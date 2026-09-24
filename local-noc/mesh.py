"""mesh: what the OpenSync cloud does for a location with extenders, locally.

A reconcile loop over the controller sessions (Noc.sessions). Every few
seconds it compares each node's monitor mirror with the desired state and
sends only the transacts that are missing, so it is idempotent and picks up
where it left off when a node restarts or reconnects.

Gateway (--mesh-gateway, the node whose uplink is the WAN):
  * backhaul AP: Wifi_VIF_Config[<bhaul-if>] enabled with the backhaul
    SSID/PSK (WPA2-PSK, new-style wpa_* columns) -- the network the pods'
    bhaul-sta VIFs are provisioned to join (their Wifi_Credential_Config);
  * per pod: once a pod associated to the backhaul AP holds a lease on it
    (DHCP_leased_IP x Wifi_Associated_Clients, or IPv4_Neighbors;
    169.254.0.0/16), a gretap to it -- Wifi_Inet_Config
    pgd<b3>_<b4> (if_type gre, gre_ifname <bhaul-if>) -- and that tunnel as
    a port of the LAN bridge (Interface/Port/Bridge), so the pod is on the
    gateway's LAN. The pod's cm builds the other end (g-bhaul-sta-*) itself.

  * live counters: ovs-vswitchd refreshes Interface.statistics only every
    other_config:stats-update-interval (mv3 ships 1 hour); set it to
    --mesh-stats-interval ms so the topology view shows current traffic.

Pod (any other node that reaches the controller -- over that tunnel):
  * fronthaul AP: Wifi_VIF_Config home-ap-<band> on the radio of --mesh-
    fronthaul-band, in br-home, with the home SSID/PSK, plus its
    Wifi_Inet_Config, and the radio's channel.
"""

import asyncio
import ipaddress
import logging

log = logging.getLogger("local-noc.mesh")

LL = ipaddress.ip_network("169.254.0.0/16")
BANDS = {"24": ("2.4G", 6, "HT20"), "50": ("5G", 44, "HT20"), "60": ("6G", 5, "HT20")}


def oset(v):
    """OVSDB set value -> python list."""
    if isinstance(v, list) and len(v) == 2 and v[0] == "set":
        return v[1]
    return [v]


def omap(v):
    if isinstance(v, list) and len(v) == 2 and v[0] == "map":
        return dict(v[1])
    return {}


def uuid_of(v):
    return v[1] if isinstance(v, list) and len(v) == 2 and v[0] == "uuid" else None


def wpa_row(ssid, psk):
    return {"ssid": ssid, "wpa": True, "wpa_key_mgmt": "wpa-psk",
            "wpa_psks": ["map", [["key--1", psk]]], "rsn_pairwise_ccmp": True,
            "security": ["map", []]}


class Mesh:
    def __init__(self, noc, args):
        self.noc = noc
        self.gateway = args.mesh_gateway
        self.bhaul_if = args.mesh_bhaul_if
        self.lan_bridge = args.mesh_lan_bridge
        self.bhaul = (args.mesh_bhaul_ssid, args.mesh_bhaul_psk)
        self.home = (args.mesh_home_ssid, args.mesh_home_psk)
        self.fh_band = args.mesh_fronthaul_band
        self.interval = args.mesh_interval
        self.stats_ms = args.mesh_stats_interval
        self.busy = set()                   # nodes with a reconcile in flight

    async def run(self):
        log.info("mesh: gateway %s, backhaul %s '%s', pods get home-ap-%s '%s'",
                 self.gateway, self.bhaul_if, self.bhaul[0], self.fh_band, self.home[0])
        while True:
            await asyncio.sleep(self.interval)
            for s in list(self.noc.sessions):
                # controller sessions whose initial monitor dump is in
                if s.role != "controller" or not s.node or not s.tables or s.node in self.busy:
                    continue
                self.busy.add(s.node)
                try:
                    if s.node == self.gateway:
                        await self.gateway_step(s)
                    elif not self.noc.redirected(s.node, self.noc.serial(s)):
                        # a redirected pod's fronthaul belongs to its new manager
                        await self.pod_step(s)
                except Exception as e:                      # noqa: BLE001
                    log.warning("mesh: %s: %r", s.node, e)
                finally:
                    self.busy.discard(s.node)

    async def transact(self, s, what, *ops):
        r = await s.request("transact", ["Open_vSwitch", *ops])
        res = r.get("result") or []
        errs = [x for x in res if isinstance(x, dict) and x.get("error")] or \
            ([r["error"]] if r.get("error") else [])
        log.info("mesh: %s: %s: %s", s.node, what, errs or "ok")
        return not errs

    @staticmethod
    def rows(s, table, **where):
        return [r for r in s.tables.get(table, {}).values()
                if all(r.get(k) == v for k, v in where.items())]

    # -- gateway ---------------------------------------------------------------
    async def gateway_step(self, s):
        # 1. backhaul AP
        want = dict(wpa_row(*self.bhaul), enabled=True)
        vif = self.rows(s, "Wifi_VIF_Config", if_name=self.bhaul_if)
        if vif:
            cur = vif[0]
            diff = {k: v for k, v in want.items()
                    if not self.same(cur.get(k), v)}
            if diff:
                await self.transact(s, f"backhaul AP {self.bhaul_if} ({', '.join(sorted(diff))})", {
                    "op": "update", "table": "Wifi_VIF_Config",
                    "where": [["if_name", "==", self.bhaul_if]], "row": want})
        else:
            log.warning("mesh: %s has no Wifi_VIF_Config %s", s.node, self.bhaul_if)

        # 2. live OVS counters
        if self.stats_ms:
            ovs = next(iter(s.tables.get("Open_vSwitch", {}).values()), None)
            if ovs is not None and omap(ovs.get("other_config")).get("stats-update-interval") != str(self.stats_ms):
                await self.transact(s, f"OVS stats-update-interval {self.stats_ms} ms", {
                    "op": "mutate", "table": "Open_vSwitch", "where": [],
                    "mutations": [["other_config", "delete", ["set", ["stats-update-interval"]]],
                                  ["other_config", "insert",
                                   ["map", [["stats-update-interval", str(self.stats_ms)]]]]]})

        # 3. a GRE per pod holding a backhaul address
        for ip in sorted(self.pod_ips(s)):
            b = ip.packed
            name = f"pgd{b[2]}_{b[3]}"
            local = self.bhaul_local_ip(s)
            if not local:
                break
            if not self.rows(s, "Wifi_Inet_Config", if_name=name):
                await self.transact(s, f"GRE {name} -> {ip}", {
                    "op": "insert", "table": "Wifi_Inet_Config", "row": {
                        "if_name": name, "if_type": "gre", "enabled": True, "network": True,
                        "mtu": 1562, "ip_assign_scheme": "none", "gre_ifname": self.bhaul_if,
                        "gre_local_inet_addr": local, "gre_remote_inet_addr": str(ip)}})
            if not self.in_bridge(s, name):
                await self.transact(s, f"{name} into {self.lan_bridge}",
                    {"op": "insert", "table": "Interface", "uuid-name": "i", "row": {"name": name}},
                    {"op": "insert", "table": "Port", "uuid-name": "p",
                     "row": {"name": name, "interfaces": ["named-uuid", "i"]}},
                    {"op": "mutate", "table": "Bridge", "where": [["name", "==", self.lan_bridge]],
                     "mutations": [["ports", "insert", ["set", [["named-uuid", "p"]]]]]})

    def bhaul_local_ip(self, s):
        for r in self.rows(s, "Wifi_Inet_State", if_name=self.bhaul_if):
            if r.get("inet_addr") not in (None, "", "0.0.0.0"):
                return r["inet_addr"]
        return None

    def bhaul_clients(self, s):
        """MACs associated to the backhaul AP (Wifi_VIF_State.associated_clients)."""
        clients = s.tables.get("Wifi_Associated_Clients", {})
        macs = set()
        for vs in self.rows(s, "Wifi_VIF_State", if_name=self.bhaul_if):
            for ref in oset(vs.get("associated_clients")):
                c = clients.get(uuid_of(ref))
                if c and c.get("state", "active") == "active":
                    macs.add(c.get("mac", "").lower())
        return macs

    def pod_ips(self, s):
        """Backhaul addresses of pods that are associated right now: leases
        (DHCP_leased_IP) whose MAC is a client of the backhaul AP -- a lease
        alone may be left over from an earlier association -- and ARP entries
        on the backhaul interface (IPv4_Neighbors, where the node has it)."""
        assoc = self.bhaul_clients(s)
        ips = set()
        for r in s.tables.get("DHCP_leased_IP", {}).values():
            if r.get("hwaddr", "").lower() in assoc:
                ips.add(r.get("inet_addr"))
        for r in s.tables.get("IPv4_Neighbors", {}).values():
            if r.get("if_name") == self.bhaul_if:
                ips.add(r.get("address"))
        out = set()
        local = self.bhaul_local_ip(s)
        for a in ips:
            try:
                ip = ipaddress.ip_address(a)
            except (TypeError, ValueError):
                continue
            if ip in LL and str(ip) != local:
                out.add(ip)
        return out

    def in_bridge(self, s, name):
        ports = self.rows(s, "Port", name=name)
        if not ports:
            return False
        puuids = {u for u, r in s.tables.get("Port", {}).items() if r.get("name") == name}
        for br in self.rows(s, "Bridge", name=self.lan_bridge):
            members = {uuid_of(x) for x in oset(br.get("ports"))}
            if members & puuids:
                return True
        return False

    # -- pod -------------------------------------------------------------------
    async def pod_step(self, s):
        band, chan, ht = BANDS[self.fh_band]
        vif_name = f"home-ap-{self.fh_band}"
        radios = self.rows(s, "Wifi_Radio_Config", freq_band=band)
        if not radios:
            return
        radio = radios[0]
        want = dict(wpa_row(*self.home), enabled=True, mode="ap", bridge="br-home",
                    ssid_broadcast="enabled", ap_bridge=True, mac_list_type="none",
                    vif_radio_idx=1)
        vif = self.rows(s, "Wifi_VIF_Config", if_name=vif_name)
        ops = []
        if not vif:
            ops += [{"op": "insert", "table": "Wifi_VIF_Config", "uuid-name": "fh",
                     "row": dict(want, if_name=vif_name)},
                    {"op": "mutate", "table": "Wifi_Radio_Config",
                     "where": [["if_name", "==", radio["if_name"]]],
                     "mutations": [["vif_configs", "insert", ["set", [["named-uuid", "fh"]]]]]}]
        if radio.get("channel") != chan or radio.get("enabled") is not True:
            ops.append({"op": "update", "table": "Wifi_Radio_Config",
                        "where": [["if_name", "==", radio["if_name"]]],
                        "row": {"channel": chan, "ht_mode": ht, "enabled": True}})
        if not self.rows(s, "Wifi_Inet_Config", if_name=vif_name):
            ops.append({"op": "insert", "table": "Wifi_Inet_Config", "row": {
                "if_name": vif_name, "if_type": "vif", "enabled": True, "network": True,
                "NAT": False, "ip_assign_scheme": "none", "mtu": 1500}})
        if ops:
            await self.transact(s, f"fronthaul {vif_name} on {radio['if_name']} ch{chan} '{self.home[0]}'", *ops)

    @staticmethod
    def same(cur, want):
        """Compare a mirrored OVSDB value with a desired one."""
        if isinstance(want, list) and want and want[0] == "map":
            return omap(cur) == dict(want[1])
        if isinstance(cur, list) and cur and cur[0] == "set":
            vals = cur[1]
            return vals == ([want] if not isinstance(want, list) else want)
        return cur == want


def add_args(ap):
    g = ap.add_argument_group("mesh (location orchestration)")
    g.add_argument("--mesh-gateway", help="node id of the gateway; enables the mesh orchestrator")
    g.add_argument("--mesh-bhaul-if", default="wl1.1", help="gateway backhaul AP interface")
    g.add_argument("--mesh-lan-bridge", default="brlan0", help="gateway LAN bridge the GREs join")
    g.add_argument("--mesh-bhaul-ssid", default="opensync-lab-bhaul")
    g.add_argument("--mesh-bhaul-psk", default="opensync-lab-bhaul-psk")
    g.add_argument("--mesh-home-ssid", default="opensync-lab-home")
    g.add_argument("--mesh-home-psk", default="opensync-lab-home-psk")
    g.add_argument("--mesh-fronthaul-band", default="24", choices=sorted(BANDS))
    g.add_argument("--mesh-interval", type=float, default=5.0)
    g.add_argument("--mesh-stats-interval", type=int, default=5000,
                   help="gateway OVS counters refresh (ms) for the topology view; 0 = leave as is")
