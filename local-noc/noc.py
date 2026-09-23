#!/usr/bin/env python3
"""local-noc: a local, plain-TCP stand-in for the OpenSync cloud (NOC).

It speaks the protocol an OpenSync node speaks to its cloud -- OVSDB JSON-RPC
(RFC 7047) with the cloud as the *client* on a connection the node's
ovsdb-server opens (Manager.target / AWLAN_Node.redirector_addr) -- without
TLS, and records every message so the whole exchange can be analysed.

Two roles, like the real cloud:

  redirector  (--redirector-port, default 6640)
      The node connects here first (AWLAN_Node.redirector_addr, i.e. the
      RDK SONURL). We read the node's AWLAN_Node row and answer by writing
      AWLAN_Node.manager_addr = tcp:<advertise>:<controller-port>; the node's
      cm then moves to the controller.

  controller  (--controller-port, default 6641)
      list_dbs, get_schema, then one `monitor` over every table and column
      of the node's Open_vSwitch database. The initial dump and all updates
      are applied to an in-memory mirror per node (queried with noc-ctl).
      Echo requests from the node are answered, so the session stays up.

Capture: <data>/sessions/<node>/<utc-ts>-<role>-<peer>.jsonl, one line per
JSON-RPC message: {"t": epoch, "dir": "rx"|"tx", "role", "peer", "msg"}.
The latest schema per node is kept in <data>/nodes/<node>/schema.json and a
mirror snapshot in <data>/nodes/<node>/tables.json (rewritten on change).

Mesh (--mesh-gateway): orchestrates a location -- the gateway's backhaul AP,
a GRE per extender (pod) on it, and the pods' fronthaul -- as the cloud does
(mesh.py).

Web UI (--http-port, default 8640): GET / serves webui/index.html, a live
view of the location's topology; GET /api/topology returns it as JSON
(topology.py).

Control: newline-delimited JSON on the unix socket <data>/noc.sock (see
noc-ctl). Commands: nodes, tables, dump, request, transact.

Standard library only.
"""

import argparse
import asyncio
import itertools
import json
import logging
import os
import time

import mesh
import topology

log = logging.getLogger("local-noc")
WEBUI = os.path.join(os.path.dirname(os.path.realpath(__file__)), "webui")


class JsonStream:
    """Incremental decoder for a stream of concatenated JSON texts."""

    def __init__(self):
        self.buf = ""
        self.dec = json.JSONDecoder()

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            s = self.buf.lstrip()
            if not s:
                self.buf = ""
                break
            try:
                obj, end = self.dec.raw_decode(s)
            except json.JSONDecodeError:
                self.buf = s          # incomplete: wait for more bytes
                break
            out.append(obj)
            self.buf = s[end:]
        return out


class Session:
    """One OVSDB JSON-RPC connection opened by a node's ovsdb-server."""

    ids = itertools.count(1)

    def __init__(self, noc, role, reader, writer):
        self.noc, self.role = noc, role
        self.reader, self.writer = reader, writer
        peer = writer.get_extra_info("peername")
        self.peer = f"{peer[0]}:{peer[1]}" if peer else "?"
        self.node = None                    # AWLAN_Node.id once known
        self.pending = {}                   # request id -> future
        self.tables = {}                    # table -> uuid -> row (monitor mirror)
        self.schema = None
        self.started = time.time()
        self.capture = None
        self._open_capture(f"peer-{self.peer.split(':')[0]}")

    # -- capture ---------------------------------------------------------------
    def _open_capture(self, who):
        d = os.path.join(self.noc.data, "sessions", who)
        os.makedirs(d, exist_ok=True)
        ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(self.started))
        path = os.path.join(d, f"{ts}-{self.role}-{self.peer.replace(':', '_')}.jsonl")
        if self.capture:                    # node identified: move the file
            self.capture.close()
            os.replace(self.capture_path, path)
            self.capture = open(path, "a", buffering=1)
        else:
            self.capture = open(path, "a", buffering=1)
        self.capture_path = path

    def _record(self, direction, msg):
        self.capture.write(json.dumps({"t": round(time.time(), 3), "dir": direction,
                                       "role": self.role, "peer": self.peer,
                                       "msg": msg}) + "\n")

    def identify(self, node_id):
        if node_id and node_id != self.node:
            self.node = node_id
            self._open_capture(node_id)
            log.info("%s %s is node %s", self.role, self.peer, node_id)

    # -- transport -------------------------------------------------------------
    def send(self, msg):
        self._record("tx", msg)
        self.writer.write(json.dumps(msg).encode())

    async def request(self, method, params, timeout=30):
        rid = next(Session.ids)
        fut = asyncio.get_running_loop().create_future()
        self.pending[rid] = fut
        self.send({"id": rid, "method": method, "params": params})
        try:
            return await asyncio.wait_for(fut, timeout)
        finally:
            self.pending.pop(rid, None)

    async def reader_loop(self):
        stream = JsonStream()
        while True:
            data = await self.reader.read(65536)
            if not data:
                return
            for msg in stream.feed(data.decode("utf-8", "replace")):
                self._record("rx", msg)
                self.dispatch(msg)

    def dispatch(self, msg):
        method = msg.get("method")
        if method is None:                                  # a response
            fut = self.pending.get(msg.get("id"))
            if fut and not fut.done():
                fut.set_result(msg)
        elif method == "echo":                              # keepalive probe
            self.send({"id": msg.get("id"), "result": msg.get("params", []), "error": None})
        elif method == "update":                            # monitor notification
            params = msg.get("params", [])
            if len(params) == 2:
                self.apply_update(params[1])
        elif msg.get("id") is not None:                     # anything else: refuse politely
            self.send({"id": msg["id"], "result": None, "error": "not supported"})

    # -- monitor mirror --------------------------------------------------------
    def apply_update(self, updates):
        for table, rows in (updates or {}).items():
            t = self.tables.setdefault(table, {})
            for uuid, change in rows.items():
                new = change.get("new")
                if new is None:
                    t.pop(uuid, None)
                else:
                    t.setdefault(uuid, {}).update(new)
        awlan = self.tables.get("AWLAN_Node")
        if awlan:
            self.identify(next(iter(awlan.values())).get("id"))
        self.noc.snapshot(self)

    # -- roles -----------------------------------------------------------------
    async def run(self):
        log.info("%s connection from %s", self.role, self.peer)
        reader = asyncio.create_task(self.reader_loop())
        role = asyncio.create_task(self.redirect() if self.role == "redirector" else self.control())
        try:
            # The session lives as long as the peer keeps the connection open.
            # A peer that goes away (EOF) ends it at once, even mid-request
            # (e.g. a port probe); a failed role step ends it too.
            done, _ = await asyncio.wait({reader, role}, return_when=asyncio.FIRST_COMPLETED)
            if role in done:
                role.result()                       # raise the role's error, if any
                await reader                        # role done: keep serving until EOF
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        except Exception as e:                              # noqa: BLE001
            log.warning("%s %s: %r", self.role, self.peer, e)
        finally:
            role.cancel()
            reader.cancel()
            self.noc.sessions.discard(self)
            log.info("%s %s (%s) closed after %.0fs", self.role, self.peer,
                     self.node or "?", time.time() - self.started)
            self.capture.close()
            self.writer.close()

    async def redirect(self):
        r = await self.request("transact", ["Open_vSwitch", {
            "op": "select", "table": "AWLAN_Node", "where": [],
            "columns": ["id", "serial_number", "model", "firmware_version",
                        "redirector_addr", "manager_addr"]}])
        rows = (r.get("result") or [{}])[0].get("rows", [])
        if rows:
            self.identify(rows[0].get("id"))
            log.info("redirector: node %s serial %s model %s fw %s",
                     rows[0].get("id"), rows[0].get("serial_number"),
                     rows[0].get("model"), rows[0].get("firmware_version"))
        target = f"tcp:{self.noc.advertise}:{self.noc.controller_port}"
        r = await self.request("transact", ["Open_vSwitch", {
            "op": "update", "table": "AWLAN_Node", "where": [],
            "row": {"manager_addr": target}}])
        log.info("redirector: %s -> manager_addr=%s (%s)", self.node or self.peer, target,
                 "ok" if not r.get("error") else r.get("error"))

    async def control(self):
        dbs = (await self.request("list_dbs", [])).get("result") or []
        db = "Open_vSwitch" if "Open_vSwitch" in dbs else (dbs[0] if dbs else "Open_vSwitch")
        self.schema = (await self.request("get_schema", [db])).get("result")
        requests = {t: {} for t in (self.schema or {}).get("tables", {})}   # all columns
        r = await self.request("monitor", [db, "local-noc", requests], timeout=120)
        if r.get("error"):
            raise RuntimeError(f"monitor failed: {r['error']}")
        self.apply_update(r.get("result"))
        self.noc.save_schema(self)
        log.info("controller: monitoring %d tables of %s on %s", len(requests), db,
                 self.node or self.peer)


class Noc:
    def __init__(self, args):
        self.data = args.data
        self.advertise = args.advertise
        self.controller_port = args.controller_port
        self.location = args.location
        self.sessions = set()
        self.topology = topology.Topology(self)
        os.makedirs(self.data, exist_ok=True)

    def node_dir(self, s):
        d = os.path.join(self.data, "nodes", s.node or s.peer.split(":")[0])
        os.makedirs(d, exist_ok=True)
        return d

    def snapshot(self, s):
        if s.role != "controller":
            return
        path = os.path.join(self.node_dir(s), "tables.json")
        with open(path + ".tmp", "w") as f:
            json.dump({"node": s.node, "peer": s.peer, "t": time.time(), "tables": s.tables}, f)
        os.replace(path + ".tmp", path)

    def save_schema(self, s):
        if s.schema:
            with open(os.path.join(self.node_dir(s), "schema.json"), "w") as f:
                json.dump(s.schema, f)

    def handler(self, role):
        async def handle(reader, writer):
            s = Session(self, role, reader, writer)
            self.sessions.add(s)
            await s.run()
        return handle

    def find(self, node):
        cands = [s for s in self.sessions if s.role == "controller" and node in (s.node, s.peer)]
        if not cands:
            raise KeyError(f"no controller session for node {node!r}")
        return max(cands, key=lambda s: s.started)

    async def control(self, reader, writer):
        """noc-ctl: one JSON command per line, one JSON reply per line."""
        while line := await reader.readline():
            try:
                cmd = json.loads(line)
                reply = {"ok": True, "result": await self.command(cmd)}
            except Exception as e:                          # noqa: BLE001
                reply = {"ok": False, "error": f"{type(e).__name__}: {e}"}
            writer.write((json.dumps(reply) + "\n").encode())
            await writer.drain()
        writer.close()

    async def http(self, reader, writer):
        """Minimal HTTP/1.1 for the web UI: GET only, one request per connection."""
        try:
            line = await asyncio.wait_for(reader.readline(), 10)
            while (await asyncio.wait_for(reader.readline(), 10)) not in (b"\r\n", b"\n", b""):
                pass
            parts = line.decode("latin-1").split()
            path = parts[1].split("?")[0] if len(parts) >= 2 else "/"
            if parts[:1] != ["GET"]:
                status, ctype, body = "405 Method Not Allowed", "text/plain", b"GET only\n"
            elif path == "/api/topology":
                status, ctype = "200 OK", "application/json"
                body = json.dumps(self.topology.build()).encode()
            elif path.startswith("/api/node/"):
                # one node's raw OVSDB mirror, as the cloud holds it
                try:
                    sess = self.find(path[len("/api/node/"):])
                    status, ctype = "200 OK", "application/json"
                    body = json.dumps({"node": sess.node, "peer": sess.peer,
                                       "tables": sess.tables}, indent=1).encode()
                except KeyError:
                    status, ctype, body = "404 Not Found", "text/plain", b"no such node\n"
            elif path in ("/", "/index.html"):
                with open(os.path.join(WEBUI, "index.html"), "rb") as f:
                    status, ctype, body = "200 OK", "text/html; charset=utf-8", f.read()
            else:
                status, ctype, body = "404 Not Found", "text/plain", b"not found\n"
            writer.write((f"HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\n"
                          f"Content-Length: {len(body)}\r\nCache-Control: no-store\r\n"
                          "Connection: close\r\n\r\n").encode() + body)
            await writer.drain()
        except (asyncio.TimeoutError, ConnectionError, OSError):
            pass
        except Exception as e:                              # noqa: BLE001
            log.warning("http: %r", e)
        finally:
            writer.close()

    async def command(self, cmd):
        c = cmd.get("cmd")
        if c == "nodes":
            return [{"node": s.node, "role": s.role, "peer": s.peer,
                     "since": round(s.started), "tables": len(s.tables),
                     "capture": s.capture_path} for s in sorted(self.sessions, key=lambda s: s.started)]
        s = self.find(cmd["node"])
        if c == "tables":
            return {t: len(rows) for t, rows in sorted(s.tables.items())}
        if c == "dump":
            return list(s.tables.get(cmd["table"], {}).values())
        if c == "transact":
            return (await s.request("transact", ["Open_vSwitch", *cmd["ops"]])).get("result")
        if c == "request":
            return await s.request(cmd["method"], cmd.get("params", []))
        raise ValueError(f"unknown command {c!r}")


async def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--listen", default="0.0.0.0")
    ap.add_argument("--redirector-port", type=int, default=6640)
    ap.add_argument("--controller-port", type=int, default=6641)
    ap.add_argument("--advertise", required=True,
                    help="address nodes reach the controller on (goes into manager_addr)")
    ap.add_argument("--data", default="/var/lib/local-noc")
    ap.add_argument("--http-port", type=int, default=8640, help="web UI (0 = off)")
    ap.add_argument("--location", default="opensync-lab", help="location name shown in the web UI")
    mesh.add_args(ap)
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    noc = Noc(args)
    sock = os.path.join(noc.data, "noc.sock")
    if os.path.exists(sock):
        os.unlink(sock)
    servers = [
        await asyncio.start_server(noc.handler("redirector"), args.listen, args.redirector_port),
        await asyncio.start_server(noc.handler("controller"), args.listen, args.controller_port),
        await asyncio.start_unix_server(noc.control, sock),
    ]
    if args.http_port:
        servers.append(await asyncio.start_server(noc.http, args.listen, args.http_port))
    log.info("local-noc: redirector tcp:%s:%d, controller tcp:%s:%d (advertised as %s), "
             "web UI http:%s:%d, data %s", args.listen, args.redirector_port, args.listen,
             args.controller_port, args.advertise, args.listen, args.http_port, noc.data)
    tasks = [s.serve_forever() for s in servers]
    if args.mesh_gateway:
        tasks.append(mesh.Mesh(noc, args).run())
    await asyncio.gather(*tasks)


if __name__ == "__main__":
    asyncio.run(main())
