"""Shared by local-noc's tests: its modules on the path, OVSDB value helpers, a fake
controller session that records what local-noc asks of a node, and the mesh's arguments.
Standard library only, like local-noc itself."""

import argparse
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "local-noc"))
sys.dont_write_bytecode = True      # leave local-noc/ as checked out

import mesh  # noqa: E402
import noc  # noqa: E402
import topology  # noqa: E402

__all__ = ["mesh", "noc", "topology", "ROOT", "ref", "oset", "omap", "FakeSession",
           "mesh_args", "transact_ops"]


def ref(u):
    """An OVSDB uuid reference."""
    return ["uuid", u]


def oset(*vals):
    return ["set", list(vals)]


def omap(**kv):
    return ["map", [[k, v] for k, v in kv.items()]]


class FakeSession:
    """A controller session as mesh.py and topology.py see it: a node id, its monitor
    mirror (table -> uuid -> row) and request(); each request is recorded and answered
    as a node's ovsdb-server would (one empty result per transact operation)."""

    def __init__(self, node, tables, role="controller", peer="10.0.0.2:40000"):
        self.node, self.tables, self.role, self.peer = node, tables, role, peer
        self.started = time.time()
        self.requests = []

    async def request(self, method, params, timeout=30):
        self.requests.append((method, params))
        ops = params[1:] if method == "transact" else []
        return {"id": len(self.requests), "result": [{} for _ in ops], "error": None}


def transact_ops(session):
    """Every operation local-noc sent the session, in order."""
    return [op for method, params in session.requests if method == "transact"
            for op in params[1:]]


def mesh_args(*argv):
    """local-noc's mesh arguments, parsed as noc.py parses them."""
    ap = argparse.ArgumentParser()
    mesh.add_args(ap)
    return ap.parse_args(["--mesh-gateway", "gw", *argv])
