# pins/: a placeholder

The pin sets of the gateway container build are private since 28 October 2026, and so is the
build's manifest URL. They live in a checkout of a private repository, `OPENSYNC_LAB_PRIVATE`
(default `~/yocto/opensync-lab-private`, set in [config/](../config)):

| Path under `OPENSYNC_LAB_PRIVATE` | What |
| --- | --- |
| `private.conf` | sourced by every host script (`lib/common.sh`): `MANIFEST_URL`, the repo manifest repository; `OPENSYNC_LAB_SON_OBJECT`, the router's SON object that the OpenSync step enables; `OPENSYNC_LAB_SUBDIRS`, the build subdirectory of the products that have one (`<product>=<subdir> ...`) |
| `pins/<pin set>/` | one pin set: `manifest.xml` and `manifest.xml.projects`, `layers.lock`, `srcrev.inc`, `reference.txt` and the reference package lists, as [docs/project/implementation-plan.md](../docs/project/implementation-plan.md) §3 describes them |

The build's `pin` step writes a pin set there, and its `build` step and the deploy script read
it. Without the checkout the build's `status` still runs, and `pin`, `build` and `all` stop with
a message naming `OPENSYNC_LAB_PRIVATE`. The files that were here are in this repository's
history up to e71f36d.
