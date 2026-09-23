#!/usr/bin/env bash
#
# setup-vm.sh - create and provision the mvx-opensync lab VM (an LXD VM).
#
#   setup-vm.sh create      create + boot the VM (idempotent)
#   setup-vm.sh provision   base packages, docker, nested LXD, hwsim pool, boardfarm lab
#   setup-vm.sh all         create + provision
#   setup-vm.sh status      VM state + lab status inside it
#   setup-vm.sh shell       root shell in the VM
#   setup-vm.sh start|stop  VM lifecycle
#   setup-vm.sh delete      delete the VM (asks first)
#
# The VM (default mvx-opensync-<MMDD>, see config/mvx.conf) is the lab host:
# Docker runs the boardfarm WAN side (dhcp-cpe1 + wan-cpe1 on br-wan101,
# lan-cpe1 on br-lan201), nested LXD runs the mvx container, and the
# mac80211_hwsim pool supplies its radios. Deploying the container is
# deploy-mvx.sh's job.
#
# Guest scripts are pushed to /opt/mvx-opensync in the VM and run as root.
# The VM cannot reach bitbucket and has no GitHub key, so git inputs go in
# as bundles made on this host.

set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
source "$MVX_ROOT/lib/vm.sh"

: "${MVX_CACHE:=$HOME/.cache/mvx-opensync}"

cmd_create() {
    require_cmd lxc
    if vm_exists; then
        log "create: $MVX_VM exists ($(vm_state))"
        [ "$(vm_state)" = RUNNING ] || lxc start "$MVX_VM"
        vm_wait_agent
        return
    fi
    log "create: $MVX_VM ($MVX_VM_IMAGE, ${MVX_VM_CPUS} cpu, $MVX_VM_MEMORY, $MVX_VM_DISK on pool $MVX_VM_STORAGE)"
    lxc init "$MVX_VM_IMAGE" "$MVX_VM" --vm --storage "$MVX_VM_STORAGE" \
        --config limits.cpu="$MVX_VM_CPUS" --config limits.memory="$MVX_VM_MEMORY" </dev/null
    # uefi-nosecureboot: keeps the option open to load a locally built
    # (patched, unsigned) mac80211_hwsim for wmediumd later.
    lxc config set "$MVX_VM" boot.mode uefi-nosecureboot 2>/dev/null \
        || lxc config set "$MVX_VM" security.secureboot false
    lxc config set "$MVX_VM" boot.autostart false
    if lxc config device show "$MVX_VM" | grep -q '^root:'; then
        lxc config device set "$MVX_VM" root size="$MVX_VM_DISK"
    else
        lxc config device override "$MVX_VM" root size="$MVX_VM_DISK"
    fi
    lxc config device override "$MVX_VM" eth0 network="$MVX_VM_NETWORK" 2>/dev/null \
        || lxc config device add "$MVX_VM" eth0 nic network="$MVX_VM_NETWORK"
    lxc config set "$MVX_VM" user.mvx-opensync.created "$(date -Is)"
    lxc start "$MVX_VM"
    vm_wait_agent
    log "create: waiting for cloud-init"
    lxc exec "$MVX_VM" -- cloud-init status --wait >/dev/null || warn "cloud-init reported an error"
    # later runs (other days) must keep targeting this VM
    persist_local MVX_VM "$MVX_VM"
    lxc list "$MVX_VM" -c ns4 --format table
}

# Bare cache clone of boardfarm-lab-staging on this host, then a bundle of
# the pinned commit for the VM.
make_boardfarm_bundle() {
    local out=$1 cache=$MVX_CACHE/boardfarm-lab-staging.git
    install -d "$MVX_CACHE"
    if [ ! -d "$cache" ]; then
        git clone -q --mirror "$MVX_BOARDFARM_SOURCE" "$cache"
    elif ! git --git-dir="$cache" cat-file -e "$MVX_BOARDFARM_COMMIT^{commit}" 2>/dev/null; then
        git --git-dir="$cache" fetch -q --prune origin
    fi
    git --git-dir="$cache" cat-file -e "$MVX_BOARDFARM_COMMIT^{commit}" \
        || die "boardfarm commit $MVX_BOARDFARM_COMMIT not found in $MVX_BOARDFARM_SOURCE"
    git --git-dir="$cache" update-ref refs/heads/mvx-pin "$MVX_BOARDFARM_COMMIT"
    git --git-dir="$cache" bundle create "$out" refs/heads/mvx-pin 2>/dev/null
    git --git-dir="$cache" update-ref -d refs/heads/mvx-pin
    git --git-dir="$cache" bundle verify "$out" >/dev/null 2>&1 || die "bad bundle $out"
}

cmd_provision() {
    vm_exists || die "$MVX_VM does not exist (run: $0 create)"
    [ "$(vm_state)" = RUNNING ] || lxc start "$MVX_VM"
    vm_wait_agent
    start_log "provision-$MVX_VM"

    local stage
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' RETURN
    log "provision: boardfarm-lab-staging @ ${MVX_BOARDFARM_COMMIT:0:12}"
    make_boardfarm_bundle "$stage/boardfarm-lab-staging.bundle"
    vm_push_tree
    vm_push_file "$stage/boardfarm-lab-staging.bundle" /opt/mvx-opensync/assets/boardfarm-lab-staging.bundle

    vm_run_guest 00-base.sh
    if lxc exec "$MVX_VM" -- test -e /var/lib/mvx-opensync/reboot-required; then
        log "provision: kernel changed, rebooting $MVX_VM"
        lxc restart "$MVX_VM" --timeout 300
        vm_wait_agent
        lxc exec "$MVX_VM" -- rm -f /var/lib/mvx-opensync/reboot-required
        vm_run_guest 00-base.sh
    fi
    vm_run_guest 10-hwsim.sh
    vm_run_guest 20-boardfarm.sh
    log "provision: done"
    cmd_status
}

cmd_status() {
    vm_exists || { echo "$MVX_VM: not created"; return 0; }
    lxc list "$MVX_VM" -c nsN4tm --format table
    [ "$(vm_state)" = RUNNING ] || return 0
    vm_wait_agent
    lxc exec "$MVX_VM" -- bash -c '
        printf "kernel      %s\n" "$(uname -r)"
        printf "hwsim       radios=%s channels=%s free=%s\n" \
            "$(cat /sys/module/mac80211_hwsim/parameters/radios 2>/dev/null)" \
            "$(cat /sys/module/mac80211_hwsim/parameters/channels 2>/dev/null)" \
            "$(ls /sys/class/net | grep -c "^virt-wlan")"
        printf "lxd         %s\n" "$(lxd --version 2>/dev/null)"
        for f in /var/lib/mvx-opensync/*.status; do [ -e "$f" ] && printf "%-11s %s\n" "$(basename "$f" .status)" "$(cat "$f")"; done
        echo "--- docker"; docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null
        echo "--- lxc";    lxc list -c ns4 --format csv 2>/dev/null | sed "s/^/  /"
    '
}

cmd_delete() {
    vm_exists || { log "$MVX_VM does not exist"; return 0; }
    lxc list "$MVX_VM" -c nstc --format table
    read -r -p "Delete VM $MVX_VM and everything in it? [y/N] " a
    [[ "$a" =~ ^[yY] ]] || { log "not deleted"; return 0; }
    lxc delete -f "$MVX_VM"
    log "deleted $MVX_VM"
}

usage() { sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
    create)    cmd_create ;;
    provision) cmd_provision ;;
    all)       cmd_create; cmd_provision ;;
    status)    cmd_status ;;
    shell)     exec lxc exec "$MVX_VM" -- bash -l ;;
    start)     lxc start "$MVX_VM"; vm_wait_agent ;;
    stop)      lxc stop "$MVX_VM" --timeout 300 ;;
    delete)    cmd_delete ;;
    *)         usage ;;
esac
