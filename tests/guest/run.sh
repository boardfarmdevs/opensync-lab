#!/usr/bin/env bash
#
# tests/guest/run.sh - offline tests of the lab VM's guest steps (guest/). Each step runs as
# root, as it does in the lab VM, with the commands it drives (docker, lxc, systemctl, curl)
# replaced by stubs that record their calls and answer as a test needs (tests/guest/lib.sh).
# The steps write /etc, /usr/local and /var/lib: run this in a throwaway container,
# tests/guest/in-container.sh, not on a host.
#
#   tests/guest/run.sh        all cases; exit 1 on any failure

set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export MVX_GUEST_ROOT=$ROOT
[ "$(id -u)" -eq 0 ] || { echo "run.sh: as root, in a container (tests/guest/in-container.sh)" >&2; exit 2; }
# shellcheck source=tests/guest/lib.sh
source "$ROOT/tests/guest/lib.sh"

echo "== guest/common.sh"

test_case "wait_for"
out=$( (source "$ROOT/guest/common.sh"; wait_for 5 1 "x" true; echo "rc=$?") 2>&1)
assert_match "$out" "^rc=0$" "a condition that holds returns at once"
# (common.sh sets -e: the status is taken where the call fails)
out=$( (source "$ROOT/guest/common.sh"; wait_for 2 1 "the thing" false || echo "rc=$?") 2>&1)
assert_match "$out" "timed out after 2s: the thing" "a timeout warns"
assert_match "$out" "^rc=1$" "a timeout returns 1"

test_case "set_status"
( source "$ROOT/guest/common.sh"; set_status pod-1 "PASS all good" )
assert_file /var/lib/opensync-lab/pod-1.status "^PASS all good$"

test_case "ct_running"
behave lxc <<'EOF'
[ "$1 $2" = "list ^c1\$" ] && echo RUNNING || echo STOPPED
EOF
out=$( (source "$ROOT/guest/common.sh"; ct_running c1 && echo yes; ct_running c2 || echo no) 2>&1)
assert_eq "$out" "$(printf 'yes\nno')" "RUNNING is running, anything else is not"

test_case "fix_lan_dhcp: running"
behave lxc <<'EOF'
exit 0
EOF
out=$( (source "$ROOT/guest/common.sh"; fix_lan_dhcp mv3) 2>&1)
assert_eq "$out" "dnsmasq running" "nothing to do"
assert_no_match "$(cat "$STUB_LOG")" "bind-dynamic" "dnsmasq left alone"

test_case "fix_lan_dhcp: down"
behave lxc <<'EOF'
case "$*" in
    *"pidof dnsmasq"*)
        n=$(cat "$STUB_DIR/pidof" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB_DIR/pidof"
        [ "$n" -ge 1 ] ;;
esac
EOF
out=$( (source "$ROOT/guest/common.sh"; fix_lan_dhcp mv3; echo "rc=$?") 2>&1)
assert_match "$out" "dnsmasq was down .* restarted with bind-dynamic" "restarted"
assert_match "$out" "^rc=0$" "returns 0 once it runs"
assert_called "lxc exec mv3 -- sh -c .*bind-dynamic"
rm -f "$STUB_DIR/pidof"

test_case "fix_lan_dhcp: stays down"
behave lxc <<'EOF'
case "$*" in *"pidof dnsmasq"*) exit 1 ;; esac
EOF
out=$( (source "$ROOT/guest/common.sh"; fix_lan_dhcp mv3 || echo "rc=$?") 2>&1)
assert_match "$out" "^dnsmasq still not running$" "says so"
assert_match "$out" "^rc=1$" "returns 1"

echo "== guest/25-local-noc.sh"

test_case "local-noc started"
out=$(MVX_NOC_REDIRECT="podA=tcp:10.9.9.9:6651 podB=tcp:10.9.9.9:6652" MVX_MESH_GATEWAY=gw0 \
      bash "$ROOT/guest/25-local-noc.sh" 2>&1); rc=$?
assert_eq "$rc" 0 "exit status"
assert_called "^docker build -q -t local-noc:latest $ROOT/local-noc$"
assert_called "^docker rm -f local-noc$"
run=$(grep '^docker run ' "$STUB_LOG")
assert_match "$run" "--name local-noc --restart unless-stopped -p 8640:8640" "container, restart, UI port"
assert_match "$run" "--advertise 10.101.0.40 --redirector-port 6640 --controller-port 6641 --http-port 8640" "addresses and ports"
assert_match "$run" "--mesh-gateway gw0 --mesh-bhaul-if wl1.1 --mesh-bhaul-ssid opensync-lab-bhaul" "mesh"
assert_match "$run" "--redirect podA=tcp:10.9.9.9:6651 --redirect podB=tcp:10.9.9.9:6652" "redirects"
assert_file /etc/default/local-noc "^LOCAL_NOC_IP=10.101.0.40$"
assert_file /usr/local/sbin/local-noc-net "." 755
assert_file /etc/systemd/system/local-noc-net.service "." 644
assert_called "^systemctl enable local-noc-net.service$"
assert_called "^systemctl restart local-noc-net.service$"
assert_called "^docker exec wan-cpe1 sh -c nc -z -w3 10.101.0.40 6640 && nc -z -w3 10.101.0.40 6641$"
assert_called "^curl -fs -o /dev/null http://127.0.0.1:8640/api/topology$"
assert_file /var/lib/opensync-lab/local-noc.status \
    "^ok redirector tcp:10.101.0.40:6640 controller tcp:10.101.0.40:6641 web :8640$"

test_case "local-noc: no redirects by default"
bash "$ROOT/guest/25-local-noc.sh" >/dev/null 2>&1
assert_no_match "$(grep '^docker run ' "$STUB_LOG")" "--redirect [^ ]+=" "no --redirect"

test_case "local-noc unreachable from the WAN side (30 s)"
behave docker <<'EOF'
[ "$1" = exec ] && exit 1
exit 0
EOF
out=$(bash "$ROOT/guest/25-local-noc.sh" 2>&1); rc=$?
assert_eq "$rc" 1 "exit status"
assert_match "$out" "FATAL.* local-noc not reachable at 10.101.0.40:6640/6641" "says why"
if [ -f /var/lib/opensync-lab/local-noc.status ]; then bad "a status written"; else ok "no status written"; fi

echo "== guest/85-topology.sh"

# a lab of 2 pods x 1 client: mv3's backhaul stations, GRE ports and leases, the pods'
# identities and MACs, local-noc's sessions, the web UI's counts; MISSING drops a pod's
# station from mv3's backhaul
topology_lab() {
    behave lxc <<'EOF'
case "$*" in
    "exec mv3 -- sh -c"*"station dump"*)
        echo "Station 02:00:00:00:01:50 (on wl1.1)"
        [ "${MISSING:-}" = pod-2 ] || echo "Station 02:00:00:00:02:50 (on wl1.1)" ;;
    "exec mv3 -- sh -c"*"list-ports brlan0"*) printf 'pgd1_50\npgd1_51\nwl0.1\n' ;;
    "exec mv3 -- sh -c"*dnsmasq.leases*)
        echo "1 02:00:00:00:01:01 10.0.0.11 pod-1-wc1 *"
        echo "1 02:00:00:00:02:01 10.0.0.21 pod-2-wc1 *" ;;
    "exec pod-"?" -- /usr/opensync/tools/ovsh -r s AWLAN_Node id") echo "POD${2#pod-}" ;;
    "exec pod-"?" -- cat /sys/class/net/bhaul-sta-50/address") echo "02:00:00:00:0${2#pod-}:50" ;;
    "exec pod-"?" -- cat /sys/class/net/home-ap-24/address") echo "12:00:00:00:0${2#pod-}:24" ;;
    "exec pod-"?"-wc1 -- cat /sys/class/net/wlan0/address") n=${2#pod-}; echo "02:00:00:00:0${n%-wc1}:01" ;;
    "exec pod-"?" -- iw dev home-ap-24 station dump") echo "Station 02:00:00:00:0${2#pod-}:01 (on home-ap-24)" ;;
esac
EOF
    behave docker <<'EOF'
[ "$*" = "exec local-noc noc-ctl nodes" ] && printf 'mv3 controller x\nPOD1 controller x\nPOD2 controller x\n'
exit 0
EOF
    behave curl <<'EOF'
echo '{"counts": {"gateways": 1, "extenders": 2, "clients": 2, "online": 3}}'
EOF
    mkdir -p /var/lib/opensync-lab
    for n in pod-1 pod-2 pod-1-wc1 pod-2-wc1; do echo "PASS $n" > "/var/lib/opensync-lab/$n.status"; done
}

test_case "topology: healthy"
topology_lab
out=$(MVX_PODS=2 MVX_POD_CLIENTS=1 bash "$ROOT/guest/85-topology.sh" 2>&1); rc=$?
assert_eq "$rc" 0 "exit status"
assert_match "$out" "PASS mv3 backhaul +2 stations on wl1.1" "backhaul"
assert_match "$out" "PASS mv3 GRE ports +pgd1_50 pgd1_51 in brlan0" "GRE ports"
assert_match "$out" "PASS pod-1 +POD1 fronthaul 12:00:00:00:01:24, clients: pod-1-wc1=10.0.0.11" "pod-1"
assert_match "$out" "PASS pod-2 +POD2" "pod-2"
assert_match "$out" "PASS topology view" "the web UI's counts"
assert_file /var/lib/opensync-lab/topology.status "^PASS mv3\+2x1 "

test_case "topology: a pod off the backhaul"
topology_lab
out=$(MISSING=pod-2 MVX_PODS=2 MVX_POD_CLIENTS=1 bash "$ROOT/guest/85-topology.sh" 2>&1); rc=$?
assert_eq "$rc" 1 "exit status"
assert_match "$out" "FAIL mv3 backhaul +1 stations on wl1.1, want 2" "backhaul"
assert_match "$out" "FAIL pod-2 +POD2: not-on-backhaul" "pod-2 says why"
assert_match "$out" "PASS pod-1" "pod-1 still passes"
assert_file /var/lib/opensync-lab/topology.status "^FAIL mv3\+2x1 "

test_case "topology: a client's check failed"
topology_lab
echo "FAIL no lease" > /var/lib/opensync-lab/pod-1-wc1.status
out=$(MVX_PODS=2 MVX_POD_CLIENTS=1 bash "$ROOT/guest/85-topology.sh" 2>&1); rc=$?
assert_eq "$rc" 1 "exit status"
assert_match "$out" "FAIL pod-1 +POD1: pod-1-wc1\(check=FAIL lease=10.0.0.11 on-pod=1\)" "the client named"

echo "== guest/75-pod-planb.sh"

# a pod: running; ovsdb-server killed by pkill; systemd's restart count and the service's
# state after the kill as $RESTARTED/$SVC_STATE say ($STATE is common.sh's); the journal with
# $ABORTS libev aborts
planb_pod() {
    rm -f "$STUB_DIR/killed"
    behave lxc <<'EOF'
case "$*" in
    "list ^pod-1"*) echo RUNNING ;;
    *"pkill -x ovsdb-server") touch "$STUB_DIR/killed" ;;
    *"NRestarts --value") if [ -e "$STUB_DIR/killed" ]; then echo "$RESTARTED"; else echo 0; fi ;;
    *"is-active opensync.service") if [ -e "$STUB_DIR/killed" ]; then echo "$SVC_STATE"; else echo active; fi ;;
    *"AWLAN_Node id") [ "$SVC_STATE" = active ] && echo POD1 ;;
    *"date +%s") echo 1000 ;;
    *journalctl*)
        echo "OVSDB: Connection to OVSDB is lost, restarting OpenSync"
        echo "TARGET: Plan B is executing restart script: /usr/opensync/scripts/restart.sh"
        for _ in $(seq 1 "$ABORTS"); do echo "(libev) epoll_wait: Invalid argument"; done ;;
    *"-p ActiveState -p Result -p NRestarts") printf 'ActiveState=failed\nResult=exit-code\nNRestarts=0\n' ;;
esac
EOF
}

test_case "planb: OpenSync restarted by systemd, no abort"
planb_pod
out=$(RESTARTED=1 SVC_STATE=active ABORTS=0 bash "$ROOT/guest/75-pod-planb.sh" pod-1 2>&1); rc=$?
assert_eq "$rc" 0 "exit status"
assert_called "lxc exec pod-1 -- pkill -x ovsdb-server"
assert_match "$out" "OpenSync back after .* s \(restarts: 1\)" "back by itself"
assert_match "$out" "no Plan B child aborted" "no abort"
assert_match "$out" "planb: PASS" "PASS"

test_case "planb: before the fix (Restart=no, libev aborts)"
planb_pod
out=$(MVX_PLANB_WAIT=2 RESTARTED=0 SVC_STATE=failed ABORTS=12 bash "$ROOT/guest/75-pod-planb.sh" pod-1 2>&1); rc=$?
assert_eq "$rc" 1 "exit status"
assert_match "$out" "OpenSync not back: ActiveState=failed Result=exit-code NRestarts=0" "the service stayed down"
assert_match "$out" "12 Plan B child\(ren\) aborted in libev" "the aborts counted"
assert_match "$out" "planb: FAIL" "FAIL"

test_case "planb: no such pod"
behave lxc <<'EOF'
echo STOPPED
EOF
out=$(bash "$ROOT/guest/75-pod-planb.sh" pod-9 2>&1); rc=$?
assert_eq "$rc" 1 "exit status"
assert_match "$out" "pod pod-9 is not running" "says so"
assert_no_match "$(cat "$STUB_LOG")" "pkill" "nothing killed"

echo
echo "== $TESTS cases, $FAILS failed checks"
[ "$FAILS" -eq 0 ]
