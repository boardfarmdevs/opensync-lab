#!/usr/bin/env bash
# Base lab host: packages, Docker, nested LXD (snap, held), uv, hwsim module.
source "$(dirname "$0")/common.sh"

log "base: apt packages"
apt-get update -q
apt-get install -y -q --no-install-recommends \
    bridge-utils btrfs-progs ca-certificates curl docker.io docker-compose-v2 \
    git iperf3 iproute2 iptables iputils-ping iw jq python3 rsync sshpass sudo tcpdump \
    util-linux wpasupplicant isc-dhcp-client zstd >/dev/null

# mac80211_hwsim ships in linux-modules-extra for the generic kernel; the
# cloud image may run a flavour without it (then switch to linux-generic).
if ! modinfo mac80211_hwsim >/dev/null 2>&1; then
    log "base: mac80211_hwsim missing for $(uname -r)"
    if apt-get install -y -q "linux-modules-extra-$(uname -r)" >/dev/null 2>&1; then
        log "base: installed linux-modules-extra-$(uname -r)"
    else
        log "base: installing linux-generic (reboot required)"
        apt-get install -y -q linux-generic >/dev/null
        touch "$STATE/reboot-required"
        exit 0
    fi
fi
modinfo mac80211_hwsim | grep -q '^parm:.*channels' || die "mac80211_hwsim has no channels= parameter"

systemctl enable --now docker >/dev/null 2>&1

log "base: snaps (lxd, astral-uv)"
snap list lxd >/dev/null 2>&1 || snap install lxd --channel=latest/stable
snap refresh --hold=forever lxd >/dev/null
snap list astral-uv >/dev/null 2>&1 || snap install astral-uv --classic
lxd waitready --timeout=120

if ! lxc storage show default >/dev/null 2>&1; then
    # btrfs: mv.sh puts size= quotas on the container root and nvram volume
    log "base: lxd init (btrfs default pool)"
    lxd init --auto --storage-backend btrfs
fi

# Docker defaults FORWARD to DROP; let LXD's own bridge through.
install -m 0755 "$MVX_GUEST_ROOT/guest/files/mvx-lxd-docker-forward" /usr/local/sbin/
install -m 0644 "$MVX_GUEST_ROOT/guest/files/mvx-lxd-docker-forward.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now mvx-lxd-docker-forward.service >/dev/null 2>&1

set_status base "ok lxd=$(lxd --version) docker=$(docker version -f '{{.Server.Version}}') kernel=$(uname -r)"
log "base: $(cat "$STATE/base.status")"
