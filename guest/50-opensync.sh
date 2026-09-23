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
# the selection itself (see docs/PLAN.md), make it here -- same default NOC as
# f5685 without BUILD_OSRT, and what mv27/mv37 ship: theta-dev.
noc=${MVX_OPENSYNC_NOC:-theta-dev}
certdir=/usr/opensync/etc/certs
# Decided from the files, not the SSL table: on a fresh container OpenSync is
# not running yet (SON off), so the table cannot be read at this point.
missing=$(for f in ca.pem client.pem client_dec.key; do cx "test -e $certdir/$f" || echo "$f"; done)
if [ -n "$missing" ]; then
    cx "test -d $certdir/$noc" || die "no NOC certificate dir $certdir/$noc in the image"
    for f in $missing; do
        cx "ln -sfn $noc/$f $certdir/$f"
    done
    result INFO "client certificates" "image selects no NOC; linked $(echo $missing | wc -w) file(s) -> $noc/ (runtime workaround)"
    certs_linked=1
else
    result INFO "client certificates" "present: $certdir/client.pem -> $(cx "readlink $certdir/client.pem")"
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

# Uplink address family. cm only connects over a family it considers usable
# on the uplink (erouter0). OpenSync 4.4's cm2 decides that when it selects
# the link: if erouter0 has a global IPv6 address that is not blocked it
# takes IPv6 and never evaluates IPv4 at all (ipv4.is_ip stays false, "Ares:
# Skip ipv4 address. IP active: false") until erouter0's IPv4 address changes.
# That happens whenever OpenSync (re)starts while the WAN is already up, e.g.
# on a cloud switch. This lab gives the CPE global IPv6 but has no IPv6
# upstream, so cm then retries IPv6 forever. When cm is stuck and there is no
# IPv6 internet, mark IPv6 blocked on the uplink (cm's own mechanism for a
# failing family) and restart cm, so it selects IPv4. First boot also leaves
# Connection_Manager_Uplink.ipv4 unset; record it as ready.
# Retried while waiting for the controller below (rate-limited): right after
# boot the managers can be up before erouter0 has its WAN lease.
v6_internet=
cx "ping -6 -c1 -W3 2001:4860:4860::8888 >/dev/null 2>&1" && v6_internet=1
last_uplink_fix=-999
fix_uplink() {
    local uplink what=""
    [ "$(ovsh '-r s Manager is_connected')" = true ] && return 0
    [ $((SECONDS - last_uplink_fix)) -ge 90 ] || return 0
    uplink=$(ovsh "-r s Connection_Manager_Uplink if_name -w is_used==true" | head -1)
    uplink=${uplink:-erouter0}
    cx "ip -4 -o addr show $uplink" | grep -q inet || return 0
    if [ "$(ovsh "-r s Connection_Manager_Uplink ipv4 -w if_name==$uplink")" != ready ]; then
        ovsh "u Connection_Manager_Uplink -w if_name==$uplink ipv4:=ready" >/dev/null
        what="ipv4 unset -> ready"
    fi
    if [ -z "$v6_internet" ]; then
        ovsh "u Connection_Manager_Uplink -w if_name==$uplink ipv6:=blocked" >/dev/null
        what="${what:+$what, }ipv6 -> blocked (no IPv6 internet)"
    fi
    [ -n "$what" ] || return 0
    ovsh "u Node_Services -w service==cm enable:=false" >/dev/null
    sleep 3
    ovsh "u Node_Services -w service==cm enable:=true" >/dev/null
    last_uplink_fix=$SECONDS
    result INFO "uplink address family" "cm not connected; $uplink: $what; restarted cm (runtime workaround)"
}
fix_uplink

# the SSL table (read by ovsdb-server) must point at existing files
bad=$(for f in $(ovsh "-r s SSL private_key certificate ca_cert"); do cx "test -e $f" || echo "$f"; done)
[ -z "$bad" ] || result FAIL "SSL table files" "missing: $bad"

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
redir_ok() { fix_uplink; ovsh "-r s AWLAN_Node redirector_addr" | grep -q "$redir_host"; }
if wait_for 90 5 "redirector_addr" redir_ok; then
    result PASS "AWLAN_Node.redirector_addr" "$(ovsh '-r s AWLAN_Node redirector_addr')"
else
    result FAIL "AWLAN_Node.redirector_addr" "'$(ovsh '-r s AWLAN_Node redirector_addr')'"
fi

# L4b redirector -> controller assignment, then the controller connection
mgr_addr() { ovsh "-r s AWLAN_Node manager_addr" | grep -E '^(ssl|tcp):'; }
mgr_addr_wait() { fix_uplink; mgr_addr >/dev/null; }
if wait_for 360 5 "manager_addr" mgr_addr_wait; then
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

# local-noc: the controller side must see the node too
if [ "$redir_host" = "${MVX_LOCAL_NOC_IP:-}" ]; then
    node_id=$(ovsh '-r s AWLAN_Node id')
    noc_session() { docker exec local-noc noc-ctl nodes 2>/dev/null | awk -v n="$node_id" '$1 == n && $2 == "controller"' | tail -1; }
    noc_has_session() { [ -n "$(noc_session)" ]; }
    wait_for 120 5 "local-noc controller session" noc_has_session
    sess=$(noc_session)
    if [ -n "$sess" ]; then
        result PASS "local-noc session" "$(awk '{print $2, "from", $3, $4}' <<< "$sess") capture $(awk '{print $5}' <<< "$sess")"
    else
        result FAIL "local-noc session" "no controller session for this node in local-noc"
    fi
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
