# shellcheck shell=bash
# Host-side helpers for talking to the lab VM. Source after lib/common.sh.

GUEST_ROOT=/opt/opensync-lab

vm_exists() { lxc info "$MVX_VM" >/dev/null 2>&1; }
vm_state()  { lxc info "$MVX_VM" 2>/dev/null | sed -n 's/^Status: //p'; }

vm_wait_agent() {
    wait_for 300 2 "LXD agent in $MVX_VM" lxc exec "$MVX_VM" -- true \
        || die "$MVX_VM did not expose its LXD agent"
}

# The redirector (SONURL) for a cloud name: plume | local.
cloud_redirector() {
    case "$1" in
        plume) echo "$MVX_PLUME_REDIRECTOR" ;;
        local) echo "tcp:$MVX_LOCAL_NOC_IP:$MVX_LOCAL_NOC_REDIRECTOR_PORT" ;;
        *) die "unknown cloud '$1' (plume|local)" ;;
    esac
}
: "${MVX_OPENSYNC_REDIRECTOR:=$(cloud_redirector "$MVX_CLOUD")}"

# Everything the guest needs from this repo, plus the resolved settings.
vm_push_tree() {
    log "push: guest scripts + boardfarm overlay -> $MVX_VM:$GUEST_ROOT"
    lxc exec "$MVX_VM" -- install -d "$GUEST_ROOT/assets" /var/lib/opensync-lab
    # replace, not overlay: a file removed or renamed here must vanish there too
    lxc exec "$MVX_VM" -- rm -rf "$GUEST_ROOT/guest" "$GUEST_ROOT/boardfarm" "$GUEST_ROOT/local-noc"
    tar -C "$MVX_ROOT" -czf - guest boardfarm local-noc \
        | lxc exec "$MVX_VM" -- tar -C "$GUEST_ROOT" -xzf -
    {
        echo "# written by $(basename "$0") on $(hostname) at $(date -Is)"
        local v
        for v in MVX_PRODUCT MVX_RELEASE MVX_BOARDFARM_COMMIT MVX_HWSIM_POOL MVX_HWSIM_CHANNELS \
                 MVX_HWSIM_RADIOS MVX_INSTANCE MVX_OPENSYNC_REDIRECTOR MVX_LOCAL_NOC_IP \
                 MVX_LOCAL_NOC_REDIRECTOR_PORT MVX_LOCAL_NOC_CONTROLLER_PORT MVX_MESH_GATEWAY \
                 MVX_MESH_BHAUL_IF MVX_MESH_BHAUL_SSID MVX_MESH_BHAUL_PSK MVX_MESH_HOME_SSID \
                 MVX_MESH_HOME_PSK; do
            printf '%s=%q\n' "$v" "${!v}"
        done
    } | lxc exec "$MVX_VM" -- tee "$GUEST_ROOT/vm.env" >/dev/null
}

vm_push_file() {
    local src=$1 dst=$2
    lxc exec "$MVX_VM" -- install -d "$(dirname "$dst")"
    lxc file push --quiet "$src" "$MVX_VM$dst"
}

# Run one guest script as root, stdin detached (lxc/lxd parse piped stdin).
vm_run_guest() {
    local script=$1
    shift
    log "guest: $script $*"
    lxc exec "$MVX_VM" --env MVX_GUEST_ROOT="$GUEST_ROOT" -- \
        bash -c 'exec </dev/null; exec bash "$0" "$@"' "$GUEST_ROOT/guest/$script" "$@" \
        || die "guest script $script failed"
}
