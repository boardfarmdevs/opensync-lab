#!/usr/bin/env bash
# Wireless client behind the extender: a small Alpine container whose only
# network is one hwsim radio (no wired NIC). wpa_supplicant joins the pod's
# fronthaul (home SSID, configured by local-noc), DHCP comes from the gateway
# across the pod's GRE backhaul, and the internet is reached as
#   client -wifi-> pod home-ap -> br-home -> GRE over wifi backhaul -> mv3 brlan0 -> WAN
source "$(dirname "$0")/common.sh"
set +e
set +o pipefail

name=${1:-wclient}
pod=${MVX_POD_NAME:-pod}
gw=${MVX_MESH_GATEWAY:-mv3}
ssid=${MVX_MESH_HOME_SSID:-mvx-opensync-home}
psk=${MVX_MESH_HOME_PSK:-mvx-opensync-home-psk}
image=mvx-wclient
base=${MVX_CLIENT_BASE_IMAGE:-images:alpine/3.22}
fail=0 lines=()

result() {
    printf '  %-4s %-24s %s\n' "$1" "$2" "$3"
    lines+=("$1 $2: $3")
    [ "$1" = FAIL ] && fail=1
    return 0
}
cx() { lxc exec "$name" -- sh -c "$1" 2>/dev/null; }

# client image: Alpine + wpa_supplicant/iw, installed once while it still has
# a normal NIC, then published locally
if ! lxc image info "$image" >/dev/null 2>&1; then
    log "client: building image $image (alpine + wpa_supplicant)"
    lxc delete -f "$image-build" >/dev/null 2>&1
    lxc launch "$base" "$image-build" >/dev/null || die "cannot launch $base"
    online() { lxc exec "$image-build" -- sh -c 'ping -c1 -W2 dl-cdn.alpinelinux.org' >/dev/null 2>&1; }
    wait_for 60 2 "$image-build online" online || die "$image-build has no network"
    lxc exec "$image-build" -- apk add -q wpa_supplicant iw >/dev/null || die "apk add failed"
    lxc stop "$image-build" && lxc publish "$image-build" --alias "$image" >/dev/null || die "publish failed"
    lxc delete "$image-build" >/dev/null
fi

log "client: (re)creating $name"
lxc delete -f "$name" >/dev/null 2>&1
lxc profile delete "$name" >/dev/null 2>&1
sleep 1
hwsim_reclaim
lxc profile create "$name" >/dev/null
lxc profile set "$name" security.privileged=true limits.memory=128MiB boot.autostart=false
lxc profile device add "$name" root disk path=/ pool=default >/dev/null
radio=$(hwsim_free | head -1)
[ -n "$radio" ] || die "no free hwsim radio"
lxc profile device add "$name" wlan0 nic nictype=physical parent="$radio" name=wlan0 >/dev/null
lxc launch "$image" "$name" -p "$name" >/dev/null || die "launch failed"
wait_for 60 2 "$name running" ct_running "$name" || die "$name did not start"
log "client: $name has $radio as wlan0 and no other NIC"

echo "=== wireless client: $name -> '$ssid' (pod $pod) ==="
nics=$(cx "ip -o link | grep -v ' lo:' | cut -d: -f2 | tr -d ' ' | tr '\n' ' '")
result INFO "interfaces" "$nics(no wired NIC)"

cx "mkdir -p /etc/wpa_supplicant; cat > /etc/wpa_supplicant/mvx.conf <<EOF
ctrl_interface=/run/wpa_supplicant
network={
    ssid=\"$ssid\"
    psk=\"$psk\"
    key_mgmt=WPA-PSK
    scan_ssid=1
}
EOF
ip link set wlan0 up; wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/mvx.conf -P /run/wpa_supplicant.pid >/dev/null"
assoc() { cx "wpa_cli -i wlan0 status" | grep -q '^wpa_state=COMPLETED'; }
if wait_for 90 3 "association with '$ssid'" assoc; then
    bssid=$(cx "wpa_cli -i wlan0 status" | sed -n 's/^bssid=//p')
    freq=$(cx "wpa_cli -i wlan0 status" | sed -n 's/^freq=//p')
    podmac=$(lxc exec "$pod" -- cat /sys/class/net/home-ap-24/address 2>/dev/null)
    if [ -n "$podmac" ] && [ "$bssid" = "$podmac" ]; then
        result PASS "association" "'$ssid' bssid $bssid ($freq MHz) = $pod home-ap-24"
    else
        result FAIL "association" "bssid $bssid is not $pod's home-ap-24 (${podmac:-unknown})"
    fi
else
    result FAIL "association" "$(cx "wpa_cli -i wlan0 status" | grep wpa_state)"
fi

mac=$(cx "cat /sys/class/net/wlan0/address")
if lxc exec "$pod" -- iw dev home-ap-24 station dump 2>/dev/null | grep -qi "Station $mac"; then
    result PASS "pod station" "$pod home-ap-24 lists $mac"
else
    result FAIL "pod station" "$mac not associated on $pod home-ap-24"
fi

# The gateway hands out global IPv6 but this lab has no IPv6 upstream (see
# README): keep the client on IPv4, or name lookups prefer unreachable AAAA.
cx "sysctl -qw net.ipv6.conf.wlan0.disable_ipv6=1"
cx "udhcpc -i wlan0 -n -q -t 10 -T 2 >/dev/null 2>&1"
ip=$(cx "ip -4 -o addr show wlan0" | awk '{print $4}')
route=$(cx "ip route" | awk '$1 == "default" {print $3; exit}')
lanip=$(lxc exec "$gw" -- sh -c "ip -4 -o addr show brlan0" 2>/dev/null | awk '{print $4}')
if [ -n "$ip" ] && [ -n "$route" ] && [ "$route" = "${lanip%/*}" ]; then
    result PASS "DHCP" "$ip via $route ($gw brlan0 $lanip, served across the GRE backhaul)"
else
    result FAIL "DHCP" "wlan0 '$ip' default via '$route' (want $gw brlan0 ${lanip:-?})"
fi
if lxc exec "$gw" -- grep -qi "$mac" /var/lib/misc/dnsmasq.leases 2>/dev/null; then
    result PASS "gateway lease" "$gw dnsmasq leased to $mac"
else
    result FAIL "gateway lease" "no lease for $mac in $gw's dnsmasq"
fi

if cx "ping -c3 -W3 8.8.8.8" | grep -q ' 0% packet loss'; then
    result PASS "internet (ICMP)" "$(cx 'ping -c3 -W3 8.8.8.8' | tail -1)"
else
    result FAIL "internet (ICMP)" "no reply from 8.8.8.8"
fi
if cx "nslookup example.com" | grep -qE 'Address.*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' ; then
    result PASS "DNS" "example.com resolves"
else
    result FAIL "DNS" "example.com does not resolve"
fi
code=$(cx "timeout 20 wget -T 15 -S -O /dev/null http://example.com 2>&1 | awk '/HTTP\//{print \$2}' | tail -1")
if [ "$code" = 200 ]; then
    result PASS "internet (HTTP)" "GET http://example.com -> 200"
else
    result FAIL "internet (HTTP)" "GET http://example.com -> '${code:-none}'"
fi

state=FAIL; [ $fail -eq 0 ] && state=PASS
{ echo "$state $name $(date -Is)"; printf '%s\n' "${lines[@]}"; } > "$STATE/client.status"
echo "=== wireless client: $state ==="
exit $fail
