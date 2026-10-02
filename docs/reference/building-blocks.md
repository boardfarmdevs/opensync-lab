# Building blocks

[Documents](../README.md)

What the lab reuses, unforked, and where it lives on the build host.

| Component | Location | Role |
|---|---|---|
| `meta-lxd` (`rnl25-oe40`) | `~/git/meta-lxd` | LXD image class, `hal-wifi-hwsim` recipe, `gen/mv.sh` launcher, `gen/gen-util.sh` hwsim pool |
| `meta-lxd-mv3` (`rnl25-oe40`) | `~/git/meta-lxd-mv3` | mv3 LXD machine; selects `hal-wifi-hwsim` as the Wi-Fi HAL |
| `hal-wifi-hwsim` | `~/git/hal-wifi-hwsim` | nl80211 `wifi_hal.h` implementation (multi-BSS home + backhaul VAPs) |
| build tooling | `~/git/redkite/notes/rdk-b/bash` (`do-lxd.sh`, `git-offline.sh`), `~/yocto/mv-builds` | checkout and offline-redirect logic this project wraps |
| boardfarm-lab-staging | `github.com:robvogelaar/boardfarm-lab-staging` | `bf-lab` WAN/DHCP/LAN Docker lab, `tests/opensync` |
| OpenSync 6.6.1.0 (open source) | github.com/plume-design: `opensync`, `opensync-platform-cfg80211`, `opensync-vendor-openwrt-template`, `opensync-service-provider-local` | the extender (pod), pinned in `pod/opensync/sources.lock` |
| LXD-VM appliance pattern | `~/yocto/easymesh-bpi/meta-cmf-bananapi-vcpe/gen/vm` | template for VM creation, asset bundling, and boardfarm-in-VM |

## Related documents outside this repository

- `~/git/meta-lxd/docs/hwsim.md`: the hwsim radio pool and Wi-Fi HAL providers
- `~/git/meta-lxd/docs/opensync-mesh-hwsim.md`: OpenSync GRE mesh over hwsim
- `~/git/hal-wifi-hwsim/SETUP.md`: OpenSync over 802.11 simulation: what has been proven
- `~/yocto/mv-builds/README.md`: the mvx build manual
