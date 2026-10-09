"""mesh.py's reconcile steps against a node's mirror: what local-noc sends a gateway and a
pod, and that a mirror already in the desired state gets nothing (the loop is idempotent)."""

import asyncio
import ipaddress
import unittest
import zlib

from support import FakeSession, mesh, mesh_args, omap, oset, ref, transact_ops


def run(coro):
    return asyncio.run(coro)


def gateway_tables(converged=False):
    """A gateway: backhaul AP wl1.1 at 169.254.1.1 with one pod associated and leased at
    .50, a stale lease (.77) whose MAC is not associated, and LAN bridge brlan0."""
    want = dict(mesh.wpa_row("opensync-lab-bhaul", "opensync-lab-bhaul-psk"), enabled=True)
    t = {
        "Wifi_VIF_Config": {"v1": dict(want, if_name="wl1.1") if converged
                            else {"if_name": "wl1.1", "enabled": False, "ssid": "old"}},
        "Wifi_Inet_State": {"i1": {"if_name": "wl1.1", "inet_addr": "169.254.1.1"}},
        "Wifi_VIF_State": {"vs1": {"if_name": "wl1.1", "associated_clients": oset(ref("c1"))}},
        "Wifi_Associated_Clients": {"c1": {"mac": "AA:BB:CC:00:00:01", "state": "active"}},
        "DHCP_leased_IP": {"l1": {"hwaddr": "aa:bb:cc:00:00:01", "inet_addr": "169.254.1.50"},
                           "l2": {"hwaddr": "aa:bb:cc:00:00:99", "inet_addr": "169.254.1.77"}},
        "Open_vSwitch": {"o": {"other_config": omap(**({"stats-update-interval": "5000"}
                                                       if converged else {}))}},
        "Bridge": {"b1": {"name": "brlan0", "ports": oset(ref("p1")) if converged else oset()}},
    }
    if converged:
        t["Wifi_Inet_Config"] = {"gi": {"if_name": "pgd1_50", "if_type": "gre"}}
        t["Port"] = {"p1": {"name": "pgd1_50"}}
    return t


def pod_tables(converged=False, uplink=None):
    """A pod with a 2.4 GHz radio (phy0) and a 5 GHz one (phy1)."""
    radio24 = {"if_name": "phy0", "freq_band": "2.4G", "channel": 6 if converged else 1,
               "enabled": True if converged else False}
    t = {"AWLAN_Node": {"a": {"id": "pod1", "serial_number": "S1"}},
         "Wifi_Radio_Config": {"r0": radio24,
                               "r1": {"if_name": "phy1", "freq_band": "5G", "channel": 44,
                                      "enabled": True}},
         "Wifi_VIF_Config": {}, "Wifi_Inet_Config": {}}
    if converged:
        t["Wifi_VIF_Config"]["h"] = {"if_name": "home-ap-24"}
        t["Wifi_Inet_Config"]["hi"] = {"if_name": "home-ap-24"}
    if uplink:
        t["Connection_Manager_Uplink"] = {"u": uplink}
    return t


class HelpersTest(unittest.TestCase):
    def test_ovsdb_values(self):
        self.assertEqual(mesh.oset(["set", [1, 2]]), [1, 2])
        self.assertEqual(mesh.oset("x"), ["x"])
        self.assertEqual(mesh.omap(["map", [["k", "v"]]]), {"k": "v"})
        self.assertEqual(mesh.omap("x"), {})
        self.assertEqual(mesh.uuid_of(["uuid", "u"]), "u")
        self.assertIsNone(mesh.uuid_of("u"))

    def test_same(self):
        self.assertTrue(mesh.Mesh.same(["map", [["a", "1"]]], ["map", [["a", "1"]]]))
        self.assertFalse(mesh.Mesh.same(["map", []], ["map", [["a", "1"]]]))
        self.assertTrue(mesh.Mesh.same(["set", ["br-home"]], "br-home"))
        self.assertFalse(mesh.Mesh.same(["set", []], "br-home"))
        self.assertTrue(mesh.Mesh.same(True, True))

    def test_parent_net(self):
        net = mesh.Mesh.parent_net("pod1")
        self.assertEqual(net, ipaddress.ip_network(
            f"169.254.{2 + zlib.crc32(b'pod1') % 250}.0/24"))
        self.assertEqual(net, mesh.Mesh.parent_net("pod1"))   # stable across restarts


class GatewayStepTest(unittest.TestCase):
    def test_backhaul_ap_stats_and_gre(self):
        m = mesh.Mesh(None, mesh_args())
        s = FakeSession("gw", gateway_tables())
        run(m.gateway_step(s))
        ops = transact_ops(s)
        ap = ops[0]
        self.assertEqual((ap["op"], ap["table"], ap["where"]),
                         ("update", "Wifi_VIF_Config", [["if_name", "==", "wl1.1"]]))
        self.assertEqual(ap["row"]["ssid"], "opensync-lab-bhaul")
        self.assertIs(ap["row"]["enabled"], True)
        self.assertEqual(ap["row"]["wpa_psks"], ["map", [["key--1", "opensync-lab-bhaul-psk"]]])
        stats = ops[1]
        self.assertEqual(stats["table"], "Open_vSwitch")
        self.assertIn(["other_config", "insert", ["map", [["stats-update-interval", "5000"]]]],
                      stats["mutations"])
        gre = ops[2]
        self.assertEqual((gre["op"], gre["table"]), ("insert", "Wifi_Inet_Config"))
        self.assertEqual(gre["row"]["if_name"], "pgd1_50")
        self.assertEqual((gre["row"]["gre_local_inet_addr"], gre["row"]["gre_remote_inet_addr"],
                          gre["row"]["gre_ifname"], gre["row"]["mtu"]),
                         ("169.254.1.1", "169.254.1.50", "wl1.1", 1562))
        port = ops[3:]
        self.assertEqual([o["table"] for o in port], ["Interface", "Port", "Bridge"])
        self.assertEqual(port[2]["where"], [["name", "==", "brlan0"]])
        # the stale lease (.77, not associated) gets no tunnel
        self.assertFalse(any(o.get("row", {}).get("if_name") == "pgd1_77" for o in ops))

    def test_converged_gets_nothing(self):
        m = mesh.Mesh(None, mesh_args())
        s = FakeSession("gw", gateway_tables(converged=True))
        run(m.gateway_step(s))
        self.assertEqual(s.requests, [])

    def test_pod_ips(self):
        m = mesh.Mesh(None, mesh_args())
        t = gateway_tables()
        t["IPv4_Neighbors"] = {"n1": {"if_name": "wl1.1", "address": "169.254.1.60"},
                               "n2": {"if_name": "wl1.1", "address": "192.168.1.5"},
                               "n3": {"if_name": "eth0", "address": "169.254.9.9"}}
        ips = m.pod_ips(FakeSession("gw", t))
        self.assertEqual(sorted(map(str, ips)), ["169.254.1.50", "169.254.1.60"])

    def test_no_backhaul_address_no_gre(self):
        m = mesh.Mesh(None, mesh_args("--mesh-stats-interval", "0"))
        t = gateway_tables()
        t["Wifi_Inet_State"] = {"i1": {"if_name": "wl1.1", "inet_addr": "0.0.0.0"}}
        s = FakeSession("gw", t)
        run(m.gateway_step(s))
        self.assertEqual([o["table"] for o in transact_ops(s)], ["Wifi_VIF_Config"])


class PodStepTest(unittest.TestCase):
    def test_fronthaul_created(self):
        m = mesh.Mesh(None, mesh_args())
        s = FakeSession("pod1", pod_tables())
        run(m.pod_step(s))
        ops = transact_ops(s)
        self.assertEqual([(o["op"], o["table"]) for o in ops],
                         [("insert", "Wifi_VIF_Config"), ("mutate", "Wifi_Radio_Config"),
                          ("update", "Wifi_Radio_Config"), ("insert", "Wifi_Inet_Config")])
        vif = ops[0]["row"]
        self.assertEqual((vif["if_name"], vif["ssid"], vif["bridge"], vif["mode"]),
                         ("home-ap-24", "opensync-lab-home", "br-home", "ap"))
        self.assertEqual(ops[1]["where"], [["if_name", "==", "phy0"]])
        self.assertEqual(ops[2]["row"], {"channel": 6, "ht_mode": "HT20", "enabled": True})

    def test_converged_gets_nothing(self):
        m = mesh.Mesh(None, mesh_args())
        s = FakeSession("pod1", pod_tables(converged=True))
        run(m.pod_step(s))
        self.assertEqual(s.requests, [])

    def test_fronthaul_band_without_radio(self):
        m = mesh.Mesh(None, mesh_args("--mesh-fronthaul-band", "60"))
        s = FakeSession("pod1", pod_tables())
        run(m.pod_step(s))
        self.assertEqual(s.requests, [])

    def test_ethernet_uplink_into_bridge(self):
        up = {"if_name": "eth1", "if_type": "eth", "is_used": True, "bridge": oset()}
        m = mesh.Mesh(None, mesh_args("--mesh-eth-bridge", "br-home"))
        s = FakeSession("pod1", pod_tables(converged=True, uplink=up))
        run(m.pod_step(s))
        self.assertEqual(transact_ops(s), [{
            "op": "update", "table": "Connection_Manager_Uplink",
            "where": [["if_name", "==", "eth1"]], "row": {"bridge": "br-home"}}])
        s.tables["Connection_Manager_Uplink"]["u"]["bridge"] = "br-home"
        s.requests.clear()
        run(m.pod_step(s))
        self.assertEqual(s.requests, [])

    def test_ethernet_uplink_left_alone_by_default(self):
        up = {"if_name": "eth1", "if_type": "eth", "is_used": True, "bridge": oset()}
        m = mesh.Mesh(None, mesh_args())
        s = FakeSession("pod1", pod_tables(converged=True, uplink=up))
        run(m.pod_step(s))
        self.assertEqual(s.requests, [])

    def test_wired_pod_as_backhaul_parent(self):
        up = {"if_name": "eth1", "if_type": "eth", "is_used": True}
        m = mesh.Mesh(None, mesh_args("--mesh-pod-bhaul-band", "50", "--mesh-fronthaul-band", "50"))
        t = pod_tables(uplink=up)
        t["Wifi_VIF_Config"]["s"] = {"if_name": "bhaul-sta-50", "enabled": True}
        s = FakeSession("pod1", t)
        run(m.pod_step(s))
        ops = transact_ops(s)
        net = mesh.Mesh.parent_net("pod1")
        ap = next(o for o in ops if o["op"] == "insert" and o["table"] == "Wifi_VIF_Config")
        self.assertEqual((ap["row"]["if_name"], ap["row"]["ssid"], ap["row"]["multi_ap"]),
                         ("b-ap-50", "opensync-lab-bhaul", "none"))
        self.assertIn({"op": "update", "table": "Wifi_VIF_Config",
                       "where": [["if_name", "==", "bhaul-sta-50"]], "row": {"enabled": False}}, ops)
        inet = next(o for o in ops if o["op"] == "insert" and o["table"] == "Wifi_Inet_Config")
        self.assertEqual((inet["row"]["if_name"], inet["row"]["inet_addr"], inet["row"]["mtu"]),
                         ("b-ap-50", str(net.network_address + 1), 1600))
        self.assertEqual(dict(inet["row"]["dhcpd"][1])["start"], str(net.network_address + 10))
        # the fronthaul band is the backhaul band: no home AP on it (one AP per radio)
        self.assertFalse(any(o.get("row", {}).get("if_name", "").startswith("home-ap") for o in ops))

    def test_wireless_pod_is_no_parent(self):
        up = {"if_name": "g-bhaul-sta-50", "if_type": "gre", "is_used": True}
        m = mesh.Mesh(None, mesh_args("--mesh-pod-bhaul-band", "50"))
        s = FakeSession("pod1", pod_tables(converged=True, uplink=up))
        run(m.pod_step(s))
        self.assertEqual(s.requests, [])


class TransactTest(unittest.TestCase):
    def test_errors_reported(self):
        m = mesh.Mesh(None, mesh_args())

        class Failing(FakeSession):
            async def request(self, method, params, timeout=30):
                return {"result": [{"error": "constraint violation"}], "error": None}

        self.assertFalse(run(m.transact(Failing("gw", {}), "x", {"op": "insert"})))
        self.assertTrue(run(m.transact(FakeSession("gw", {}), "x", {"op": "insert"})))


if __name__ == "__main__":
    unittest.main()
