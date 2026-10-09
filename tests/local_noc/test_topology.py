"""topology.py: the location as the web UI shows it, from the nodes' mirrors: a gateway, an
extender on its backhaul (with both ends of its GRE), a client with its lease, and a node
that went away (kept offline for a while, then dropped)."""

import time
import unittest
from types import SimpleNamespace

from support import FakeSession, omap, oset, ref, topology

STA_MAC = "aa:bb:cc:00:00:01"
LAPTOP = "aa:bb:cc:00:00:42"


def gateway():
    return FakeSession("gw", {
        "AWLAN_Node": {"a": {"id": "gw", "model": "MV3", "serial_number": "G1",
                             "firmware_version": "1.0"}},
        "Connection_Manager_Uplink": {"u": {"if_name": "eth0", "if_type": "eth", "is_used": True,
                                            "priority": 2}},
        "Wifi_Radio_State": {"r": {"if_name": "wifi1", "freq_band": "5G", "channel": 44,
                                   "vif_states": oset(ref("bh"))}},
        "Wifi_VIF_State": {
            "bh": {"if_name": "wl1.1", "mode": "ap", "enabled": True, "ssid": "bhaul",
                   "channel": 44, "associated_clients": oset(ref("c1"))},
            "fh": {"if_name": "wl0.1", "mode": "ap", "enabled": True, "ssid": "home",
                   "channel": 6, "associated_clients": oset(ref("c2"))},
            "off": {"if_name": "wl0.2", "mode": "ap", "enabled": False}},
        "Wifi_Associated_Clients": {"c1": {"mac": STA_MAC.upper()},
                                    "c2": {"mac": LAPTOP, "state": "active"}},
        "Wifi_Inet_State": {
            "w": {"if_name": "eth0", "inet_addr": "192.168.2.10", "if_type": "eth"},
            "g": {"if_name": "pgd1_50", "if_type": "gre", "gre_remote_inet_addr": "169.254.1.50",
                  "inet_addr": "0.0.0.0"}},
        "DHCP_leased_IP": {"l": {"hwaddr": LAPTOP, "inet_addr": "10.0.0.42", "hostname": "laptop"}},
        "Bridge": {"b": {"name": "brlan0", "ports": oset(ref("p"))}},
        "Port": {"p": {"name": "pgd1_50", "interfaces": oset(ref("i"))}},
        "Interface": {"i": {"type": "gre", "statistics": omap(rx_bytes=100, tx_bytes=200,
                                                              collisions=0)}},
        "Manager": {"m": {"is_connected": True, "target": "tcp:10.101.0.40:6641",
                          "status": omap(state="ACTIVE")}},
    })


def extender():
    return FakeSession("pod1", {
        "AWLAN_Node": {"a": {"id": "pod1", "model": "RPI_POD"}},
        "Connection_Manager_Uplink": {"u": {"if_name": "g-bhaul-sta-50", "if_type": "gre",
                                            "is_used": True}},
        "Wifi_VIF_State": {"s": {"if_name": "bhaul-sta-50", "mode": "sta", "enabled": True,
                                 "mac": STA_MAC, "parent": "02:00:00:00:00:11", "channel": 44}},
        "Wifi_Inet_State": {"g": {"if_name": "g-bhaul-sta-50", "if_type": "gre",
                                  "gre_local_inet_addr": "169.254.1.50",
                                  "gre_remote_inet_addr": "169.254.1.1"}},
    })


class ExtractTest(unittest.TestCase):
    def test_gateway_view(self):
        info = topology.extract(gateway())
        self.assertEqual((info["model"], info["serial"], info["uplink"]["if_name"]),
                         ("MV3", "G1", "eth0"))
        self.assertEqual([v["if_name"] for v in info["vifs"]], ["wl0.1", "wl1.1"])  # enabled only
        bh = next(v for v in info["vifs"] if v["if_name"] == "wl1.1")
        self.assertEqual((bh["band"], bh["clients"]), ("5G", [STA_MAC]))
        fh = next(v for v in info["vifs"] if v["if_name"] == "wl0.1")
        self.assertEqual(fh["band"], "2.4G")                 # from the channel: no radio row
        self.assertEqual(info["inet"], {"eth0": "192.168.2.10"})
        self.assertEqual(info["leases"][LAPTOP]["hostname"], "laptop")
        self.assertEqual(info["ovs"][0]["ports"][0]["stats"], {"rx_bytes": 100, "tx_bytes": 200})
        self.assertEqual((info["cloud"]["connected"], info["cloud"]["state"]), (True, "ACTIVE"))


class BuildTest(unittest.TestCase):
    def build(self, sessions):
        t = topology.Topology(SimpleNamespace(sessions=set(sessions), location="lab"))
        return t, t.build()

    def test_gateway_extender_client(self):
        _, view = self.build([gateway(), extender()])
        kinds = {n["id"]: n["kind"] for n in view["nodes"]}
        self.assertEqual(kinds, {"gw": "gateway", "pod1": "extender", "internet": "internet",
                                 LAPTOP: "client"})
        self.assertEqual(view["counts"], {"gateways": 1, "extenders": 1, "clients": 1, "online": 2})
        links = {(l["source"], l["target"]): l for l in view["links"]}
        self.assertEqual(links[("gw", "internet")]["detail"]["address"], "192.168.2.10")
        bh = links[("pod1", "gw")]
        self.assertEqual((bh["kind"], bh["band"], bh["detail"]["ap"]), ("backhaul", "5G", "wl1.1"))
        tunnel = bh["detail"]["tunnel"]
        self.assertEqual((tunnel["extender"]["if_name"], tunnel["parent"]["if_name"],
                          tunnel["parent_bridge"]), ("g-bhaul-sta-50", "pgd1_50", "brlan0"))
        client = next(n for n in view["nodes"] if n["id"] == LAPTOP)
        self.assertEqual((client["label"], client["detail"]["ip"]), ("laptop", "10.0.0.42"))
        self.assertEqual(links[(LAPTOP, "gw")]["kind"], "client")

    def test_offline_kept_then_dropped(self):
        t, _ = self.build([gateway(), extender()])
        t.noc.sessions = {s for s in t.noc.sessions if s.node == "gw"}
        view = t.build()
        pod = next(n for n in view["nodes"] if n["id"] == "pod1")
        self.assertFalse(pod["online"])
        info, _ = t.seen["pod1"]
        t.seen["pod1"] = (info, time.time() - topology.OFFLINE_KEEP - 1)
        view = t.build()
        self.assertNotIn("pod1", {n["id"] for n in view["nodes"]})

    def test_newest_session_wins(self):
        old, new = extender(), extender()
        old.started, new.started = 100, 200
        new.tables["AWLAN_Node"]["a"]["model"] = "NEWER"
        t = topology.Topology(SimpleNamespace(sessions={old, new}, location="lab"))
        self.assertIs(t._live()["pod1"], new)

    def test_no_gateway_no_internet(self):
        _, view = self.build([extender()])
        self.assertNotIn("internet", {n["id"] for n in view["nodes"]})
        self.assertEqual(view["counts"]["gateways"], 0)


if __name__ == "__main__":
    unittest.main()
