#!/usr/bin/env bash
# Enable OpenSync (SON) on the mvx container and check the cloud connection:
#   L3 managers running (dm cm nm wm + ovsdb-server)
#   L4 MeshAgent bridged SONURL -> AWLAN_Node.redirector_addr,
#      cm reached the redirector and was handed a controller, Manager.is_connected
# Same dmcli sequence as boardfarm tests/opensync/test_opensync_cloud.py.
source "$(dirname "$0")/common.sh"
set +e
set +o pipefail   # probes pipe into grep -q; an early exit must not fail them

name=${1:?container name}
redirector=${MVX_OPENSYNC_REDIRECTOR:-ssl:wildfire.plume.tech:443}
redir_host=$(sed -E 's|^[a-z]+:||; s|:[0-9]+$||' <<< "$redirector")
fail=0 lines=()

cx() { lxc exec "$name" -- sh -c "$1" 2>/dev/null; }
ovsh() { cx "export PATH=\$PATH:/usr/opensync/tools:/usr/opensync/bin; ovsh $*"; }
result() {
    printf '  %-4s %-26s %s\n' "$1" "$2" "$3"
    lines+=("$1 $2: $3")
    [ "$1" = FAIL ] && fail=1
    return 0
}

echo "=== OpenSync: $name -> $redirector ==="
wait_for 180 3 "$name running" ct_running "$name" || die "$name is not running"
bm=$(cx "syscfg get bridge_mode")
[ -z "$bm" ] || [ "$bm" = 0 ] || die "$name is in bridge mode ($bm); OpenSync cloud needs router mode"
cx "test -x /usr/opensync/scripts/opensync.init" || die "no OpenSync in this image"

# Client certificates. ovsdb-server takes them from the OVSDB SSL table
# (/usr/opensync/etc/certs/{ca,client}.pem, client_dec.key). On the real
# board meta-rdk-opensync-sagemcom's do_install:append:f5685 symlinks those to
# one NOC's directory; that override does not apply to MACHINE
# exm-qemux86-mv3, so the LXD image ships theta-dev/ + opensync-dev/ but no
# selection and cm can never complete TLS (BACKOFF). Until meta-lxd-mv3 does
# the selection itself (see doc/PLAN.md), make it here -- same default NOC as
# f5685 without BUILD_OSRT, and what mv27/mv37 ship: theta-dev.
noc=${MVX_OPENSYNC_NOC:-theta-dev}
missing=$(for f in $(ovsh "-r s SSL private_key certificate ca_cert"); do cx "test -e $f" || echo "$f"; done)
if [ -n "$missing" ]; then
    cx "test -d /usr/opensync/etc/certs/$noc" || die "no NOC certificate dir /usr/opensync/etc/certs/$noc in the image"
    for f in $missing; do
        cx "ln -sfn $noc/$(basename "$f") $f"
    done
    result INFO "client certificates" "image selects no NOC; linked $(echo $missing | wc -w) file(s) -> $noc/ (runtime workaround)"
    certs_linked=1
else
    result INFO "client certificates" "present: $(ovsh '-r s SSL certificate') -> $(cx "readlink $(ovsh '-r s SSL certificate')")"
fi

cur_admin=$(cx "dmcli eRT getv Device.X_LGI-COM_SON.SONAdminStatus" | awk '/value:/ {print $NF}')
cur_url=$(cx "dmcli eRT getv Device.X_LGI-COM_SON.SONURL" | awk '/value:/ {print $NF}')
if [ "$cur_admin" = true ] && [ "$cur_url" = "$redirector" ]; then
    log "SON already enabled with $redirector"
else
    log "enabling SON (SONURL=$redirector)"
    for kv in "SONURL string $redirector" "NativeAtmBsControl bool true" \
              "SONOperationalStatus bool true" "SONLogpullEnable bool true" \
              "SONAdminStatus bool true"; do
        set -- $kv
        cx "dmcli eRT setv Device.X_LGI-COM_SON.$1 $2 $3" | grep -q succeed \
            || warn "dmcli setv $1 did not report success"
    done
fi

# L3 managers
managers="ovsdb-server dm cm nm wm"
running() { local m; for m in $managers; do cx "pidof $m >/dev/null" || return 1; done; }
if wait_for 240 5 "OpenSync managers" running; then
    result PASS "managers" "$(for m in $managers; do printf '%s ' "$m"; done)running"
else
    missing=$(for m in $managers; do cx "pidof $m >/dev/null" || printf '%s ' "$m"; done)
    result FAIL "managers" "not running: $missing"
fi

# enabling SON leaves the LAN DHCP server down on this image (see common.sh)
if msg=$(fix_lan_dhcp "$name"); then
    result INFO "LAN DHCP (dnsmasq)" "$msg"
else
    result FAIL "LAN DHCP (dnsmasq)" "$msg"
fi

# If SON was already on (it persists in nvram), cm has been failing TLS since
# boot and its retry backoff has grown to minutes. Restart it so it retries
# with the certificates now in place -- through dm (Node_Services), which does
# not respawn a manager that was simply killed.
if [ -n "${certs_linked:-}" ] && [ "$cur_admin" = true ]; then
    ovsh "u Node_Services -w service==cm enable:=false" >/dev/null
    sleep 3
    ovsh "u Node_Services -w service==cm enable:=true" >/dev/null
    wait_for 60 3 "cm restarted" cx "pidof cm >/dev/null" \
        && log "restarted cm (Node_Services) to pick up the certificates" \
        || warn "cm did not come back after the Node_Services toggle"
fi

# L4a SONURL -> AWLAN_Node.redirector_addr (local MeshAgent bridge)
redir_ok() { ovsh "-r s AWLAN_Node redirector_addr" | grep -q "$redir_host"; }
if wait_for 90 5 "redirector_addr" redir_ok; then
    result PASS "AWLAN_Node.redirector_addr" "$(ovsh '-r s AWLAN_Node redirector_addr')"
else
    result FAIL "AWLAN_Node.redirector_addr" "'$(ovsh '-r s AWLAN_Node redirector_addr')'"
fi

# L4b redirector -> controller assignment, then the controller connection
mgr_addr() { ovsh "-r s AWLAN_Node manager_addr" | grep -E '^(ssl|tcp):'; }
if wait_for 360 5 "manager_addr" mgr_addr; then
    result PASS "controller assigned" "AWLAN_Node.manager_addr=$(mgr_addr)"
else
    result FAIL "controller assigned" "AWLAN_Node.manager_addr empty (redirector not reached, or node unknown to the cloud)"
fi
connected() { [ "$(ovsh '-r s Manager is_connected')" = true ]; }
if wait_for 240 5 "Manager.is_connected" connected; then
    result PASS "Manager.is_connected" "true -> $(ovsh '-r s Manager target')"
else
    result FAIL "Manager.is_connected" "$(ovsh '-r s Manager is_connected') (target $(ovsh '-r s Manager target'), status $(ovsh '-r s Manager status' | tr '\n' ' '))"
fi

# informational: identity the cloud sees, and whether it pushed config
result INFO "node identity" "id=$(ovsh '-r s AWLAN_Node id') serial=$(ovsh '-r s AWLAN_Node serial_number') model=$(ovsh '-r s AWLAN_Node model')"
result INFO "cloud config (VIFs)" "$(ovsh '-r s Wifi_VIF_Config if_name' | tr '\n' ' ')"
result INFO "mqtt topics" "$(ovsh '-r s AWLAN_Node mqtt_topics' | head -c 120)"

ts=$(date +%Y%m%d-%H%M%S)
for t in AWLAN_Node Manager Wifi_Radio_State Wifi_VIF_State Wifi_Inet_State Connection_Manager_Uplink; do
    echo "### $t"; ovsh "s $t"
done > "$STATE/ovsdb-$name-$ts.txt"
result INFO "ovsdb dump" "$STATE/ovsdb-$name-$ts.txt"

state=FAIL; [ $fail -eq 0 ] && state=PASS
{ echo "$state $name $(date -Is)"; printf '%s\n' "${lines[@]}"; } > "$STATE/opensync.status"
echo "=== OpenSync: $state ==="
exit $fail
