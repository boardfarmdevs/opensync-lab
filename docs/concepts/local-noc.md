# local-noc: a local OpenSync cloud

[Documents](../README.md)

`local-noc/` is a stand-in for the OpenSync cloud. It runs as a Docker
container in the lab VM on boardfarm's WAN segment (`10.101.0.40`, network
`wan-cpe1`) and speaks the cloud's OVSDB JSON-RPC protocol over plain TCP:

- **redirector** (`tcp:10.101.0.40:6640`, what `SONURL` points at): reads the
  node's `AWLAN_Node` and assigns `manager_addr = tcp:10.101.0.40:6641`;
- **controller** (`:6641`): `list_dbs`, `get_schema`, then `monitor` on every
  table; answers the node's `echo` probes and keeps a live mirror of its
  database.

**Topology view.** local-noc also serves a web UI (port 8640, published on
the host by `setup-vm.sh`: `http://<host address>:8640/`). It draws the
location it holds, live: the gateway (drawn as a router) with its WAN link
to the internet, the extenders (drawn as plug-in pods) on their Wi-Fi
backhaul, clients on their extender's or gateway's AP. Every Wi-Fi link is a
spring, coloured by band and badged with its channel. The layout is a force
simulation that settles and then stands still; drag any node and the others
follow on their springs, which shimmy while you drag. Drag the background to
pan, use the wheel to zoom, double-click to pin a node.

The configuration and traffic are one hover or click away, never in the way:
- hover a node for its active configuration: an extender shows its GRE
  uplink (both endpoints, parent interface), the gateway's end of it, its
  LAN bridge and ports, fronthaul, cloud state and tunnel traffic; the router
  its WAN/LAN, APs, tunnels and leases; hover a link for the tunnel or client;
- click a node for everything, in collapsible sections: interfaces (with GRE
  endpoints and states), bridge ports with packet/byte/error counters and
  rates, GRE tunnels, radios, Wi-Fi interfaces, the uplink monitor, cloud
  session, DHCP leases, MAC table, and the node's raw OVSDB tables
  (`/api/node/<id>`);
- the collapsed **Network** drawer lists every tunnel with live rates, all
  Wi-Fi links, the cloud sessions and the leases.

Counters are the gateway's OVS port counters (the extenders run no
ovs-vswitchd); local-noc sets mv3's OVS `stats-update-interval` to 5 s
(`--mesh-stats-interval`, mv3 ships 1 hour) so they are current. Nodes
that lose their session stay on the map, greyed out, for 10 minutes. The data
behind it is `GET /api/topology` (`local-noc/topology.py`), built from the
same OVSDB mirrors `noc-ctl` shows.

With `--mesh-gateway` (set by the VM provisioning), local-noc also
orchestrates the location like the cloud (`local-noc/mesh.py`): it enables
the gateway's backhaul AP, creates the gateway's end of each extender's GRE
and adds it to `brlan0`, and gives every extender that connects its
fronthaul AP. SSIDs and keys are `MVX_MESH_*` in `config/mvx.conf`.

Every message in both directions is recorded, one JSON line each, in
`/var/lib/local-noc/sessions/<node>/*.jsonl`, together with the node's schema
and a table snapshot. `noc-ctl`, reached as `./deploy-mvx.sh noc …`, lists
sessions, dumps tables, tails the capture, and sends `transact` or raw
requests, so it can act as the cloud too. A node switches between clouds
with `deploy-mvx.sh opensync --cloud plume|local`.
