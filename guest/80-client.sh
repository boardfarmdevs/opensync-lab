#!/usr/bin/env bash
# Wireless client behind an extender: a small Alpine container whose only
# network is one hwsim radio (no wired NIC). wpa_supplicant joins the pod's
# fronthaul (home SSID, configured by local-noc; every pod uses the same SSID
# on the one hwsim medium, so the client is pinned to its pod's BSSID), DHCP
# comes from the gateway across the pod's GRE backhaul, and the internet is
# reached as
#
#   80-client.sh <name> <pod>
#   client -wifi-> pod home-ap -> br-home -> GRE over wifi backhaul -> mv3 brlan0 -> WAN
source "$(dirname "$0")/common.sh"
set +e
set +o pipefail

name=${1:-pod-1-wc1}
pod=${2:-pod-1}
gw=${MVX_MESH_GATEWAY:-mv3}
# MVX_CLIENT_SSID/PSK: join a fronthaul another manager configured (default: local-noc's)
ssid=${MVX_CLIENT_SSID:-${MVX_MESH_HOME_SSID:-opensync-lab-home}}
psk=${MVX_CLIENT_PSK:-${MVX_MESH_HOME_PSK:-opensync-lab-home-psk}}
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

ct_running "$pod" || die "pod $pod is not running (deploy-mvx.sh pod $pod)"
podmac=$(lxc exec "$pod" -- cat /sys/class/net/home-ap-24/address 2>/dev/null)
[ -n "$podmac" ] || die "$pod has no fronthaul home-ap-24 yet"

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

# The client runs its own networking like a device: an OpenRC boot script
# (local service) brings up wpa_supplicant on its pod's fronthaul and a
# udhcpc that stays running -- it keeps, renews and re-requests the lease
# from the gateway (also after a reassociation or a restart).
# The gateway hands out global IPv6 but this lab has no IPv6 upstream (see
# README): the client stays on IPv4, or name lookups prefer unreachable AAAA.
cx "mkdir -p /etc/wpa_supplicant /etc/local.d; cat > /etc/wpa_supplicant/opensync-lab.conf <<EOF
ctrl_interface=/run/wpa_supplicant
network={
    ssid=\"$ssid\"
    bssid=$podmac
    psk=\"$psk\"
    key_mgmt=WPA-PSK
    scan_ssid=1
}
EOF"
cx "cat > /etc/local.d/opensync-lab-wlan.start" <<'START'
#!/bin/sh
# wlan0: join the extender's fronthaul, keep a DHCP lease from the gateway
sysctl -qw net.ipv6.conf.wlan0.disable_ipv6=1
ip link set wlan0 up
pidof wpa_supplicant >/dev/null ||
    wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/opensync-lab.conf -P /run/wpa_supplicant.wlan0.pid
pidof udhcpc >/dev/null ||
    udhcpc -b -S -i wlan0 -p /run/udhcpc.wlan0.pid -t 10 -T 2 -A 5
START
cx "chmod +x /etc/local.d/opensync-lab-wlan.start; rc-update add local default >/dev/null 2>&1; /etc/local.d/opensync-lab-wlan.start >/dev/null 2>&1"
assoc() { cx "wpa_cli -i wlan0 status" | grep -q '^wpa_state=COMPLETED'; }
if wait_for 90 3 "association with '$ssid'" assoc; then
    bssid=$(cx "wpa_cli -i wlan0 status" | sed -n 's/^bssid=//p')
    freq=$(cx "wpa_cli -i wlan0 status" | sed -n 's/^freq=//p')
    if [ "$bssid" = "$podmac" ]; then
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

leased() { cx "ip -4 -o addr show wlan0" | grep -q inet; }
wait_for 60 2 "DHCP lease on wlan0" leased
ip=$(cx "ip -4 -o addr show wlan0" | awk '{print $4}')
route=$(cx "ip route" | awk '$1 == "default" {print $3; exit}')
lanip=$(lxc exec "$gw" -- sh -c "ip -4 -o addr show brlan0" 2>/dev/null | awk '{print $4}')
if [ -n "$ip" ] && [ -n "$route" ] && [ "$route" = "${lanip%/*}" ]; then
    result PASS "DHCP" "$ip via $route ($gw brlan0 $lanip, served across the GRE backhaul)"
else
    result FAIL "DHCP" "wlan0 '$ip' default via '$route' (want $gw brlan0 ${lanip:-?})"
fi
dhcpc=$(cx "pidof udhcpc")
if [ -n "$dhcpc" ] && cx "rc-update show default" | grep -qw local; then
    result PASS "DHCP client" "udhcpc running (pid $dhcpc), started at boot by OpenRC local"
else
    result FAIL "DHCP client" "udhcpc pid '${dhcpc:-none}', boot script $(cx 'rc-update show default' | grep -qw local && echo enabled || echo 'not enabled')"
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
{ echo "$state $name via $pod $(date -Is)"; printf '%s\n' "${lines[@]}"; } > "$STATE/$name.status"
echo "=== wireless client: $state ==="
exit $fail
