# mvx-opensync

Reproducible, one-command lab for an **OpenSync-enabled containerized RDK-B
gateway** (the LGI "mvx" products, starting with **mv3**). It:

1. **Builds** the LXD mv3 image from a *fresh* `repo init`. The build is pinned
   to the exact manifest project revisions, `meta-lxd*` layer commits, and
   AUTOREV `SRCREV`s of a known-good reference build (default
   `~/yocto/mv3-lxd-r25-oe40-0808`). It uses the local repo mirror
   `~/yocto/repo_reference/mv3-r25-oe40-repo_reference`, so it also works
   offline without the bitbucket VPN.
2. **Creates an LXD VM** (e.g. `mvx-opensync-0922`) as an isolated lab host. Inside it:
   - **boardfarm-lab** Docker containers provide the WAN side: a Kea DHCP server
     plus a NAT gateway (`dhcp-cpe1`, `wan-cpe1` on `br-wan101`);
   - a **mac80211_hwsim radio pool** supplies simulated Wi-Fi radios;
   - the **mv3 container** is launched with `meta-lxd/gen/mv.sh`. It gets its WAN
     through boardfarm and 3 hwsim radios driven by the `hal-wifi-hwsim` Wi-Fi HAL.
3. **Brings up OpenSync.** SON is enabled, the node connects to its cloud
   (the Plume redirector) over the WAN, and the home and backhaul VAPs and the
   GRE backhaul network that external OpenSync nodes (extenders/pods) join are
   built.

```
 rev140 (host)                                     LXD VM  mvx-opensync-MMDD
 ─────────────                                     ───────────────────────────────────────────
 ~/yocto/mv3-lxd-r25-oe40-MMDD  ── image ──►       docker: dhcp-cpe1 (Kea)   wan-cpe1 (NAT) ─► internet
   (pinned fresh build)                                         │ br-wan101 (802.1Q 1081 / 881)
 ~/git/meta-lxd       ── bundle ──►                LXD:  mv3 ── eth0 → erouter0 ── OpenSync cm ─► cloud
 boardfarm-lab-staging ── bundle ──►                        ├── eth1 → br-lan201 (lan-cpe1)
                                                            └── wlan0/1/2 ◄── mac80211_hwsim pool
```

## Status

Working end to end (2026-09-22, VM `mvx-opensync-0922`):

| Goal | Result |
|---|---|
| Pinned offline build | `mv3-lxd-r25-oe40-0922`: installed packages identical to the 0808 reference, all recorded SRCREVs match the pins |
| mv3 internet | erouter0 leases `10.70.0.x` from boardfarm Kea on tagged VLAN 1081; internet, DNS and TLS to the Plume redirector all work |
| OpenSync cloud | `Manager` ACTIVE on the theta dev controller; the `mv3` identity is claimed into a location and receives cloud config |
| GRE backhaul | OpenSync `nm` builds the gretap on both ends over an hwsim RF backhaul to a second node (`mv3-002`); a Wi-Fi client behind it gets DHCP and internet through the tunnel |

The GRE is real OpenSync, but its config is injected locally: the cloud pushes
backhaul/GRE config only once a pod exists in the location (see
[doc/PLAN.md](doc/PLAN.md) §1.4).

### Workarounds this lab applies (and where the real fix belongs)

| Problem | Lab workaround | Proper fix |
|---|---|---|
| mv3 LXD image selects no OpenSync NOC certificates (only `do_install:append:f5685` does), so `cm` stays in BACKOFF | `guest/50-opensync.sh` links `/usr/opensync/etc/certs/*` -> `theta-dev/` and restarts `cm` | `doc/proposed/0001-*.patch` for meta-lxd-mv3 (untested) |
| With SON on, `dnsmasq` refuses to start (`bind-interfaces` + missing `wl0.1`/`wl1.1`), so LAN DHCP breaks | `fix_lan_dhcp` in `guest/common.sh` restarts it with `bind-dynamic` | same proposed patch (utopia) |
| mv3's MeshAgent crashes on the empty `SONURL` that `sim-mesh.sh` uses | `guest/60-gre.sh` enables SON on the leaf with the real redirector | meta-lxd `gen/sim-mesh.sh` |
| On mv3, `brlan0` is an OVS bridge with SON on; `sim-mesh.sh` uses `ip link set master` | `guest/60-gre.sh` uses `ovs-vsctl add-port` | meta-lxd `gen/sim-mesh.sh` |
| boardfarm `bf-wan` build: Debian bullseye security packages now 404 | `boardfarm/patches/0001` | boardfarm-lab-staging |
| boardfarm `wan-cpe1`: docker 28+ can make the non-masqueraded eth1 the default route, so the WAN side has no internet | `boardfarm/patches/0002` | boardfarm-lab-staging |
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
./setup-vm.sh all        # create + provision mvx-opensync-<MMDD>
./setup-vm.sh status | shell | stop | start | delete

# 3. deploy the container into the VM and check its WAN
./deploy-mvx.sh all      # push image + meta-lxd, mv.sh launch, WAN check
./deploy-mvx.sh check | status | shell
```

Settings live in `config/mvx.conf`: product, release, reference build, pins,
VM name and size, boardfarm commit, hwsim pool, and so on. Any of them can be
overridden from the environment. Values the scripts must remember across days,
such as the VM name, are written to the untracked `config/local.conf`.

```
build-mvx.sh  setup-vm.sh  deploy-mvx.sh     entry points (run on rev140)
config/       mvx.conf defaults (+ untracked local.conf)
lib/          host-side helpers (common.sh, vm.sh, pin-manifest.py)
pins/         pinned manifest, layer commits, SRCREVs, reference package list
guest/        scripts + units pushed to /opt/mvx-opensync in the VM
boardfarm/    lab config overlaid into boardfarm-lab-staging/lab/
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
| LXD-VM appliance pattern | `~/yocto/easymesh-bpi/meta-cmf-bananapi-vcpe/gen/vm` | template for VM creation, asset bundling, and boardfarm-in-VM |

## Documentation

- [doc/PLAN.md](doc/PLAN.md): the detailed implementation plan
- `~/git/meta-lxd/docs/hwsim.md`: the hwsim radio pool and Wi-Fi HAL providers
- `~/git/meta-lxd/docs/opensync-mesh-hwsim.md`: OpenSync GRE mesh over hwsim
- `~/git/hal-wifi-hwsim/SETUP.md`: OpenSync over 802.11 simulation: what has been proven
- `~/yocto/mv-builds/README.md`: the mvx build manual
