#!/usr/bin/env bash
#
# deploy-mvx.sh - deploy the mvx container into the lab VM and check it.
#
#   deploy-mvx.sh push     [--image PATH]   push the image + the pinned meta-lxd into the VM
#   deploy-mvx.sh launch                    launch the container with meta-lxd gen/mv.sh
#   deploy-mvx.sh check                     WAN connectivity check (+ radios, LAN info)
#   deploy-mvx.sh opensync                  enable SON, check the cloud connection
#   deploy-mvx.sh gre                       leaf node + OpenSync GRE backhaul + client via it
#   deploy-mvx.sh all      [--image PATH]   push + launch + check + opensync + gre
#   deploy-mvx.sh status                    container state + last check result
#   deploy-mvx.sh shell                     shell inside the mvx container
#
# The container is launched exactly the way meta-lxd intends: gen/mv.sh with
#   -b br-wan101   eth0 (WAN) on boardfarm's WAN bridge (dhcp-cpe1 + wan-cpe1)
#   -l br-lan201   eth1 (LAN port 1) on boardfarm's LAN bridge (lan-cpe1)
#   HWSIM_RADIOS   radios moved in from the VM's mac80211_hwsim pool
# (setup-vm.sh must have provisioned the VM first.)
#
# Image: --image PATH, else $MVX_IMAGE, else the artifact of $MVX_BUILD_DIR
# (build-mvx.sh). It is staged in the VM under a directory named after its
# build dir, because mv.sh reads product and release from the path and the
# build stamp from the real file name.

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
source "$MVX_ROOT/lib/vm.sh"

product_info "$MVX_PRODUCT"
PINS_DIR="$MVX_ROOT/pins/$MVX_PINS"
: "${MVX_PIN_STORE:=$HOME/yocto/repo_reference/mvx-pins/$MVX_PINS}"

container_name() {
    if [ -n "$MVX_INSTANCE" ]; then printf '%s-%03d\n' "$MVX_PRODUCT" "$MVX_INSTANCE"; else echo "$MVX_PRODUCT"; fi
}

resolve_image() {
    local img=${1:-$MVX_IMAGE}
    if [ -z "$img" ]; then
        img="$MVX_BUILD_DIR${PROD_SUBDIR:+/$PROD_SUBDIR}/build-$PROD_MACHINE/tmp/deploy/images/$PROD_MACHINE/ofw-$PROD_MACHINE.tar.bz2"
    fi
    [ -e "$img" ] || die "image not found: $img (build it with build-mvx.sh, or pass --image)"
    echo "$img"
}

# The build dir name (<product>-lxd-<release>-<oe>-<MMDD>) an image came from.
image_build_name() {
    local p
    p=$(readlink -f "$1")
    grep -oE "${MVX_PRODUCT}-lxd-r[0-9]+-oe[0-9]+-[^/]+" <<< "$p" | head -1
}

meta_lxd_source() {  # prints "<git dir> <sha>"
    if [ "$MVX_RUNTIME_META_LXD" = pin ]; then
        local sha
        sha=$(awk '$1 == "meta-lxd" {print $3}' "$PINS_DIR/layers.lock")
        [ -n "$sha" ] || die "no meta-lxd pin in $PINS_DIR/layers.lock"
        echo "$MVX_PIN_STORE/layers/meta-lxd.git $sha"
    else
        echo "$MVX_GIT_DIR/meta-lxd/.git $(git -C "$MVX_GIT_DIR/meta-lxd" rev-parse "$MVX_RUNTIME_META_LXD")"
    fi
}

cmd_push() {
    local image=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --image) image=$2; shift 2 ;;
            *) die "push: unknown option $1" ;;
        esac
    done
    vm_exists || die "$MVX_VM does not exist (run setup-vm.sh all)"
    vm_wait_agent
    image=$(resolve_image "$image")
    local real bname stage gitdir sha
    real=$(readlink -f "$image")
    bname=$(image_build_name "$image")
    [ -n "$bname" ] || die "cannot tell which build dir $real came from"
    grep -qE '[0-9]{14}' <<< "$(basename "$real")" || die "image file name carries no build stamp: $real"

    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' RETURN
    read -r gitdir sha < <(meta_lxd_source)
    log "push: meta-lxd ${sha:0:12} (from $gitdir)"
    git --git-dir="$gitdir" update-ref refs/heads/mvx-runtime "$sha"
    git --git-dir="$gitdir" bundle create "$stage/meta-lxd.bundle" refs/heads/mvx-runtime 2>/dev/null
    git --git-dir="$gitdir" update-ref -d refs/heads/mvx-runtime

    vm_push_tree
    vm_push_file "$stage/meta-lxd.bundle" /opt/mvx-opensync/assets/meta-lxd.bundle
    log "push: image $real ($(du -h "$real" | cut -f1)) -> images/$bname/"
    vm_push_file "$real" "/opt/mvx-opensync/images/$bname/$(basename "$real")"
    lxc exec "$MVX_VM" -- ln -sfn "$(basename "$real")" \
        "/opt/mvx-opensync/images/$bname/ofw-$PROD_MACHINE.tar.bz2"
    {
        echo "image=/opt/mvx-opensync/images/$bname/ofw-$PROD_MACHINE.tar.bz2"
        echo "image_src=$(hostname):$real"
        echo "image_sha256=$(sha256sum "$real" | awk '{print $1}')"
        echo "meta_lxd=$sha"
    } | lxc exec "$MVX_VM" -- tee /opt/mvx-opensync/deploy.env >/dev/null
    log "push: done"
}

cmd_launch() { vm_run_guest 30-mvx.sh "$(container_name)"; }
cmd_check()    { vm_run_guest 40-wan-check.sh "$(container_name)"; }
cmd_opensync() { vm_run_guest 50-opensync.sh "$(container_name)"; }
cmd_gre()      { vm_run_guest 60-gre.sh "$(container_name)"; }

cmd_status() {
    local c
    c=$(container_name)
    lxc exec "$MVX_VM" -- bash -c "
        export PATH=/snap/bin:\$PATH
        lxc list '^$c\$' -c ns4t --format table
        lxc config get '$c' user.build 2>/dev/null | sed 's/^/build stamp: /'
        for f in wan opensync gre; do
            [ -f /var/lib/mvx-opensync/\$f.status ] && sed \"s/^/\$f: /\" /var/lib/mvx-opensync/\$f.status
        done
    "
}

usage() { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
    push)   cmd_push "$@" ;;
    launch)   vm_push_tree; cmd_launch ;;
    check)    vm_push_tree; cmd_check ;;
    opensync) vm_push_tree; cmd_opensync ;;
    gre)      vm_push_tree; cmd_gre ;;
    all)      start_log "deploy-$MVX_VM"; cmd_push "$@"; cmd_launch; cmd_check; cmd_opensync; cmd_gre ;;
    status) cmd_status ;;
    shell)  exec lxc exec "$MVX_VM" -t -- /snap/bin/lxc exec "$(container_name)" -- sh -l ;;
    *)      usage ;;
esac
