"""noc.py: the redirects' configuration, a session's monitor mirror and dispatch, and local-noc
end to end on loopback: a fake node (an ovsdb-server, as OpenSync's cm points it at the cloud)
through the redirector and the controller, the control socket (noc-ctl's protocol), the web
UI's API, the capture files, and a redirect that hands the node to another manager."""

import argparse
import asyncio
import glob
import json
import os
import tempfile
import unittest

from support import ROOT, noc

TIMEOUT = 10


def noc_args(data, *extra):
    ns = argparse.Namespace(data=data, advertise="127.0.0.1", controller_port=6641,
                            location="test", redirect=None)
    for k, v in extra:
        setattr(ns, k, v)
    return ns


class FakeWriter:
    def __init__(self):
        self.sent = []
        self.closed = False

    def get_extra_info(self, _):
        return ("10.0.0.2", 40000)

    def write(self, data):
        self.sent.append(json.loads(data))

    def close(self):
        self.closed = True


class RedirectConfigTest(unittest.TestCase):
    def test_from_file_and_arguments(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "redirects.json"), "w") as f:
                json.dump({"podA": "tcp:10.0.0.9:6651"}, f)
            n = noc.Noc(noc_args(d, ("redirect", ["podB=tcp:10.0.0.9:6652"])))
            self.assertEqual(n.redirects, {"podA": "tcp:10.0.0.9:6651", "podB": "tcp:10.0.0.9:6652"})
            self.assertEqual(n.home(), "tcp:127.0.0.1:6641")
            self.assertEqual(n.target_for("podA"), "tcp:10.0.0.9:6651")
            self.assertEqual(n.target_for("other", "podB"), "tcp:10.0.0.9:6652")   # by serial
            self.assertEqual(n.target_for("other", None), n.home())
            n.redirects["podC"] = "tcp:x:1"
            n.save_redirects()
            with open(os.path.join(d, "redirects.json")) as f:
                self.assertEqual(json.load(f)["podC"], "tcp:x:1")
            self.assertFalse(os.path.exists(os.path.join(d, "redirects.json.tmp")))

    def test_bad_argument(self):
        with tempfile.TemporaryDirectory() as d, self.assertRaises(SystemExit):
            noc.Noc(noc_args(d, ("redirect", ["no-target"])))

    def test_unreadable_file_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "redirects.json"), "w") as f:
                f.write("{not json")
            self.assertEqual(noc.Noc(noc_args(d)).redirects, {})


class SessionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.noc = noc.Noc(noc_args(self.tmp.name))
        self.w = FakeWriter()
        self.s = noc.Session(self.noc, "controller", None, self.w)

    def tearDown(self):
        self.s.capture.close()
        self.tmp.cleanup()

    def test_mirror_insert_modify_delete(self):
        s = self.s
        s.apply_update({"AWLAN_Node": {"a": {"new": {"id": "pod1", "model": "X"}}},
                        "Wifi_VIF_State": {"v": {"new": {"if_name": "home-ap-24", "channel": 1}}}})
        self.assertEqual(s.node, "pod1")
        s.apply_update({"Wifi_VIF_State": {"v": {"old": {"channel": 1}, "new": {"channel": 6}}}})
        self.assertEqual(s.tables["Wifi_VIF_State"]["v"], {"if_name": "home-ap-24", "channel": 6})
        s.apply_update({"Wifi_VIF_State": {"v": {"old": {"channel": 6}}}})
        self.assertEqual(s.tables["Wifi_VIF_State"], {})
        # identified: the capture moved under the node, a snapshot kept
        self.assertIn(os.path.join("sessions", "pod1"), s.capture_path)
        with open(os.path.join(self.tmp.name, "nodes", "pod1", "tables.json")) as f:
            self.assertEqual(json.load(f)["node"], "pod1")

    def test_dispatch(self):
        s = self.s
        s.dispatch({"id": "e1", "method": "echo", "params": ["x"]})
        s.dispatch({"id": 9, "method": "lock", "params": []})
        s.dispatch({"id": None, "method": "update", "params": ["local-noc", {
            "Wifi_Radio_State": {"r": {"new": {"if_name": "phy0"}}}}]})
        self.assertEqual(self.w.sent, [{"id": "e1", "result": ["x"], "error": None},
                                       {"id": 9, "result": None, "error": "not supported"}])
        self.assertIn("r", s.tables["Wifi_Radio_State"])


class FakeNode:
    """An OpenSync node's ovsdb-server on a connection it opened to local-noc: it answers
    local-noc's requests from `answers` (method -> function of params), records them, and
    can send its own (echo, monitor updates)."""

    def __init__(self, answers):
        self.answers = answers
        self.requests = []
        self.replies = {}
        self.closed = asyncio.Event()

    async def connect(self, host, port):
        self.reader, self.writer = await asyncio.open_connection(host, port)
        self.task = asyncio.create_task(self.loop())

    async def loop(self):
        stream = noc.JsonStream()
        try:
            while data := await self.reader.read(65536):
                for msg in stream.feed(data.decode()):
                    if msg.get("method"):
                        self.requests.append(msg)
                        result = self.answers[msg["method"]](msg["params"])
                        self.send({"id": msg["id"], "result": result, "error": None})
                    else:
                        self.replies[msg.get("id")] = msg
        finally:
            self.closed.set()

    def send(self, msg):
        self.writer.write(json.dumps(msg).encode())

    async def wait_for(self, pred, what):
        for _ in range(TIMEOUT * 20):
            if pred():
                return
            await asyncio.sleep(0.05)
        raise AssertionError(f"timed out waiting for {what}")

    async def close(self):
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except ConnectionError:
            pass
        await self.task


SCHEMA = {"name": "Open_vSwitch", "tables": {"AWLAN_Node": {"columns": {}},
                                              "Wifi_VIF_State": {"columns": {}}}}
INITIAL = {"AWLAN_Node": {"a1": {"new": {"id": "pod1", "serial_number": "SER1"}}},
           "Wifi_VIF_State": {"v1": {"new": {"if_name": "home-ap-24", "enabled": True,
                                             "mode": "ap"}}}}


def node_answers(manager_addrs):
    def transact(params):
        op = params[1]
        if op["op"] == "select":
            return [{"rows": [{"id": "pod1", "serial_number": "SER1", "model": "RPI_POD",
                               "firmware_version": "6.6.1"}]}]
        manager_addrs.append(op["row"]["manager_addr"])
        return [{"count": 1}]
    return {"transact": transact, "list_dbs": lambda p: ["Open_vSwitch"],
            "get_schema": lambda p: SCHEMA, "monitor": lambda p: INITIAL}


class EndToEndTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.noc = noc.Noc(noc_args(self.tmp.name))
        start = asyncio.start_server
        self.servers = [await start(self.noc.handler("redirector"), "127.0.0.1", 0),
                        await start(self.noc.handler("controller"), "127.0.0.1", 0),
                        await start(self.noc.http, "127.0.0.1", 0)]
        self.rport, self.cport, self.hport = (s.sockets[0].getsockname()[1] for s in self.servers)
        self.noc.controller_port = self.cport
        self.sock = os.path.join(self.tmp.name, "noc.sock")
        self.servers.append(await asyncio.start_unix_server(self.noc.control, self.sock))

    async def asyncTearDown(self):
        for s in self.servers:
            s.close()
            await s.wait_closed()
        self.tmp.cleanup()

    async def ctl(self, cmd):
        r, w = await asyncio.open_unix_connection(self.sock)
        w.write((json.dumps(cmd) + "\n").encode())
        reply = json.loads(await asyncio.wait_for(r.readline(), TIMEOUT))
        w.close()
        await w.wait_closed()
        return reply

    async def noc_ctl(self, *argv):
        """local-noc/noc-ctl, as an operator runs it, against this local-noc."""
        p = await asyncio.create_subprocess_exec(
            os.path.join(ROOT, "local-noc", "noc-ctl"), *argv,
            env=dict(os.environ, LOCAL_NOC_DATA=self.tmp.name),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await asyncio.wait_for(p.communicate(), TIMEOUT)
        return p.returncode, out.decode(), err.decode()

    async def http(self, path):
        r, w = await asyncio.open_connection("127.0.0.1", self.hport)
        w.write(f"GET {path} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
        raw = await asyncio.wait_for(r.read(), TIMEOUT)
        w.close()
        await w.wait_closed()
        head, _, body = raw.partition(b"\r\n\r\n")
        return head.split(b"\r\n")[0].decode(), body

    async def redirect_once(self):
        addrs = []
        node = FakeNode(node_answers(addrs))
        await node.connect("127.0.0.1", self.rport)
        await node.wait_for(lambda: addrs, "manager_addr written")
        await node.close()
        return addrs[0]

    async def test_node_through_redirector_and_controller(self):
        # redirector: the node is sent to this controller
        self.assertEqual(await self.redirect_once(), f"tcp:127.0.0.1:{self.cport}")

        # controller: list_dbs, get_schema, monitor of every table
        addrs = []
        node = FakeNode(node_answers(addrs))
        await node.connect("127.0.0.1", self.cport)
        await node.wait_for(lambda: any(r["method"] == "monitor" for r in node.requests),
                            "monitor")
        monitor = next(r for r in node.requests if r["method"] == "monitor")
        self.assertEqual(sorted(monitor["params"][2]), ["AWLAN_Node", "Wifi_VIF_State"])
        self.assertEqual([r["method"] for r in node.requests], ["list_dbs", "get_schema", "monitor"])

        # the node's keepalive is answered; its updates reach the mirror
        node.send({"id": "e1", "method": "echo", "params": []})
        node.send({"id": None, "method": "update", "params": ["local-noc", {
            "Wifi_VIF_State": {"v2": {"new": {"if_name": "bhaul-sta-24", "mode": "sta",
                                              "enabled": True}}}}]})
        await node.wait_for(lambda: "e1" in node.replies, "echo reply")

        nodes = (await self.ctl({"cmd": "nodes"}))["result"]
        ctl = next(n for n in nodes if n["role"] == "controller")
        self.assertEqual((ctl["node"], ctl["tables"]), ("pod1", 2))
        await node.wait_for(lambda: len(self.noc.find("pod1").tables["Wifi_VIF_State"]) == 2,
                            "update in the mirror")
        tables = await self.ctl({"cmd": "tables", "node": "pod1"})
        self.assertEqual(tables["result"], {"AWLAN_Node": 1, "Wifi_VIF_State": 2})
        dump = await self.ctl({"cmd": "dump", "node": "pod1", "table": "Wifi_VIF_State"})
        self.assertEqual(sorted(r["if_name"] for r in dump["result"]), ["bhaul-sta-24", "home-ap-24"])
        bad = await self.ctl({"cmd": "dump", "node": "nobody", "table": "x"})
        self.assertFalse(bad["ok"])
        self.assertIn("KeyError", bad["error"])

        # noc-ctl, the operator's view of the same
        rc, out, _ = await self.noc_ctl("nodes")
        self.assertEqual(rc, 0)
        self.assertRegex(out, r"pod1\s+controller\s+127\.0\.0\.1:\d+\s+tables=2")
        rc, out, _ = await self.noc_ctl("tables", "pod1")
        self.assertEqual(out.split(), ["1", "AWLAN_Node", "2", "Wifi_VIF_State"])
        rc, out, _ = await self.noc_ctl("dump", "pod1", "AWLAN_Node")
        self.assertEqual(json.loads(out), [{"id": "pod1", "serial_number": "SER1"}])
        rc, out, _ = await self.noc_ctl("request", "pod1", "list_dbs")
        self.assertEqual(json.loads(out)["result"], ["Open_vSwitch"])
        rc, out, _ = await self.noc_ctl("log", "pod1", "3")
        self.assertEqual((rc, len(out.splitlines())), (0, 3))
        rc, _, err = await self.noc_ctl("tables", "nobody")
        self.assertNotEqual(rc, 0)
        self.assertIn("no controller session", err)

        # a transact through the control socket reaches the node
        r = await self.ctl({"cmd": "transact", "node": "pod1", "ops": [
            {"op": "update", "table": "AWLAN_Node", "where": [], "row": {"manager_addr": "tcp:m:1"}}]})
        self.assertEqual(r["result"], [{"count": 1}])
        self.assertEqual(addrs, ["tcp:m:1"])

        # the web UI's API
        status, body = await self.http("/api/node/pod1")
        self.assertEqual((status, json.loads(body)["node"]), ("HTTP/1.1 200 OK", "pod1"))
        status, body = await self.http("/api/topology")
        view = json.loads(body)
        self.assertEqual((status, view["location"]), ("HTTP/1.1 200 OK", "test"))
        self.assertIn("pod1", {n["id"] for n in view["nodes"]})
        self.assertEqual((await self.http("/api/node/nobody"))[0], "HTTP/1.1 404 Not Found")
        self.assertEqual((await self.http("/nothing"))[0], "HTTP/1.1 404 Not Found")

        # captured: the exchange per node, its schema and its mirror
        caps = glob.glob(os.path.join(self.tmp.name, "sessions", "pod1", "*-controller-*.jsonl"))
        self.assertEqual(len(caps), 1)
        with open(caps[0]) as f:
            dirs = [json.loads(line)["dir"] for line in f]
        self.assertIn("rx", dirs)
        self.assertIn("tx", dirs)
        for name in ("schema.json", "tables.json"):
            self.assertTrue(os.path.exists(os.path.join(self.tmp.name, "nodes", "pod1", name)))

        # a redirect hands the connected node over and ends its session
        r = await self.ctl({"cmd": "redirect", "node": "SER1", "target": "tcp:10.9.9.9:6651"})
        self.assertEqual(r["result"], {"SER1": "tcp:10.9.9.9:6651"})
        await asyncio.wait_for(node.closed.wait(), TIMEOUT)
        await node.close()
        self.assertEqual(addrs[-1], "tcp:10.9.9.9:6651")
        with open(os.path.join(self.tmp.name, "redirects.json")) as f:
            self.assertEqual(json.load(f), {"SER1": "tcp:10.9.9.9:6651"})
        # ...and the redirector now sends it there
        self.assertEqual(await self.redirect_once(), "tcp:10.9.9.9:6651")
        # undone: back home
        await self.ctl({"cmd": "redirect", "node": "SER1"})
        self.assertEqual(await self.redirect_once(), f"tcp:127.0.0.1:{self.cport}")

    async def test_probe_closes_cleanly(self):
        # a port probe (connect, then EOF) ends its session without a node
        r, w = await asyncio.open_connection("127.0.0.1", self.cport)
        w.close()
        await w.wait_closed()
        for _ in range(TIMEOUT * 20):
            if not self.noc.sessions:
                break
            await asyncio.sleep(0.05)
        self.assertEqual(self.noc.sessions, set())

    async def test_unknown_command(self):
        r = await self.ctl({"cmd": "frobnicate", "node": "x"})
        self.assertFalse(r["ok"])
        r = await self.ctl({"cmd": "redirects"})
        self.assertEqual(r, {"ok": True, "result": {}})


if __name__ == "__main__":
    unittest.main()
