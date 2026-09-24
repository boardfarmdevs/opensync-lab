# opensync-lab

Reproducible, one-command lab for an **OpenSync-enabled containerized RDK-B
gateway** (the LGI "mvx" products, starting with **mv3**). It:

1. **Builds** the LXD mv3 image from a *fresh* `repo init`. The build is pinned
   to the exact manifest project revisions, `meta-lxd*` layer commits, and
   AUTOREV `SRCREV`s of a known-good reference build (default
   `~/yocto/mv3-lxd-r25-oe40-0808`). It uses the local repo mirror
   `~/yocto/repo_reference/mv3-r25-oe40-repo_reference`, so it also works
   offline without the bitbucket VPN.
2. **Creates an LXD VM** (e.g. `opensync-lab-0923`) as an isolated lab host. Inside it:
   - **boardfarm-lab** Docker containers provide the WAN side: a Kea DHCP server
     plus a NAT gateway (`dhcp-cpe1`, `wan-cpe1` on `br-wan101`);
   - a **mac80211_hwsim radio pool** supplies simulated Wi-Fi radios;
   - the **mv3 container** is launched with `meta-lxd/gen/mv.sh`. It gets its WAN
     through boardfarm and 3 hwsim radios driven by the `hal-wifi-hwsim` Wi-Fi HAL.
3. **Brings up OpenSync.** SON is enabled, the node connects to its cloud
   (the Plume redirector) over the WAN, and the home and backhaul VAPs and the
   GRE backhaul network that external OpenSync nodes (extenders/pods) join are
   built.
4. **Adds OpenSync extenders.** Three pods built from the open-source
   OpenSync release (6.6.1.0) run as containers with only hwsim radios. Each
   joins mv3's Wi-Fi backhaul, builds its GRE uplink, and is claimed by
   `local-noc`, which acts as the cloud. Two wireless clients on each pod's
   fronthaul reach the internet through pod → GRE → mv3.

```
 rev140 (host)                                     LXD VM  opensync-lab-MMDD
 ─────────────                                     ───────────────────────────────────────────
 ~/yocto/mv3-lxd-r25-oe40-MMDD  ── image ──►       docker: dhcp-cpe1 (Kea)   wan-cpe1 (NAT) ─► internet
   (pinned fresh build)                                         │ br-wan101 (802.1Q 1081 / 881)
 ~/git/meta-lxd       ── bundle ──►                        local-noc (10.101.0.40, OVSDB cloud)
 boardfarm-lab-staging ── bundle ──►               LXD:  mv3 ── eth0 → erouter0 ── OpenSync cm ─► cloud
 ~/yocto/mvx-pod-work ── pod image ──►                      ├── eth1 → br-lan201 (lan-cpe1)
   (OpenSync 6.6.1.0)                                       └── wlan0/1/2 ◄── mac80211_hwsim pool
                                                                  wl1.1 backhaul AP  ((( 5 GHz )))
                                                                        │ gretap pgd* in brlan0
                                          pod-1, pod-2, pod-3 ── bhaul-sta-50 ─ g-bhaul-sta-50 ─ br-home
                                                                  home-ap-24 ((( 2.4 GHz )))
                                   pod-N-wc1, pod-N-wc2 (alpine) ── wlan0 ─ wpa_supplicant
```

## Status

Working end to end, reproduced from a fresh VM with the scripts alone (2026-09-23, VM `opensync-lab-0923`):

| Goal | Result |
|---|---|
| Pinned offline build | `mv3-lxd-r25-oe40-0923`: installed packages identical to the 0808 reference, all recorded SRCREVs match the pins |
| mv3 internet | erouter0 leases `10.70.0.x` from boardfarm Kea on tagged VLAN 1081; internet, DNS and TLS to the Plume redirector all work |
| OpenSync cloud | `Manager` ACTIVE on the theta dev controller; the `mv3` identity is claimed into a location and receives cloud config |
| Local cloud (local-noc) | the same node connects to `local-noc` over plain TCP (redirector -> controller, all 109 tables monitored and recorded) and switches back and forth with the Plume cloud |
| Topology view | local-noc's web UI on `http://<host>:8640/` shows the live location: 1 gateway, 3 extenders, 6 clients, their Wi-Fi links (band, channel) and the WAN, with draggable spring physics and per-node details |
| OpenSync extenders (GRE backhaul) | three OpenSync 6.6.1.0 pods with only hwsim radios join mv3's backhaul AP, build their GRE uplinks (`cm`), are claimed by local-noc through them and get their fronthaul; local-noc builds mv3's end of each tunnel. Two Alpine `wpa_supplicant` clients per pod, each pinned to its pod's fronthaul, get DHCP from mv3 and reach the internet (ICMP, DNS, HTTP) |

All of the mesh configuration goes through the cloud protocol, with local-noc
as the cloud.

### Workarounds this lab applies (and where the real fix belongs)

| Problem | Lab workaround | Proper fix |
|---|---|---|
| mv3 LXD image selects no OpenSync NOC certificates (only `do_install:append:f5685` does), so `cm` stays in BACKOFF | `guest/50-opensync.sh` links `/usr/opensync/etc/certs/*` -> `theta-dev/` and restarts `cm` | `docs/proposed/0001-*.patch` for meta-lxd-mv3 (untested) |
| With SON on, `dnsmasq` refuses to start (`bind-interfaces` + missing `wl0.1`/`wl1.1`), so LAN DHCP breaks | `fix_lan_dhcp` in `guest/common.sh` restarts it with `bind-dynamic` | same proposed patch (utopia) |
| boardfarm `bf-wan` build: Debian bullseye security packages now 404 | `boardfarm/patches/0001` | boardfarm-lab-staging |
| boardfarm `wan-cpe1`: docker 28+ can make the non-masqueraded eth1 the default route, so the WAN side has no internet | `boardfarm/patches/0002` | boardfarm-lab-staging |
| The lab gives CPEs global IPv6 but rev140 has no IPv6 internet: `cm` prefers IPv6 and waits out a timeout per attempt | boardfarm rebuild hook makes `wan-cpe1` reject non-lab IPv6 (TCP reset), so `cm` fails over to IPv4 at once | a lab with IPv6 upstream (the hook then does nothing) |
| hal-wifi-hwsim: (1) never reports the VAP security, so mv3's `wm` sees config ≠ state; this build's `wm` also re-applies non-home VIFs every 30 s regardless, and each re-apply restarted every BSS of the radio (`STOP_AP`), silently dropping associated stations; (2) its MLME never removes a station (no deauth/disassoc handling, stale entry on re-auth), so a returning STA never completes the 4-way handshake. Together the extender lost the backhaul and could not rejoin | `meta-mvx/` patches 0001 (report security and real BSS state, keep a running BSS running) and 0002 (forget a station on deauth/disassoc/re-auth), added by `build-mvx.sh` | hal-wifi-hwsim |
| mv3's `cm` (OpenSync 4.4) picks the uplink's address family once: with a global IPv6 on erouter0 it takes IPv6 and never evaluates IPv4 until the IPv4 address changes. Whenever OpenSync (re)starts on a WAN that is already up (e.g. a cloud switch), it then retries IPv6 forever, and this lab has no IPv6 upstream. First boot also leaves `Connection_Manager_Uplink.ipv4` unset | `guest/50-opensync.sh`: while `cm` is not connected and there is no IPv6 internet, sets `ipv6=blocked` (and `ipv4=ready`) on the uplink and restarts `cm` via `Node_Services` | OpenSync cm2 / RDK target; or a lab with IPv6 upstream |
| OpenSync 6.6.1.0 osw: `owm` aborts when its config sync has not settled in 180 s; with a `tx_chainmask` configured it never settles on mac80211_hwsim (no chains reported), so every pod dropped its backhaul, GRE and cloud session every 3 minutes | the pod bootstrap sets no `tx_chainmask` | hwsim / OpenSync osw (tolerate an unsupported chainmask) |
| OpenSync 6.6.1.0: `cm2` builds an extender's GRE only for the STAs in `CONFIG_OVSDB_BOOTSTRAP_WIFI_STA_LIST`; the OVSDB bootstrap then needs unquoted `BACKHAUL_SSID/PASS` (the `local` provider quotes them) | our `HWSIM_POD` target sets the list; `mvx-local` provider unquoted | opensync-service-provider-local |
| mac80211_hwsim radios are multi-band; OpenSync assumes one band per phy (duplicate channels, VIF naming) | `pod/opensync/patches/core/0001` (per-phy band filter), `build-pod.sh` band-by-position for `52_owm_prep.sh`, the pod's backhaul STA on 5G only | wmediumd/hwsim band config, or OpenSync |
| Repo mirror is older than the 0808 build (11 pinned commits missing) | pin store `~/yocto/repo_reference/mvx-pins/<pins>` | refresh the mirror |
| Shared sstate object with a stale absolute path (libwebsockets) | `build-mvx.sh` rebuilds such recipes locally | libwebsockets recipe |

See **[docs/PLAN.md](docs/PLAN.md)** for the design, phases and open questions.

## Usage

There are three scripts, one per stage. Each subcommand can be re-run safely.

```sh
# 1. mv3 container image: fresh checkout, pinned to the reference build, offline
./build-mvx.sh pin       # once: pins/mv3-r25-oe40-0808/ + pin store under ~/yocto/repo_reference/mvx-pins/
./build-mvx.sh build     # -> ~/yocto/mv3-lxd-r25-oe40-<MMDD>
./build-mvx.sh status

# 2. lab VM: docker + boardfarm WAN side, nested LXD, mac80211_hwsim pool
./setup-vm.sh all        # create + provision opensync-lab-<MMDD>
./setup-vm.sh status | shell | stop | start | delete

# 3. deploy the container into the VM and check it
./deploy-mvx.sh all                       # push, launch, WAN check, OpenSync cloud
./deploy-mvx.sh opensync --cloud local    # switch the node to local-noc (or --cloud plume)
./deploy-mvx.sh noc nodes | tables mv3 | dump mv3 <table> | log mv3 [N] | transact mv3 '<op>'
./deploy-mvx.sh check | status | shell

# 4. OpenSync extenders (pods) + wireless clients, orchestrated by local-noc
./build-pod.sh all                        # OpenSync 6.6.1.0 -> pod LXD image (~/yocto/mvx-pod-work)
./deploy-mvx.sh mesh                      # opensync --cloud local, pod-1..3, 2 clients each, topology check
./deploy-mvx.sh pod pod-2                 # or one at a time
./deploy-mvx.sh client pod-2-wc1 pod-2

# 5. watch it: local-noc's live topology view, from any browser
#    http://<rev140 address>:8640/        (setup-vm.sh status prints the URL)

# documentation site (docs/, GitHub Pages): viewer + reference + a recording of the lab
./build-docs.sh all                       # then commit docs/
./build-docs.sh serve                     # preview on http://localhost:8000/
```

### local-noc: a local OpenSync cloud

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

Settings live in `config/mvx.conf`: product, release, reference build, pins,
VM name and size, boardfarm commit, hwsim pool, and so on. Any of them can be
overridden from the environment. Values the scripts must remember across days,
such as the VM name, are written to the untracked `config/local.conf`.

```
build-mvx.sh  setup-vm.sh  deploy-mvx.sh  build-pod.sh  build-docs.sh   entry points (run on rev140)
config/       mvx.conf defaults (+ untracked local.conf)
lib/          host-side helpers (common.sh, vm.sh, pin-manifest.py)
local-noc/    local OpenSync cloud (noc.py, mesh.py, topology.py, webui/, noc-ctl, Dockerfile)
meta-mvx/     bbappends + patches on top of the pinned layers (hal-wifi-hwsim)
pod/          OpenSync extender: sources.lock, target/provider overlays, patches, build env, image
pins/         pinned manifest, layer commits, SRCREVs, reference package list
guest/        scripts + units pushed to /opt/opensync-lab in the VM
boardfarm/    lab config overlaid into boardfarm-lab-staging/lab/ (bf-lab only), patches
docs/         PLAN.md, proposed/ patches, and the documentation site (GitHub Pages)
```

## Building blocks (reused, not forked)

| Component | Location | Role |
|---|---|---|
| `meta-lxd` (`rnl25-oe40`) | `~/git/meta-lxd` | LXD image class, `hal-wifi-hwsim` recipe, `gen/mv.sh` launcher, `gen/gen-util.sh` hwsim pool |
| `meta-lxd-mv3` (`rnl25-oe40`) | `~/git/meta-lxd-mv3` | mv3 LXD machine; selects `hal-wifi-hwsim` as the Wi-Fi HAL |
| `hal-wifi-hwsim` | `~/git/hal-wifi-hwsim` | nl80211 `wifi_hal.h` implementation (multi-BSS home + backhaul VAPs) |
| build tooling | `~/git/redkite/notes/rdk-b/bash` (`do-lxd.sh`, `git-offline.sh`), `~/yocto/mv-builds` | checkout and offline-redirect logic this project wraps |
| boardfarm-lab-staging | `github.com:robvogelaar/boardfarm-lab-staging` | `bf-lab` WAN/DHCP/LAN Docker lab, `tests/opensync` |
| OpenSync 6.6.1.0 (open source) | github.com/plume-design: `opensync`, `opensync-platform-cfg80211`, `opensync-vendor-openwrt-template`, `opensync-service-provider-local` | the extender (pod), pinned in `pod/opensync/sources.lock` |
| LXD-VM appliance pattern | `~/yocto/easymesh-bpi/meta-cmf-bananapi-vcpe/gen/vm` | template for VM creation, asset bundling, and boardfarm-in-VM |

## Documentation

- **The documentation site**: `docs/`, published with GitHub Pages (Settings,
  Pages, deploy from branch `main`, folder `/docs`). It is generated by
  `build-docs.sh`: the reference tables come from the repository, and the
  topology viewer is local-noc's own, replaying a recording of the lab.
- [docs/PLAN.md](docs/PLAN.md): the detailed implementation plan
- `~/git/meta-lxd/docs/hwsim.md`: the hwsim radio pool and Wi-Fi HAL providers
- `~/git/meta-lxd/docs/opensync-mesh-hwsim.md`: OpenSync GRE mesh over hwsim
- `~/git/hal-wifi-hwsim/SETUP.md`: OpenSync over 802.11 simulation: what has been proven
- `~/yocto/mv-builds/README.md`: the mvx build manual
