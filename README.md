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
4. **Adds an OpenSync extender.** A pod built from the open-source OpenSync
   release (6.6.1.0) runs as a container with only hwsim radios. It joins
   mv3's Wi-Fi backhaul, builds its GRE uplink, and is claimed by `local-noc`,
   which acts as the cloud. A wireless client on the pod's fronthaul reaches
   the internet through pod → GRE → mv3.

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
                                                         pod ── bhaul-sta-50 ─ g-bhaul-sta-50 ─ br-home
                                                                  home-ap-24 ((( 2.4 GHz )))
                                                         wclient (alpine) ── wlan0 ─ wpa_supplicant
```

## Status

Working end to end, reproduced from a fresh VM with the scripts alone (2026-09-23, VM `opensync-lab-0923`):

| Goal | Result |
|---|---|
| Pinned offline build | `mv3-lxd-r25-oe40-0922`: installed packages identical to the 0808 reference, all recorded SRCREVs match the pins |
| mv3 internet | erouter0 leases `10.70.0.x` from boardfarm Kea on tagged VLAN 1081; internet, DNS and TLS to the Plume redirector all work |
| OpenSync cloud | `Manager` ACTIVE on the theta dev controller; the `mv3` identity is claimed into a location and receives cloud config |
| Local cloud (local-noc) | the same node connects to `local-noc` over plain TCP (redirector -> controller, all 109 tables monitored and recorded) and switches back and forth with the Plume cloud |
| GRE backhaul | OpenSync `nm` builds the gretap on both ends over an hwsim RF backhaul to a second node (`mv3-002`); a Wi-Fi client behind it gets DHCP and internet through the tunnel |
| OpenSync extender | an OpenSync 6.6.1.0 pod with only hwsim radios joins mv3's backhaul AP, builds its GRE uplink (`cm`), is claimed by local-noc through it and gets its fronthaul; local-noc builds mv3's end of the tunnel. An Alpine `wpa_supplicant` client on the pod's fronthaul gets DHCP from mv3 and reaches the internet (ICMP, DNS, HTTP) |

In the `mv3-002` path the GRE is real OpenSync but its config is injected
locally: the Plume cloud pushes backhaul/GRE config only once a pod exists in
the location (see [doc/PLAN.md](doc/PLAN.md) §1.4). In the extender path, all
of it goes through the cloud protocol, with local-noc as the cloud.

### Workarounds this lab applies (and where the real fix belongs)

| Problem | Lab workaround | Proper fix |
|---|---|---|
| mv3 LXD image selects no OpenSync NOC certificates (only `do_install:append:f5685` does), so `cm` stays in BACKOFF | `guest/50-opensync.sh` links `/usr/opensync/etc/certs/*` -> `theta-dev/` and restarts `cm` | `doc/proposed/0001-*.patch` for meta-lxd-mv3 (untested) |
| With SON on, `dnsmasq` refuses to start (`bind-interfaces` + missing `wl0.1`/`wl1.1`), so LAN DHCP breaks | `fix_lan_dhcp` in `guest/common.sh` restarts it with `bind-dynamic` | same proposed patch (utopia) |
| mv3's MeshAgent crashes on the empty `SONURL` that `sim-mesh.sh` uses | `guest/60-gre.sh` enables SON on the leaf with the real redirector | meta-lxd `gen/sim-mesh.sh` |
| On mv3, `brlan0` is an OVS bridge with SON on; `sim-mesh.sh` uses `ip link set master` | `guest/60-gre.sh` uses `ovs-vsctl add-port` | meta-lxd `gen/sim-mesh.sh` |
| boardfarm `bf-wan` build: Debian bullseye security packages now 404 | `boardfarm/patches/0001` | boardfarm-lab-staging |
| boardfarm `wan-cpe1`: docker 28+ can make the non-masqueraded eth1 the default route, so the WAN side has no internet | `boardfarm/patches/0002` | boardfarm-lab-staging |
| The lab gives CPEs global IPv6 but rev140 has no IPv6 internet: `cm` prefers IPv6 and waits out a timeout per attempt | boardfarm rebuild hook makes `wan-cpe1` reject non-lab IPv6 (TCP reset), so `cm` fails over to IPv4 at once | a lab with IPv6 upstream (the hook then does nothing) |
| hal-wifi-hwsim: (1) never reports the VAP security, so mv3's `wm` sees config ≠ state; this build's `wm` also re-applies non-home VIFs every 30 s regardless, and each re-apply restarted every BSS of the radio (`STOP_AP`), silently dropping associated stations; (2) its MLME never removes a station (no deauth/disassoc handling, stale entry on re-auth), so a returning STA never completes the 4-way handshake. Together the extender lost the backhaul and could not rejoin | `meta-mvx/` patches 0001 (report security and real BSS state, keep a running BSS running) and 0002 (forget a station on deauth/disassoc/re-auth), added by `build-mvx.sh` | hal-wifi-hwsim |
| mv3's `cm` (OpenSync 4.4) picks the uplink's address family once: with a global IPv6 on erouter0 it takes IPv6 and never evaluates IPv4 until the IPv4 address changes. Whenever OpenSync (re)starts on a WAN that is already up (e.g. a cloud switch), it then retries IPv6 forever, and this lab has no IPv6 upstream. First boot also leaves `Connection_Manager_Uplink.ipv4` unset | `guest/50-opensync.sh`: while `cm` is not connected and there is no IPv6 internet, sets `ipv6=blocked` (and `ipv4=ready`) on the uplink and restarts `cm` via `Node_Services` | OpenSync cm2 / RDK target; or a lab with IPv6 upstream |
| OpenSync 6.6.1.0: `cm2` builds an extender's GRE only for the STAs in `CONFIG_OVSDB_BOOTSTRAP_WIFI_STA_LIST`; the OVSDB bootstrap then needs unquoted `BACKHAUL_SSID/PASS` (the `local` provider quotes them) | our `HWSIM_POD` target sets the list; `mvx-local` provider unquoted | opensync-service-provider-local |
| mac80211_hwsim radios are multi-band; OpenSync assumes one band per phy (duplicate channels, VIF naming) | `pod/opensync/patches/core/0001` (per-phy band filter), `build-pod.sh` band-by-position for `52_owm_prep.sh`, the pod's backhaul STA on 5G only | wmediumd/hwsim band config, or OpenSync |
| Repo mirror is older than the 0808 build (11 pinned commits missing) | pin store `~/yocto/repo_reference/mvx-pins/<pins>` | refresh the mirror |
| Shared sstate object with a stale absolute path (libwebsockets) | `build-mvx.sh` rebuilds such recipes locally | libwebsockets recipe |

See **[doc/PLAN.md](doc/PLAN.md)** for the design, phases and open questions.

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
./deploy-mvx.sh all                       # push, launch, WAN check, OpenSync cloud, GRE backhaul
./deploy-mvx.sh opensync --cloud local    # switch the node to local-noc (or --cloud plume)
./deploy-mvx.sh noc nodes | tables mv3 | dump mv3 <table> | log mv3 [N] | transact mv3 '<op>'
./deploy-mvx.sh check | status | shell

# 4. OpenSync extender (pod) + wireless client, orchestrated by local-noc
./build-pod.sh all                        # OpenSync 6.6.1.0 -> pod LXD image (~/yocto/mvx-pod-work)
./deploy-mvx.sh mesh                      # opensync --cloud local + pod + client
./deploy-mvx.sh pod | client              # or one at a time
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
build-mvx.sh  setup-vm.sh  deploy-mvx.sh  build-pod.sh   entry points (run on rev140)
config/       mvx.conf defaults (+ untracked local.conf)
lib/          host-side helpers (common.sh, vm.sh, pin-manifest.py)
local-noc/    local OpenSync cloud (noc.py, mesh.py, noc-ctl, Dockerfile)
meta-mvx/     bbappends + patches on top of the pinned layers (hal-wifi-hwsim)
pod/          OpenSync extender: sources.lock, target/provider overlays, patches, build env, image
pins/         pinned manifest, layer commits, SRCREVs, reference package list
guest/        scripts + units pushed to /opt/opensync-lab in the VM
boardfarm/    lab config overlaid into boardfarm-lab-staging/lab/ (bf-lab only), patches
doc/          PLAN.md
```

## Building blocks (reused, not forked)

| Component | Location | Role |
|---|---|---|
| `meta-lxd` (`rnl25-oe40`) | `~/git/meta-lxd` | LXD image class, `hal-wifi-hwsim` recipe, `gen/mv.sh` launcher, `gen/gen-util.sh` hwsim pool, `gen/sim-mesh.sh` |
| `meta-lxd-mv3` (`rnl25-oe40`) | `~/git/meta-lxd-mv3` | mv3 LXD machine; selects `hal-wifi-hwsim` as the Wi-Fi HAL |
| `hal-wifi-hwsim` | `~/git/hal-wifi-hwsim` | nl80211 `wifi_hal.h` implementation (multi-BSS home + backhaul VAPs) |
| build tooling | `~/git/redkite/notes/rdk-b/bash` (`do-lxd.sh`, `git-offline.sh`), `~/yocto/mv-builds` | checkout and offline-redirect logic this project wraps |
| boardfarm-lab-staging | `github.com:robvogelaar/boardfarm-lab-staging` | `bf-lab` WAN/DHCP/LAN Docker lab, `tests/opensync` |
| OpenSync 6.6.1.0 (open source) | github.com/plume-design: `opensync`, `opensync-platform-cfg80211`, `opensync-vendor-openwrt-template`, `opensync-service-provider-local` | the extender (pod), pinned in `pod/opensync/sources.lock` |
| LXD-VM appliance pattern | `~/yocto/easymesh-bpi/meta-cmf-bananapi-vcpe/gen/vm` | template for VM creation, asset bundling, and boardfarm-in-VM |

## Documentation

- [doc/PLAN.md](doc/PLAN.md): the detailed implementation plan
- `~/git/meta-lxd/docs/hwsim.md`: the hwsim radio pool and Wi-Fi HAL providers
- `~/git/meta-lxd/docs/opensync-mesh-hwsim.md`: OpenSync GRE mesh over hwsim
- `~/git/hal-wifi-hwsim/SETUP.md`: OpenSync over 802.11 simulation: what has been proven
- `~/yocto/mv-builds/README.md`: the mvx build manual
