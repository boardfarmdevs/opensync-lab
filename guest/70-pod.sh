#!/usr/bin/env bash
# Launch the OpenSync pod (extender) container: the mvx-pod LXD image
# (build-pod.sh), 2 radios from the hwsim pool (1st -> 2.4G fronthaul,
# 2nd -> 5G backhaul STA), and NO wired network -- the pod's only way out
# is the Wi-Fi backhaul to the gateway, which OpenSync's cm onboards over.
# Then check the onboarding end to end (backhaul, both GRE ends, LAN, cloud
# claim, fronthaul).
source "$(dirname "$0")/common.sh"
set +e
set +o pipefail

name=${1:-pod-1}
radios=${MVX_POD_RADIOS:-2}
meta=$MVX_GUEST_ROOT/pod/mvx-pod.metadata.tar.gz
rootfs=$MVX_GUEST_ROOT/pod/mvx-pod.rootfs.tar.gz
[ -e "$rootfs" ] || die "no pod image in $MVX_GUEST_ROOT/pod (run: deploy-mvx.sh pod-push)"

fp=$(sha256sum "$rootfs" | cut -c1-12)
if ! lxc image info "mvx-pod-$fp" >/dev/null 2>&1; then
    log "pod: importing image ($fp)"
    lxc image import "$meta" "$rootfs" --alias "mvx-pod-$fp" >/dev/null || die "image import failed"
fi

log "pod: (re)creating $name"
lxc delete -f "$name" >/dev/null 2>&1
lxc profile delete "$name" >/dev/null 2>&1
sleep 1
hwsim_reclaim   # radios of earlier pods come back carrying OpenSync's VIFs
lxc profile create "$name" >/dev/null
lxc profile set "$name" security.privileged=true security.nesting=true \
    limits.memory=512MiB limits.cpu=2 boot.autostart=false
lxc profile device add "$name" root disk path=/ pool=default >/dev/null
free=($(hwsim_free))
[ "${#free[@]}" -ge "$radios" ] || die "only ${#free[@]} free hwsim radios, need $radios"
for i in $(seq 0 $((radios - 1))); do
    lxc profile device add "$name" "wlan$i" nic nictype=physical parent="${free[$i]}" name="wlan$i" >/dev/null \
        && log "pod: wlan$i <- ${free[$i]}"
done
lxc launch "mvx-pod-$fp" "$name" -p "$name" >/dev/null || die "launch failed"
lxc config set "$name" user.opensync-lab.image "$fp"

wait_for 120 2 "$name running" ct_running "$name" || die "$name did not start"
up() { [ "$(lxc exec "$name" -- systemctl is-active opensync.service 2>/dev/null)" = active ]; }
wait_for 180 3 "opensync.service active" up || {
    lxc exec "$name" -- journalctl -u mvx-pod-prep -u opensync --no-pager -n 40
    die "opensync.service did not become active in $name"
}
log "pod: $(lxc exec "$name" -- journalctl -u mvx-pod-prep -o cat --no-pager | tail -1)"
managers() { for m in ovsdb-server dm cm owm nm; do lxc exec "$name" -- pidof "$m" >/dev/null || return 1; done; }
wait_for 180 5 "pod managers" managers || warn "not all managers are running in $name"
lxc exec "$name" -- sh -c 'for m in ovsdb-server dm cm wm owm nm wano; do printf "%s:%s " $m "$(pidof $m >/dev/null && echo up || echo -)"; done; echo'
id=$(lxc exec "$name" -- /usr/opensync/tools/ovsh -r s AWLAN_Node id 2>/dev/null)
log "pod: launched $name id=$id"

# --- onboarding over the wifi backhaul -----------------------------------------
# The pod has no wired uplink: its bhaul-sta joins the gateway's backhaul AP,
# cm builds g-bhaul-sta-* to the gateway, local-noc (mesh) builds the
# gateway's end, br-home gets a LAN lease through it and the pod reaches
# local-noc -- which then claims it and gives it its fronthaul.
gw=${MVX_MESH_GATEWAY:-mv3}
bh_if=${MVX_MESH_BHAUL_IF:-wl1.1}
fail=0 lines=()
result() {
    printf '  %-4s %-24s %s\n' "$1" "$2" "$3"
    lines+=("$1 $2: $3")
    [ "$1" = FAIL ] && fail=1
    return 0
}
px() { lxc exec "$name" -- sh -c "export PATH=\$PATH:/usr/opensync/tools; $1" 2>/dev/null; }
gx() { lxc exec "$gw" -- sh -c "export PATH=\$PATH:/usr/opensync/tools; $1" 2>/dev/null; }
noc_claimed() { docker exec local-noc noc-ctl nodes 2>/dev/null | awk -v n="$id" '$1 == n && $2 == "controller"' | grep -q .; }

echo "=== extender: $name ($id) via $gw $bh_if ==="
case "${MVX_OPENSYNC_REDIRECTOR:-}" in
    tcp:"${MVX_LOCAL_NOC_IP:-10.101.0.40}":*) ;;
    *) warn "$gw is not on local-noc (${MVX_OPENSYNC_REDIRECTOR:-?}); the backhaul is orchestrated by local-noc (deploy-mvx.sh opensync --cloud local)" ;;
esac
wait_for 300 5 "$id claimed by local-noc" noc_claimed

bssid=$(px "iw dev bhaul-sta-50 link" | awk '/Connected to/{print $3}')
gwmac=$(gx "cat /sys/class/net/$bh_if/address")
if [ -n "$bssid" ] && [ "$bssid" = "$gwmac" ]; then
    result PASS "backhaul association" "bhaul-sta-50 -> $gw $bh_if ($bssid)"
else
    result FAIL "backhaul association" "bhaul-sta-50 '${bssid:-not connected}', $gw $bh_if is $gwmac"
fi
bhip=$(px "ip -4 -o addr show bhaul-sta-50" | awk '{print $4}')
gre=$(px "ip -d link show g-bhaul-sta-50" | grep -oE 'gretap remote [0-9.]+ local [0-9.]+')
if [ -n "$gre" ]; then
    result PASS "pod GRE (cm)" "g-bhaul-sta-50 $gre (bhaul $bhip)"
else
    result FAIL "pod GRE (cm)" "no g-bhaul-sta-50 (bhaul '${bhip:-none}')"
fi
ip4=${bhip%/*}
pgd=$(printf 'pgd%s_%s' "$(cut -d. -f3 <<< "$ip4")" "$(cut -d. -f4 <<< "$ip4")")
ggre=$(gx "ip -d link show $pgd" | grep -oE 'gretap remote [0-9.]+ local [0-9.]+')
if [ -n "$ggre" ] && [ "$(gx "ovs-vsctl port-to-br $pgd")" = brlan0 ]; then
    result PASS "gateway GRE (local-noc)" "$gw $pgd $ggre, port of brlan0"
else
    result FAIL "gateway GRE (local-noc)" "$gw $pgd: '${ggre:-missing}', bridge '$(gx "ovs-vsctl port-to-br $pgd")'"
fi
lan=$(px "ip -4 -o addr show br-home" | awk '{print $4}')
dgw=$(px "ip route show default" | awk '{print $3}')
if [ -n "$lan" ] && [ -n "$dgw" ]; then
    result PASS "pod LAN (br-home)" "$lan default via $dgw (the gateway, across the GRE)"
else
    result FAIL "pod LAN (br-home)" "br-home '${lan:-none}' default via '${dgw:-none}'"
fi
if noc_claimed; then
    result PASS "cloud (local-noc)" "$id: Manager $(px "ovsh -r s Manager target") connected=$(px "ovsh -r s Manager is_connected")"
else
    result FAIL "cloud (local-noc)" "$id has no controller session in local-noc"
fi
fh() { px "iw dev home-ap-24 info" | grep -q "ssid ${MVX_MESH_HOME_SSID:-opensync-lab-home}"; }
if wait_for 60 3 "fronthaul home-ap-24" fh; then
    result PASS "fronthaul (local-noc)" "home-ap-24 '${MVX_MESH_HOME_SSID:-opensync-lab-home}' $(px "iw dev home-ap-24 info" | awk '/channel/{print "ch"$2}') in br-home"
else
    result FAIL "fronthaul (local-noc)" "home-ap-24 not up: $(px "ovsh -r s Wifi_VIF_State -w if_name==home-ap-24 enabled")"
fi

state=FAIL; [ $fail -eq 0 ] && state=PASS
{ echo "$state $name id=$id $(date -Is)"; printf '%s\n' "${lines[@]}"; } > "$STATE/$name.status"
echo "=== extender: $state ==="
exit $fail
