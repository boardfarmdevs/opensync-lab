#!/usr/bin/env bash
# GRE backhaul: a second node (leaf, mv.sh -i 2, same image) joins the gateway
# over an hwsim RF backhaul; OpenSync's nm builds the gretap on both ends from
# Wifi_Inet_Config (if_type=gre); the tunnel is bridged into the gateway's LAN
# and an isolated Wi-Fi client behind the leaf gets DHCP + internet through it.
# Orchestration is meta-lxd gen/sim-mesh.sh (docs/opensync-mesh-hwsim.md).
#
# Cloud-driven GRE (the controller pushing bhaul VAPs + gre rows) additionally
# needs the node claimed into a location; this step proves the GRE machinery
# itself end to end, with the controller's config injected locally.
source "$(dirname "$0")/common.sh"
set +e
set +o pipefail   # probes pipe into grep -q; an early exit must not fail them

gw=${1:?gateway container}
leaf=${2:-${gw}-002}
source "$MVX_GUEST_ROOT/deploy.env"
GEN=$MVX_GUEST_ROOT/meta-lxd/gen
fail=0 lines=()
result() {
    printf '  %-4s %-22s %s\n' "$1" "$2" "$3"
    lines+=("$1 $2: $3")
    [ "$1" = FAIL ] && fail=1
    return 0
}
cx() { lxc exec "$1" -- sh -c "$2" 2>/dev/null; }

echo "=== GRE backhaul: $gw <-> $leaf ==="
cx "$gw" "pidof nm >/dev/null" || die "nm not running on $gw (run deploy-mvx.sh opensync first)"

# 1. leaf node (no WAN of its own: eth0 stays on meta-lxd's isolated 'wan' bridge)
if ! ct_running "$leaf"; then
    idx=$((10#${leaf##*-}))
    log "launching leaf $leaf (mv.sh -i $idx)"
    (cd "$GEN" && HWSIM_RADIOS=${MVX_HWSIM_RADIOS:-3} HWSIM_POOL_SIZE=${MVX_HWSIM_POOL:-24} \
        ./mv.sh "$image" -i "$idx") || die "mv.sh failed for $leaf"
fi
uptime_s() { cx "$leaf" "cut -d. -f1 /proc/uptime"; }
ready() { cx "$leaf" "timeout 10 dmcli eRT getv Device.DeviceInfo.SerialNumber | grep -q value" && cx "$leaf" "test -e /sys/class/net/wlan2"; }
# A freshly created mv3 reboots itself once, ~2-3 min after its first boot.
# Anything set up before that (backhaul STA, dmcli settings) is lost, so wait
# until the node has been up long enough to be past it.
settled() { [ "$(uptime_s)" -ge 300 ] 2>/dev/null && ready; }
log "waiting for $leaf to settle (past its first-boot reboot, CCSP up)"
wait_for 900 10 "$leaf settled" settled || die "$leaf did not settle"

cd "$GEN"
export GW=$gw LEAF=$leaf
BH_RADIO=wlan2 GW_BH_IP=169.254.100.1 LEAF_BH_IP=169.254.100.2 GRE_IF=gre-bhaul

# start from a clean slate if a previous run left mesh state behind
# (before enabling OpenSync on the leaf: sim-mesh.sh clean turns SON off there)
if ip netns list 2>/dev/null | grep -qw meshclient || cx "$gw" "ip link show $GRE_IF" >/dev/null; then
    log "cleaning up a previous mesh run"
    cx "$gw" "ovs-vsctl --if-exists del-port brlan0 $GRE_IF"
    ./sim-mesh.sh clean 2>&1 | sed 's/^/    /'
fi

# 2. OpenSync on the leaf. Same dmcli sequence as the gateway, with the real
#    redirector: mv3's MeshAgent crashes on the empty SONURL that sim-mesh.sh
#    uses for mv27 (and the self-healed restart then hangs dmcli). The leaf's
#    identity (mv3-002) is not claimed, so no cloud config competes with ours.
son=$(cx "$leaf" "timeout 10 dmcli eRT getv Device.X_LGI-COM_SON.SONAdminStatus" | awk '/value:/ {print $NF}')
if [ "$son" != true ]; then
    log "enabling OpenSync on $leaf"
    for kv in "SONURL string ${MVX_OPENSYNC_REDIRECTOR:-ssl:wildfire.plume.tech:443}" \
              "NativeAtmBsControl bool true" "SONOperationalStatus bool true" \
              "SONLogpullEnable bool true" "SONAdminStatus bool true"; do
        set -- $kv
        cx "$leaf" "timeout 20 dmcli eRT setv Device.X_LGI-COM_SON.$1 $2 $3" | grep -q succeed \
            || warn "$leaf: dmcli setv $1 did not report success"
    done
fi
wait_for 240 5 "nm on $leaf" cx "$leaf" "pidof nm >/dev/null && pidof dm >/dev/null" \
    && result PASS "OpenSync on leaf" "nm/dm running on $leaf" \
    || result FAIL "OpenSync on leaf" "nm not running on $leaf"

# 3. RF backhaul (hostapd AP on the gateway's wlan2 <-> STA on the leaf's wlan2)
log "sim-mesh.sh backhaul"
./sim-mesh.sh backhaul 2>&1 | sed 's/^/    /'

# 4. GRE: nm builds the gretap on both ends from an injected Wifi_Inet_Config
#    row (if_type=gre) -- what the controller would push for a joined pod.
inject_gre() {  # <node> <local-bh-ip> <remote-bh-ip>
    cx "$1" "export PATH=\$PATH:/usr/opensync/tools
        ovsh d Wifi_Inet_Config -w if_name==$GRE_IF >/dev/null 2>&1
        ovsh i Wifi_Inet_Config if_name:=$GRE_IF if_type:=gre enabled:=true network:=true \
            gre_ifname:=$BH_RADIO gre_local_inet_addr:=$2 gre_remote_inet_addr:=$3 \
            ip_assign_scheme:=none >/dev/null"
}
log "OpenSync GRE: Wifi_Inet_Config if_type=gre on $gw and $leaf"
inject_gre "$gw"   "$GW_BH_IP"   "$LEAF_BH_IP"
inject_gre "$leaf" "$LEAF_BH_IP" "$GW_BH_IP"
gre_up() { cx "$1" "ip -o link show $GRE_IF" | grep -q LOWER_UP; }
wait_for 60 3 "gretap on $gw" gre_up "$gw"
wait_for 60 3 "gretap on $leaf" gre_up "$leaf"

# 5. LAN datapath through the tunnel. Leaf side: sim-mesh.sh lan (br-mesh =
#    gretap + client AP 'MeshHome' on wlan0). Gateway side: with SON on, mv3's
#    brlan0 is an OpenSync-managed Open vSwitch bridge, so the tunnel joins it
#    as an OVS port -- as a pod's GRE does -- not with 'ip link set master'
#    (sim-mesh.sh's way, "Operation not supported" on OVS).
log "sim-mesh.sh lan"
./sim-mesh.sh lan 2>&1 | sed 's/^/    /'
if cx "$gw" "ovs-vsctl br-exists brlan0"; then
    cx "$gw" "ip addr flush dev $GRE_IF; ovs-vsctl --may-exist add-port brlan0 $GRE_IF"
    log "gateway: $GRE_IF added as an OVS port of brlan0"
fi
log "gateway LAN DHCP: $(fix_lan_dhcp "$gw")"

# 6. an isolated Wi-Fi client behind the leaf: DHCP + internet through the GRE
log "sim-mesh.sh client"
./sim-mesh.sh client 2>&1 | sed 's/^/    /'

# verdicts, from the system state rather than the script's exit codes
ovs() { cx "$1" "export PATH=\$PATH:/usr/opensync/tools; ovsh -r s Wifi_Inet_State if_name if_type enabled -w if_name==gre-bhaul"; }
bh=$(cx "$leaf" "iw dev wlan2 link" | awk '/Connected to/ {print $3}')
[ -n "$bh" ] && result PASS "RF backhaul" "$leaf wlan2 associated to $bh" \
             || result FAIL "RF backhaul" "$leaf wlan2 not associated"
for n in "$gw" "$leaf"; do
    st=$(ovs "$n" | tr '\n' ' ')
    link=$(cx "$n" "ip -d link show gre-bhaul" | grep -oE 'gretap remote [0-9.]+ local [0-9.]+')
    if [ -n "$link" ] && grep -q gre <<< "$st"; then
        result PASS "nm gretap $n" "$link (Wifi_Inet_State: $st)"
    else
        result FAIL "nm gretap $n" "state='$st' link='$link'"
    fi
done
if [ "$(cx "$gw" "ovs-vsctl port-to-br gre-bhaul")" = brlan0 ]; then
    result PASS "gateway LAN bridge" "gre-bhaul is an OVS port of brlan0"
elif cx "$gw" "ip -o link show gre-bhaul" | grep -q 'master brlan0'; then
    result PASS "gateway LAN bridge" "gre-bhaul is a port of brlan0"
else
    result FAIL "gateway LAN bridge" "gre-bhaul is not on brlan0"
fi
lease=$(ip netns exec meshclient ip -4 -o addr show 2>/dev/null | awk '$2 != "lo" {print $4}' | head -1)
[ -n "$lease" ] && result PASS "client DHCP via GRE" "$lease (from $gw dnsmasq over the tunnel)" \
                || result FAIL "client DHCP via GRE" "no address in netns meshclient"
if ip netns exec meshclient ping -c3 -W3 8.8.8.8 >/dev/null 2>&1; then
    result PASS "client internet" "8.8.8.8 via leaf -> GRE -> $gw -> WAN"
else
    result FAIL "client internet" "8.8.8.8 unreachable from the client"
fi

state=FAIL; [ $fail -eq 0 ] && state=PASS
{ echo "$state $gw<->$leaf $(date -Is)"; printf '%s\n' "${lines[@]}"; } > "$STATE/gre.status"
echo "=== GRE backhaul: $state ==="
exit $fail
