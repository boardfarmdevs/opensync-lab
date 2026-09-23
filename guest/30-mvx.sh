#!/usr/bin/env bash
# Launch the mvx container with meta-lxd gen/mv.sh: WAN on br-wan101, LAN
# port 1 on br-lan201, radios from the hwsim pool. Relaunching replaces the
# container but keeps its nvram volume (mv.sh semantics).
source "$(dirname "$0")/common.sh"

name=${1:?container name}
source "$MVX_GUEST_ROOT/deploy.env"
ML=$MVX_GUEST_ROOT/meta-lxd

[ -e "$image" ] || die "no image at $image (run deploy-mvx.sh push)"
systemctl is-active -q boardfarm-lab.service || die "boardfarm-lab.service is not active"
ip link show br-wan101 >/dev/null && ip link show br-lan201 >/dev/null \
    || die "boardfarm bridges br-wan101/br-lan201 missing"

if [ ! -d "$ML/.git" ]; then
    git clone -q "$MVX_GUEST_ROOT/assets/meta-lxd.bundle" "$ML"
else
    git -C "$ML" fetch -q "$MVX_GUEST_ROOT/assets/meta-lxd.bundle" 'refs/heads/*:refs/remotes/bundle/*'
fi
git -C "$ML" checkout -q --detach "$meta_lxd"
log "mvx: meta-lxd $(git -C "$ML" log -1 --format='%h %s')"

args=("$image" -b br-wan101 -l br-lan201)
case "$name" in
    *-[0-9][0-9][0-9]) args+=(-i "$((10#${name##*-}))") ;;
esac

log "mvx: HWSIM_RADIOS=${MVX_HWSIM_RADIOS:-3} mv.sh ${args[*]}"
cd "$ML/gen"   # mv.sh insists on running from inside its checkout
HWSIM_RADIOS=${MVX_HWSIM_RADIOS:-3} HWSIM_POOL_SIZE=${MVX_HWSIM_POOL:-24} ./mv.sh "${args[@]}"

wait_for 120 2 "$name running" ct_running "$name" \
    || die "$name did not start"
lxc config set "$name" user.mvx-opensync.image-sha256 "$image_sha256"
set_status mvx "launched $name build=$(lxc config get "$name" user.build) at $(date -Is)"
log "mvx: $(cat "$STATE/mvx.status")"
lxc list "^$name\$" -c ns4 --format table
