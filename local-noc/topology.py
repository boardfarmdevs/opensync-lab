"""topology: the location as the cloud sees it, from local-noc's node mirrors.

Built from each connected node's monitor mirror (the tables the node's
ovsdb-server reports):

  AWLAN_Node                  identity: id, model, firmware
  Connection_Manager_Uplink   the uplink in use: an Ethernet WAN (gateway) or
                              a GRE over a backhaul STA (extender)
  Wifi_Radio_State            radios: band, channel, width
  Wifi_VIF_State              VIFs: AP / STA, SSID, channel, associated clients
  Wifi_Associated_Clients     who is associated to which AP VIF
  Wifi_Inet_State             addresses
  DHCP_leased_IP              (gateway) client addresses and names

Links:
  internet  -- gateway          the gateway's WAN uplink
  gateway   -- extender         Wi-Fi backhaul: the extender's STA is an
                                associated client of the gateway's (or another
                                extender's) AP VIF. mv3 reports its VIF MACs as
                                zero, so the STA's parent BSSID alone cannot
                                name the AP's node; its client list can.
  node      -- client           every other associated client of an AP VIF

Nodes that were seen but have no controller session any more stay in the
topology, marked offline, for OFFLINE_KEEP seconds.
"""

import time

OFFLINE_KEEP = 600


def _set(v):
    if isinstance(v, list) and len(v) == 2 and v[0] == "set":
        return v[1]
    return [] if v is None else [v]


def _uuid(v):
    return v[1] if isinstance(v, list) and len(v) == 2 and v[0] == "uuid" else None


def _val(v):
    """OVSDB optional scalar: ["set", []] -> None."""
    return None if isinstance(v, list) and v[:1] == ["set"] and not v[1] else v


def _map(v):
    return dict(v[1]) if isinstance(v, list) and len(v) == 2 and v[0] == "map" else {}


STAT_KEYS = ("rx_packets", "tx_packets", "rx_bytes", "tx_bytes",
             "rx_errors", "tx_errors", "rx_dropped", "tx_dropped")


def _ovs(t):
    """OVS bridges -> ports -> interfaces, with the interface counters
    ovs-vswitchd keeps in Interface.statistics (empty where there is no
    vswitchd, as on the pods)."""
    ports, ifaces = t.get("Port", {}), t.get("Interface", {})
    bridges = []
    for b in t.get("Bridge", {}).values():
        plist = []
        for pref in _set(b.get("ports")):
            p = ports.get(_uuid(pref))
            if not p:
                continue
            for iref in _set(p.get("interfaces")):
                i = ifaces.get(_uuid(iref), {})
                st = _map(i.get("statistics"))
                plist.append({"name": p.get("name"), "type": _val(i.get("type")) or "",
                              "link": _val(i.get("link_state")), "mac": _val(i.get("mac_in_use")),
                              "stats": {k: st[k] for k in STAT_KEYS if k in st}})
        bridges.append({"name": b.get("name"), "ports": sorted(plist, key=lambda x: x["name"] or "")})
    return sorted(bridges, key=lambda x: x["name"] or "")


def _band_of_channel(ch):
    try:
        ch = int(ch)
    except (TypeError, ValueError):
        return None
    return "2.4G" if ch <= 14 else "5G"


def extract(s):
    """One node's view (a controller Session) -> plain dict."""
    t = s.tables
    awlan = next(iter(t.get("AWLAN_Node", {}).values()), {})
    radios, vif_band = [], {}
    for r in t.get("Wifi_Radio_State", {}).values():
        radios.append({"if_name": r.get("if_name"), "band": r.get("freq_band"),
                       "channel": _val(r.get("channel")), "ht_mode": _val(r.get("ht_mode")),
                       "enabled": r.get("enabled")})
        for ref in _set(r.get("vif_states")):
            vif_band[_uuid(ref)] = r.get("freq_band")
    clients = t.get("Wifi_Associated_Clients", {})
    vifs = []
    for uuid, v in t.get("Wifi_VIF_State", {}).items():
        if v.get("enabled") is not True:
            continue
        macs = []
        for ref in _set(v.get("associated_clients")):
            c = clients.get(_uuid(ref))
            if c and c.get("state", "active") == "active" and c.get("mac"):
                macs.append(c["mac"].lower())
        ch = _val(v.get("channel"))
        vifs.append({"if_name": v.get("if_name"), "mode": v.get("mode"),
                     "ssid": _val(v.get("ssid")), "channel": ch,
                     "band": vif_band.get(uuid) or _band_of_channel(ch),
                     "mac": (_val(v.get("mac")) or "").lower(),
                     "parent": (_val(v.get("parent")) or "").lower(),
                     "bridge": _val(v.get("bridge")), "clients": macs})
    uplink = next((u for u in t.get("Connection_Manager_Uplink", {}).values()
                   if u.get("is_used") is True), {})
    inet = {r.get("if_name"): r.get("inet_addr") for r in t.get("Wifi_Inet_State", {}).values()
            if r.get("inet_addr") not in (None, "", "0.0.0.0")}
    master = {r.get("if_name"): {"port": _val(r.get("port_state")), "net": _val(r.get("network_state"))}
              for r in t.get("Wifi_Master_State", {}).values()}
    interfaces = []
    for r in t.get("Wifi_Inet_State", {}).values():
        n = r.get("if_name")
        interfaces.append({
            "if_name": n, "if_type": _val(r.get("if_type")), "enabled": r.get("enabled"),
            "network": r.get("network"), "inet_addr": _val(r.get("inet_addr")),
            "netmask": _val(r.get("netmask")), "mtu": _val(r.get("mtu")),
            "assign": _val(r.get("ip_assign_scheme")), "nat": _val(r.get("NAT")),
            "gre_ifname": _val(r.get("gre_ifname")), "gre_local": _val(r.get("gre_local_inet_addr")),
            "gre_remote": _val(r.get("gre_remote_inet_addr")), "hwaddr": _val(r.get("hwaddr")),
            "port_state": master.get(n, {}).get("port"), "net_state": master.get(n, {}).get("net")})
    uplinks = []
    for u in t.get("Connection_Manager_Uplink", {}).values():
        uplinks.append({k: _val(u.get(k)) for k in (
            "if_name", "if_type", "is_used", "priority", "has_L2", "has_L3", "ipv4", "ipv6",
            "unreachable_link_counter", "unreachable_router_counter",
            "unreachable_cloud_counter", "unreachable_internet_counter", "bridge")})
    macs = [{"mac": r.get("hwaddr"), "bridge": r.get("brname"), "port": r.get("ifname"), "vlan": r.get("vlan")}
            for r in t.get("OVS_MAC_Learning", {}).values()]
    leases = {}
    for r in t.get("DHCP_leased_IP", {}).values():
        if r.get("hwaddr"):
            name = _val(r.get("hostname"))
            leases[r["hwaddr"].lower()] = {"ip": r.get("inet_addr"),
                                           "hostname": None if name in (None, "", "*") else name,
                                           "vendor": _val(r.get("vendor_class"))}
    manager = next(iter(t.get("Manager", {}).values()), {})
    mstatus = _map(manager.get("status"))
    return {
        "id": s.node, "peer": s.peer, "since": round(s.started),
        "model": awlan.get("model"), "firmware": awlan.get("firmware_version"),
        "serial": awlan.get("serial_number"),
        "uplink": {"if_name": uplink.get("if_name"), "if_type": uplink.get("if_type")},
        "radios": sorted(radios, key=lambda r: r["if_name"] or ""),
        "vifs": sorted(vifs, key=lambda v: v["if_name"] or ""),
        "inet": inet, "leases": leases, "interfaces": sorted(interfaces, key=lambda i: i["if_name"] or ""),
        "uplinks": sorted(uplinks, key=lambda u: -(u.get("priority") or 0)),
        "ovs": _ovs(t), "macs": macs,
        "cloud": {"connected": manager.get("is_connected"), "target": _val(manager.get("target")),
                  "state": mstatus.get("state"), "since": mstatus.get("sec_since_connect"),
                  "probe_ms": _val(manager.get("inactivity_probe"))},
    }


def _tunnel(ext, parent):
    """Both ends of an extender's GRE uplink: the extender's own GRE
    interface and the parent's GRE whose remote is the extender (with the
    parent's OVS counters for it, when it has them)."""
    mine = next((i for i in ext["interfaces"] if i["if_type"] == "gre" and i["gre_local"]), None)
    if not mine:
        return None
    theirs = next((i for i in parent["interfaces"] if i["if_type"] == "gre"
                   and i["gre_remote"] == mine["gre_local"]), None)
    stats, bridge = {}, None
    if theirs:
        for b in parent["ovs"]:
            for p in b["ports"]:
                if p["name"] == theirs["if_name"]:
                    stats, bridge = p["stats"], b["name"]
    return {"extender": mine, "parent": theirs, "parent_bridge": bridge, "stats": stats}


class Topology:
    def __init__(self, noc):
        self.noc = noc
        self.seen = {}                      # node id -> (last extract, last time live)

    def _live(self):
        live = {}
        for s in self.noc.sessions:
            if s.role != "controller" or not s.node or not s.tables:
                continue
            if s.node not in live or s.started > live[s.node].started:
                live[s.node] = s
        return live

    def build(self):
        now = time.time()
        for node, s in self._live().items():
            self.seen[node] = (extract(s), now)
        for node in [n for n, (_, ts) in self.seen.items() if now - ts > OFFLINE_KEEP]:
            del self.seen[node]
        live = {n for n, (_, ts) in self.seen.items() if ts == now}
        infos = {n: info for n, (info, _) in self.seen.items()}

        # every node's STA MACs, and which node's AP each MAC is a client of
        sta_owner = {}
        for n, info in infos.items():
            for v in info["vifs"]:
                if v["mode"] == "sta" and v["mac"]:
                    sta_owner[v["mac"]] = n
        leases = {}
        for info in infos.values():
            leases.update(info["leases"])

        nodes, links = [], []
        gateways = [n for n, i in infos.items() if i["uplink"].get("if_type") not in ("gre", None)
                    and not any(v["mode"] == "sta" and v["parent"] for v in i["vifs"])]
        for n, info in infos.items():
            role = "gateway" if n in gateways else "extender"
            detail = {k: info[k] for k in ("model", "firmware", "serial", "peer", "since", "uplink",
                                           "radios", "vifs", "inet", "cloud", "interfaces",
                                           "uplinks", "ovs", "macs")}
            if role == "gateway":
                detail["leases"] = [dict(mac=m, **l) for m, l in sorted(info["leases"].items())]
            nodes.append({"id": n, "kind": role, "online": n in live, "label": n, "detail": detail})
        if gateways:
            nodes.append({"id": "internet", "kind": "internet", "online": True, "label": "Internet"})
            for g in gateways:
                info = infos[g]
                links.append({"source": g, "target": "internet", "kind": "wired",
                              "label": "WAN", "detail": {
                                  "if_name": info["uplink"].get("if_name"),
                                  "address": info["inet"].get(info["uplink"].get("if_name"))}})

        clients = {}
        for n, info in infos.items():
            for v in info["vifs"]:
                if v["mode"] != "ap":
                    continue
                for mac in v["clients"]:
                    if mac in sta_owner and sta_owner[mac] != n:
                        # an extender's backhaul STA on this AP
                        ext = sta_owner[mac]
                        links.append({"source": ext, "target": n, "kind": "backhaul",
                                      "band": v["band"], "channel": v["channel"], "detail": {
                                          "ap": v["if_name"], "ssid": v["ssid"], "sta_mac": mac,
                                          "tunnel": _tunnel(infos[ext], infos[n])}})
                        continue
                    lease = leases.get(mac, {})
                    clients[mac] = {"id": mac, "kind": "client", "online": n in live,
                                    "label": lease.get("hostname") or lease.get("ip") or mac,
                                    "detail": {"mac": mac, "ip": lease.get("ip"),
                                               "hostname": lease.get("hostname"),
                                               "ap": v["if_name"], "ssid": v["ssid"],
                                               "node": n}}
                    links.append({"source": mac, "target": n, "kind": "client",
                                  "band": v["band"], "channel": v["channel"],
                                  "detail": {"ap": v["if_name"], "ssid": v["ssid"]}})
        nodes.extend(clients.values())
        counts = {"gateways": len(gateways), "extenders": len(infos) - len(gateways),
                  "clients": len(clients), "online": len(live)}
        return {"t": now, "location": self.noc.location, "counts": counts,
                "nodes": nodes, "links": links}
