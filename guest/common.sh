# shellcheck shell=bash
# Sourced by every guest script (runs as root inside the lab VM).

set -euo pipefail
exec </dev/null   # lxc subcommands try to parse a piped stdin as YAML

MVX_GUEST_ROOT=${MVX_GUEST_ROOT:-/opt/mvx-opensync}
STATE=/var/lib/mvx-opensync
install -d "$STATE"
# shellcheck source=/dev/null
[ -f "$MVX_GUEST_ROOT/vm.env" ] && source "$MVX_GUEST_ROOT/vm.env"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
export PATH=/snap/bin:$PATH

log()  { printf '\033[1;32m[vm %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[vm %s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[vm %s] FATAL\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

set_status() { printf '%s\n' "$2" > "$STATE/$1.status"; }

wait_for() {  # wait_for <timeout> <interval> <what> <cmd...>
    local timeout=$1 interval=$2 what=$3
    shift 3
    local deadline=$((SECONDS + timeout))
    while [ "$SECONDS" -lt "$deadline" ]; do
        "$@" >/dev/null 2>&1 && return 0
        sleep "$interval"
    done
    warn "timed out after ${timeout}s: $what"
    return 1
}

# Container state without a pipe into grep -q (under pipefail an early grep
# exit SIGPIPEs lxc and makes a running container look stopped).
ct_running() { [ "$(lxc list "^$1\$" -c s --format csv 2>/dev/null)" = RUNNING ]; }

# mvx LAN DHCP with SON on. RDK's service_dhcp writes /var/dnsmasq.conf with
# bind-interfaces and lists the wl0.1/wl1.1 VAP netdevs. Under hal-wifi-hwsim
# those exist only while the VAP is enabled (meta-lxd-mv3 12fbde1: the HAL owns
# the names), and with SON on the cloud keeps them disabled -- so dnsmasq exits
# with "unknown interface wl1.1" and the LAN (and anything behind a GRE) gets
# no DHCP. bind-dynamic tolerates the missing netdevs. Runtime workaround until
# the image does this itself; RDK regenerating the conf undoes it.
# Prints what it did; returns 1 if dnsmasq still is not running.
fix_lan_dhcp() {  # <container>
    local c=$1
    if lxc exec "$c" -- pidof dnsmasq >/dev/null 2>&1; then
        echo "dnsmasq running"
        return 0
    fi
    lxc exec "$c" -- sh -c 'sed -i "s/^bind-interfaces$/bind-dynamic/" /var/dnsmasq.conf &&
        dnsmasq -u nobody -q --clear-on-reload --bind-dynamic --add-mac -P 4096 -C /var/dnsmasq.conf' 2>&1 | tail -1
    sleep 1
    lxc exec "$c" -- pidof dnsmasq >/dev/null 2>&1 \
        && echo "dnsmasq was down (unknown wl0.1/wl1.1 with bind-interfaces); restarted with bind-dynamic" \
        || { echo "dnsmasq still not running"; return 1; }
}
