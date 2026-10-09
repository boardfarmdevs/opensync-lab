#!/usr/bin/env bash
# OpenSync's Plan B in a pod (deploy-mvx.sh pod-planb [NAME]; not part of mesh or all: it
# restarts the pod's OpenSync). A manager that loses OVSDB restarts OpenSync: dm's Plan B
# ends dm with exit 1, and opensync.service's drop-in (Restart=on-failure,
# pod/image/files/opensync-restart.conf) starts OpenSync again; every other manager's
# Plan B child exits (core patch 0005) instead of aborting in the event loop it
# inherited. Before those, the pod's OpenSync stayed down (Restart=no) and each manager
# left a libev abort and a core. The test: kill ovsdb-server, then OpenSync must be back
# by itself, with OVSDB answering, and no Plan B child may have aborted.
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "$0")/common.sh"
set +e
set +o pipefail

name=${1:-pod-1}
wait_s=${MVX_PLANB_WAIT:-120}   # dm's restart is RestartSec=10 plus OpenSync's start
px() { lxc exec "$name" -- "$@" </dev/null 2>/dev/null; }
restarts() { px systemctl show opensync.service -p NRestarts --value; }
# shellcheck disable=SC2317  # called by wait_for
back() {
    [ "$(restarts)" -gt "$1" ] && [ "$(px systemctl is-active opensync.service)" = active ] \
        && [ -n "$(px /usr/opensync/tools/ovsh -r s AWLAN_Node id)" ]
}

ct_running "$name" || die "pod $name is not running"
n0=$(restarts)
[ -n "$n0" ] || die "no opensync.service in $name"
since=$(px date +%s)
log "planb: killing ovsdb-server in $name (OpenSync restarted by systemd $n0 times so far)"
px pkill -x ovsdb-server || die "planb: no ovsdb-server running in $name"
result=PASS
if wait_for "$wait_s" 3 "OpenSync restarted by systemd, OVSDB answering" back "$n0"; then
    log "planb: OpenSync back after $(( $(px date +%s) - since )) s (restarts: $(restarts))"
else
    result=FAIL
    warn "planb: OpenSync not back: $(px systemctl show opensync.service -p ActiveState -p Result -p NRestarts | paste -sd' ' -)"
fi
aborts=$(px journalctl --since "@$since" --no-pager -o cat | grep -c '(libev) epoll_wait')
if [ "${aborts:-0}" -gt 0 ]; then
    result=FAIL
    warn "planb: $aborts Plan B child(ren) aborted in libev (epoll_wait)"
else
    log "planb: no Plan B child aborted"
fi
log "planb: $result"
[ "$result" = PASS ]
