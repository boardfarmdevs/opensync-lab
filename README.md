# opensync-lab: an OpenSync router and pods, with a local cloud

<!-- labs block: the same in every repository of the EasyMesh labs, but for the Site line -->
**Site:** <https://vcpe.dev/opensync-lab/>
The [EasyMesh labs](https://mesh.vcpe.dev/) serve three
goals: EasyMesh optimizer development
([easymesh-optimizer](https://vcpe.dev/easymesh-optimizer/)) in a rich
virtual lab, on both stacks
([RDK EasyMesh](https://vcpe.dev/meta-cmf-bananapi-vcpe/),
[prplMesh](https://vcpe.dev/prplmesh-lab/)); unchanged OpenSync
pods as EasyMesh agents under a local controller, without the OpenSync cloud
([EMOSA](https://vcpe.dev/emosa-lab/), with the
[OpenSync lab](https://vcpe.dev/opensync-lab/)'s pods); and
EasyMesh on physical hardware
([Protocol lab](https://vcpe.dev/easymesh-lab/)). Two core
components carry them: the RF medium
([easymesh-medium](https://vcpe.dev/easymesh-medium/)) and EMOSA's
OVSDB ⇄ EasyMesh conversion. The rest is infrastructure, tools (the
[room builder](https://vcpe.dev/easymesh-room-builder/)) and learning
around them.
<!-- /labs block -->

A reproducible, one-command lab for an **OpenSync-enabled containerized RDK-B gateway**
(the LGI mvx products, starting with **mv3**), with OpenSync extenders and a local
stand-in for the OpenSync cloud. It is the reference lab EMOSA is proven on: EMOSA takes
these pods over as EasyMesh agents. The scripts:

1. **build** the LXD mv3 image from a fresh `repo init`, pinned to the exact manifest
   revisions, `meta-lxd*` layer commits and AUTOREV `SRCREV`s of a known-good reference
   build, from a local repo mirror (offline, without the VPN);
2. **create an LXD VM** (`opensync-lab-MMDD`) as the lab host: boardfarm-lab Docker
   containers for the WAN side (Kea DHCP and a NAT gateway), a `mac80211_hwsim` radio
   pool, and the mv3 container with three hwsim radios behind the `hal-wifi-hwsim` HAL;
3. **bring up OpenSync**: SON on, the node connected to its cloud (the Plume redirector,
   or `local-noc`), the home and backhaul VAPs and the GRE backhaul network built;
4. **add OpenSync extenders**: three pods built from the open-source OpenSync release
   (6.6.1.0), with only hwsim radios, join mv3's Wi-Fi backhaul, build their GRE uplinks
   and are claimed by `local-noc`; two wireless clients on each pod's fronthaul reach
   the internet through pod, GRE and mv3.

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

## Components

| Part | What it is |
| --- | --- |
| `build-mvx.sh`, `setup-vm.sh`, `deploy-mvx.sh`, `build-pod.sh`, `build-docs.sh` | the entry points, one per stage, run on the build host |
| [config/](config) | `mvx.conf`, the defaults: product, release, reference build, pins, VM name and size, boardfarm commit, hwsim pool (any can be overridden from the environment; the untracked `local.conf` keeps what must last across days) |
| [lib/](lib) | host-side helpers (`common.sh`, `vm.sh`, `pin-manifest.py`, `docs.py`) |
| [local-noc/](local-noc) | the local OpenSync cloud: redirector and controller over OVSDB JSON-RPC, the mesh orchestration, the topology view, `noc-ctl` |
| [meta-mvx/](meta-mvx) | bbappends and patches on top of the pinned layers (`hal-wifi-hwsim`) |
| [pod/](pod) | the OpenSync extender: `sources.lock`, target and provider overlays, patches, build environment, image |
| [pins/](pins) | the pinned manifest, layer commits, SRCREVs and the reference package list |
| [guest/](guest) | the scripts and units pushed to `/opt/opensync-lab` in the VM |
| [boardfarm/](boardfarm) | the lab configuration overlaid into boardfarm-lab-staging, and its patches |
| [site/](site) | the documentation site: local-noc's topology viewer replaying a recording of the lab, the reference tables, the stages |

## Getting started

There is one script per stage; each subcommand can be re-run safely.

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

# the documentation site (site/, GitHub Pages): viewer + reference + a recording of the lab
./build-docs.sh all                       # then commit site/
./build-docs.sh serve                     # preview on http://localhost:8000/
```

## Documentation

The [site](https://vcpe.dev/opensync-lab/) walks through the lab stage by
stage, with local-noc's topology viewer on a recording of the lab. The documents are
indexed in [docs/README.md](docs/README.md): local-noc, the workarounds and where their
fixes belong, the building blocks, the fresh-VM reproduction and the implementation plan.
