#!/usr/bin/env bash
# Base lab host: packages, Docker, nested LXD (snap, held), uv, hwsim module.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"

# A lab VM takes no automatic updates: an unattended upgrade restarts services under a
# running lab. apt-get and snap refresh by hand keep working.
no_automatic_updates() {
    systemctl mask --now apt-daily.timer apt-daily-upgrade.timer
    # a run in flight holds the dpkg lock: it finishes first
    while systemctl show -p ActiveState --value apt-daily.service apt-daily-upgrade.service \
        | grep -Eq '^(activating|active)$'; do
        sleep 2
    done
    systemctl mask apt-daily.service apt-daily-upgrade.service
    systemctl disable --now unattended-upgrades.service 2>/dev/null || true
    printf '%s\n' 'APT::Periodic::Update-Package-Lists "0";' \
        'APT::Periodic::Unattended-Upgrade "0";' \
        > "${APT_CONF_DIR:-/etc/apt/apt.conf.d}/99-lab-no-automatic-updates"
    if command -v snap >/dev/null 2>&1; then
        snap wait system seed.loaded
        snap refresh --hold
    fi
}

# Ubuntu installs LXD on demand, from its own channel, the first time anything runs lxc or
# lxd in the VM (lxd-installer). The lab installs its own LXD below: no on-demand install,
# and one already under way finishes first.
no_on_demand_lxd() {
    systemctl mask --now lxd-installer.socket 2>/dev/null || true
    while snap changes 2>/dev/null | grep -Eq '^[0-9]+ +(Do|Doing|Wait) .*Install "lxd"'; do
        sleep 2
    done
}

log "base: no automatic updates, no on-demand LXD"
no_automatic_updates >/dev/null 2>&1
no_on_demand_lxd

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
