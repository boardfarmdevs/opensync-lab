#!/usr/bin/env bash
# WAN connectivity check for the mvx container. Hard checks (the result):
# WAN IPv4 lease from boardfarm, default route via wan-cpe1, internet ping,
# DNS. Informational: mgmt VLAN lease, IPv6, hwsim radios, LAN client.
source "$(dirname "$0")/common.sh"
set +e
set +o pipefail   # probes pipe into grep -q; an early exit must not fail them

name=${1:?container name}
timeout=${MVX_WAN_TIMEOUT:-420}
fail=0 lines=()

cx() { lxc exec "$name" -- sh -c "$1" 2>/dev/null; }
result() {  # result PASS|FAIL|INFO <what> <detail>
    printf '  %-4s %-22s %s\n' "$1" "$2" "$3"
    lines+=("$1 $2: $3")
    [ "$1" = FAIL ] && fail=1
    return 0
}

echo "=== WAN check: $name (timeout ${timeout}s) ==="
# the image may reboot itself once after its first boot: allow for that
wait_for 180 3 "$name running" ct_running "$name" || die "$name is not running"

# 1. erouter0 IPv4 from dhcp-cpe1 (tagged data VLAN 1081 -> 10.70.0.0/24)
wan_ip() { cx "ip -4 -o addr show erouter0" | awk '{print $4}' | grep -m1 '^10\.70\.0\.'; }
t0=$SECONDS
if wait_for "$timeout" 5 "erouter0 IPv4" wan_ip; then
    result PASS "erouter0 IPv4" "$(wan_ip) (after $((SECONDS - t0))s)"
else
    result FAIL "erouter0 IPv4" "none in 10.70.0.0/24 after ${timeout}s: $(cx 'ip -4 -o addr show erouter0' | awk '{print $4}')"
fi

# 2. default route via wan-cpe1
gw=$(cx "ip -4 route show default" | awk '/default/ {print $3; exit}')
if [ "$gw" = 10.70.0.20 ]; then result PASS "default route" "via $gw"
else result FAIL "default route" "via '${gw:-none}' (expected 10.70.0.20)"; fi

# 3. internet
if wait_for 60 5 "ping 8.8.8.8" cx "ping -c1 -W3 8.8.8.8"; then
    result PASS "internet (ICMP)" "$(cx 'ping -c3 -W3 8.8.8.8' | tail -1)"
else
    result FAIL "internet (ICMP)" "8.8.8.8 unreachable"
fi

# 4. DNS: the OpenSync redirector must resolve (busybox nslookup: answers
#    follow the "Name:" line as "Address N: <ip> [<ptr>]")
dns=$(cx "nslookup wildfire.plume.tech 2>&1" | awk '/^Name:/ {n = 1; next} n && /^Address/ {print ($2 ~ /:$/) ? $3 : $2; exit}')
if [ -n "$dns" ]; then
    result PASS "DNS" "wildfire.plume.tech -> $dns (resolver $(cx "grep -m1 ^nameserver /etc/resolv.conf" | awk '{print $2}'))"
else
    result FAIL "DNS" "wildfire.plume.tech does not resolve ($(cx 'cat /etc/resolv.conf' | tr '\n' ' '))"
fi

# 5. TLS to the OpenSync redirector (the path cm uses): handshake + Plume cert
tls=$(cx "timeout 10 openssl s_client -connect wildfire.plume.tech:443 -servername wildfire.plume.tech </dev/null 2>/dev/null" \
      | sed -n 's/^subject=.*CN *= *//p' | head -1)
[ -n "$tls" ] && result PASS "TLS redirector:443" "handshake ok, server cert CN=$tls" \
              || result FAIL "TLS redirector:443" "no TLS handshake with wildfire.plume.tech:443"

# --- informational ---
mg=$(cx "ip -4 -o addr show" | awk '$4 ~ /^10\.50\.0\./ {print $2" "$4}' | head -1)
result INFO "mgmt VLAN (881)" "${mg:-no 10.50.0.0/24 address}"
v6=$(cx "ip -6 -o addr show erouter0 scope global" | awk '{print $4}' | head -1)
result INFO "erouter0 IPv6" "${v6:-none}"
radios=$(cx "ls /sys/class/ieee80211 2>/dev/null" | wc -l)
result INFO "hwsim radios" "$radios phy(s): $(cx 'ls /sys/class/net' | grep -E '^wlan' | tr '\n' ' ')"
lease=$(docker exec lan-cpe1 ip -4 -o addr show eth1 2>/dev/null | awk '{print $4}')
result INFO "LAN client lan-cpe1" "eth1 ${lease:-no IPv4}"

state="FAIL"
[ $fail -eq 0 ] && state="PASS"
{
    echo "$state $name $(date -Is)"
    printf '%s\n' "${lines[@]}"
} > "$STATE/wan.status"
echo "=== WAN check: $state ==="
exit $fail
