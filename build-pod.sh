#!/usr/bin/env bash
#
# build-pod.sh - build the OpenSync pod (extender) LXD image from the
# open-source OpenSync release.
#
#   build-pod.sh buildenv    docker build environment (Ubuntu 20.04, OVS 2.8.7, hostap)
#   build-pod.sh sources     fetch the pinned OpenSync repos, assemble the tree + overlays
#   build-pod.sh build       make TARGET=HWSIM_POD (+ rootfs)
#   build-pod.sh image       pod runtime image -> LXD image (metadata + rootfs tarballs)
#   build-pod.sh all         everything above
#   build-pod.sh status      what exists
#
# OpenSync 6.6.1.0 from github.com/plume-design (pod/opensync/sources.lock):
# core + opensync-platform-cfg80211 (nl80211/cfg80211, i.e. mac80211_hwsim)
# + opensync-vendor-openwrt-template with our HWSIM_POD target overlaid
# (pod/opensync/vendor-overlay) + our mvx-local service provider (redirector
# = local-noc, onboarding credentials). Built natively in docker; the result
# runs as an LXD system container in the lab VM (deploy-mvx.sh pod).

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

POD=$MVX_ROOT/pod
: "${MVX_POD_WORK:=$HOME/yocto/mvx-pod-work}"
: "${MVX_POD_BUILDENV:=mvx-pod-buildenv:focal}"
: "${MVX_POD_OUT:=$MVX_POD_WORK/out}"
: "${MVX_POD_JOBS:=$(nproc)}"
SRC_CACHE=${MVX_CACHE:-$HOME/.cache/opensync-lab}/pod-src
TARGET=HWSIM_POD
PROFILE=mvx-local

in_buildenv() {
    docker run --rm -u "$(id -u):$(id -g)" -e TERM=dumb \
        -v "$MVX_POD_WORK:/src" -w /src/core "$MVX_POD_BUILDENV" "$@"
}

cmd_buildenv() {
    require_cmd docker
    log "buildenv: $MVX_POD_BUILDENV"
    docker build -q -t "$MVX_POD_BUILDENV" -f "$POD/build/Dockerfile.buildenv" "$POD/build" >/dev/null
    docker run --rm "$MVX_POD_BUILDENV" sh -c 'ovsdb-server --version | head -1; hostapd -v 2>&1 | head -1' \
        | sed 's/^/    /'
}

cmd_sources() {
    local dir url commit cache
    install -d "$SRC_CACHE"
    rm -rf "$MVX_POD_WORK/core" "$MVX_POD_WORK/platform" "$MVX_POD_WORK/vendor" "$MVX_POD_WORK/service-provider"
    while read -r dir url commit; do
        case "$dir" in ''|\#*) continue ;; esac
        cache=$SRC_CACHE/$(basename "$url" .git).git
        if [ ! -d "$cache" ]; then
            git clone -q --bare "$url" "$cache"
        elif ! git --git-dir="$cache" cat-file -e "$commit^{commit}" 2>/dev/null; then
            git --git-dir="$cache" fetch -q origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
        fi
        git --git-dir="$cache" cat-file -e "$commit^{commit}" || die "$url: commit $commit not found"
        install -d "$MVX_POD_WORK/$(dirname "$dir")"
        # a plain local clone (hardlinked objects): the build runs git in the
        # container, where an alternates path to the host cache would not resolve
        git clone -q --no-checkout "$cache" "$MVX_POD_WORK/$dir"
        git -C "$MVX_POD_WORK/$dir" checkout -q --detach "$commit"
        log "sources: $dir @ ${commit:0:12}"
    done < "$POD/opensync/sources.lock"

    # our patches to the upstream repos (pod/opensync/patches/<repo dir>/*.patch)
    local pd p
    for pd in "$POD"/opensync/patches/*/; do
        dir=$(basename "$pd")
        for p in "$pd"*.patch; do
            [ -e "$p" ] || continue
            git -C "$MVX_POD_WORK/$dir" apply "$p" || die "patch does not apply: $dir/$(basename "$p")"
            log "sources: patched $dir: $(basename "$p")"
        done
    done

    # overlays: our HWSIM_POD target on the vendor template, our service provider
    cp -a "$POD/opensync/vendor-overlay/." "$MVX_POD_WORK/vendor/openwrt-template/"
    sed -i "s/^OWRT_TEMPLATE_TARGETS += LINKSYS_MR8300 BPI-R3 BPI-R4\$/& $TARGET/" \
        "$MVX_POD_WORK/vendor/openwrt-template/build/target-arch.mk"
    grep -q " $TARGET\$" "$MVX_POD_WORK/vendor/openwrt-template/build/target-arch.mk" \
        || die "could not register $TARGET in the vendor template's target-arch.mk"
    cp -a "$POD/opensync/service-provider/." "$MVX_POD_WORK/service-provider/"
    log "sources: overlays applied (target $TARGET, profile $PROFILE)"
}

cmd_build() {
    [ -d "$MVX_POD_WORK/core/.git" ] || die "no sources (run: $0 sources)"
    local t0=$SECONDS
    log "build: make TARGET=$TARGET IMAGE_DEPLOYMENT_PROFILE=$PROFILE (-j$MVX_POD_JOBS)"
    in_buildenv make TARGET=$TARGET IMAGE_DEPLOYMENT_PROFILE=$PROFILE -j"$MVX_POD_JOBS" \
        > "$MVX_POD_WORK/build.log" 2>&1 \
        || { grep -nE ': error|\*\*\*|undefined reference' "$MVX_POD_WORK/build.log" | head -20; die "build failed (log: $MVX_POD_WORK/build.log)"; }
    in_buildenv make TARGET=$TARGET IMAGE_DEPLOYMENT_PROFILE=$PROFILE rootfs \
        >> "$MVX_POD_WORK/build.log" 2>&1 || die "make rootfs failed (log: $MVX_POD_WORK/build.log)"
    log "build: done in $(( (SECONDS - t0) / 60 )) min -> $MVX_POD_WORK/core/work/$TARGET/rootfs"
}

# 52_owm_prep.sh names each radio's VIFs by the phy's first band ("iw phy info"):
# every hwsim radio is multi-band, so all would come out as "24". Give them
# bands by position instead (MVX_POD_RADIO_BANDS, default "24 50 60").
patch_owm_prep() {
    local f=$1
    python3 - "$f" <<'EOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
new = '''radio_suffix() {
    # opensync-lab pod: hwsim radios are all multi-band, so the band cannot be
    # read from the phy. Assign by position: 1st radio -> 24, 2nd -> 50, 3rd -> 60
    # (override with MVX_POD_RADIO_BANDS).
    # position of this phy among the unit's radios (phy names are VM-wide)
    idx=$(ls /sys/class/ieee80211 | sort -V | grep -nx "$1" | cut -d: -f1)
    set -- ${MVX_POD_RADIO_BANDS:-24 50 60}
    shift $(( ${idx:-1} - 1 )) 2>/dev/null || { echo 24; return; }
    echo "${1:-24}"
}
'''
s2, n = re.subn(r'radio_suffix\(\)\s*\{.*?\n\}\n', new, s, count=1, flags=re.S)
if n != 1:
    sys.exit("radio_suffix() not found in " + p)
open(p, "w").write(s2)
EOF
}

cmd_image() {
    local rootfs=$MVX_POD_WORK/core/work/$TARGET/rootfs ctx stamp name cid
    [ -d "$rootfs/usr/opensync" ] || die "no rootfs (run: $0 build)"
    stamp=$(date +%Y%m%d%H%M%S)
    name=mvx-pod-$stamp
    ctx=$(mktemp -d)
    trap 'rm -rf "$ctx"' RETURN
    cp -a "$POD/image/." "$ctx/"
    cp -a "$rootfs" "$ctx/rootfs"
    patch_owm_prep "$ctx/rootfs/usr/opensync/scripts/start.d/52_owm_prep.sh"
    log "image: docker build (context $(du -sh "$ctx" | cut -f1))"
    docker build -q --build-arg BUILDENV="$MVX_POD_BUILDENV" -t "mvx-pod:$stamp" "$ctx" >/dev/null
    install -d "$MVX_POD_OUT"
    cid=$(docker create "mvx-pod:$stamp")
    docker export "$cid" | gzip -1 > "$MVX_POD_OUT/$name.rootfs.tar.gz"
    docker rm "$cid" >/dev/null
    cat > "$ctx/metadata.yaml" <<EOF
architecture: x86_64
creation_date: $(date +%s)
properties:
  description: "opensync-lab OpenSync pod (HWSIM_POD, OpenSync 6.6.1.0) $stamp"
  os: ubuntu
  release: focal
EOF
    tar -C "$ctx" -czf "$MVX_POD_OUT/$name.metadata.tar.gz" metadata.yaml
    ln -sfn "$name.rootfs.tar.gz" "$MVX_POD_OUT/mvx-pod.rootfs.tar.gz"
    ln -sfn "$name.metadata.tar.gz" "$MVX_POD_OUT/mvx-pod.metadata.tar.gz"
    persist_local MVX_POD_IMAGE "$MVX_POD_OUT/$name"
    log "image: $MVX_POD_OUT/$name.{metadata,rootfs}.tar.gz ($(du -h "$MVX_POD_OUT/$name.rootfs.tar.gz" | cut -f1))"
}

cmd_status() {
    echo "work dir:  $MVX_POD_WORK"
    docker image inspect "$MVX_POD_BUILDENV" >/dev/null 2>&1 && echo "buildenv:  $MVX_POD_BUILDENV" || echo "buildenv:  -"
    [ -d "$MVX_POD_WORK/core/.git" ] && echo "sources:   $(git -C "$MVX_POD_WORK/core" describe --tags 2>/dev/null)" || echo "sources:   -"
    [ -d "$MVX_POD_WORK/core/work/$TARGET/rootfs/usr/opensync" ] && echo "rootfs:    built" || echo "rootfs:    -"
    ls -1 "$MVX_POD_OUT"/*.rootfs.tar.gz 2>/dev/null | sed 's/^/image:     /' || true
}

usage() { sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
    buildenv) cmd_buildenv ;;
    sources)  cmd_sources ;;
    build)    start_log build-pod; cmd_build ;;
    image)    cmd_image ;;
    all)      start_log build-pod; cmd_buildenv; cmd_sources; cmd_build; cmd_image ;;
    status)   cmd_status ;;
    *)        usage ;;
esac
