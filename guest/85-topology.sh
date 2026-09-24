#!/usr/bin/env bash
# The lab topology as a whole, from the gateway's and the cloud's side:
#   mv3 --wifi backhaul--> pod-1..N (GRE into brlan0) --fronthaul--> pod-N-wc1..M
# Every pod: associated to mv3's backhaul AP, its GRE a port of mv3's brlan0,
# claimed by local-noc, its own check PASS. Every client: its own check PASS,
# leased by mv3, associated to its own pod.
source "$(dirname "$0")/common.sh"
set +e
set +o pipefail

gw=${MVX_MESH_GATEWAY:-mv3}
bh_if=${MVX_MESH_BHAUL_IF:-wl1.1}
pods=${MVX_PODS:-3}
clients=${MVX_POD_CLIENTS:-2}
fail=0 lines=()
result() {
    printf '  %-4s %-22s %s\n' "$1" "$2" "$3"
    lines+=("$1 $2: $3")
    [ "$1" = FAIL ] && fail=1
    return 0
}
gx() { lxc exec "$gw" -- sh -c "export PATH=\$PATH:/usr/opensync/tools; $1" 2>/dev/null; }
verdict() { [ -f "$STATE/$1.status" ] && head -1 "$STATE/$1.status" | cut -d' ' -f1 || echo none; }

echo "=== topology: $gw + $pods pods x $clients clients ==="
stas=$(gx "iw dev $bh_if station dump" | awk '/^Station/{print $2}')
ports=$(gx "ovs-vsctl list-ports brlan0" | grep '^pgd')
nodes=$(docker exec local-noc noc-ctl nodes 2>/dev/null | awk '$2 == "controller" {print $1}' | sort -u)
leases=$(gx "cat /var/lib/misc/dnsmasq.leases")

n_sta=$(printf '%s\n' "$stas" | grep -c .)
n_gre=$(printf '%s\n' "$ports" | grep -c .)
[ "$n_sta" -eq "$pods" ] && result PASS "$gw backhaul" "$n_sta stations on $bh_if" \
                         || result FAIL "$gw backhaul" "$n_sta stations on $bh_if, want $pods"
[ "$n_gre" -eq "$pods" ] && result PASS "$gw GRE ports" "$(echo $ports) in brlan0" \
                         || result FAIL "$gw GRE ports" "'$(echo $ports)' in brlan0, want $pods"
printf '%s\n' "$nodes" | grep -qx "$gw" && result PASS "$gw cloud" "controller session in local-noc" \
                                       || result FAIL "$gw cloud" "no controller session in local-noc"

for p in $(seq 1 "$pods"); do
    pod=pod-$p
    id=$(lxc exec "$pod" -- /usr/opensync/tools/ovsh -r s AWLAN_Node id 2>/dev/null)
    stamac=$(lxc exec "$pod" -- cat /sys/class/net/bhaul-sta-50/address 2>/dev/null)
    fhmac=$(lxc exec "$pod" -- cat /sys/class/net/home-ap-24/address 2>/dev/null)
    ok=1 why=""
    [ "$(verdict "$pod")" = PASS ] || { ok=0; why="$why check=$(verdict "$pod")"; }
    printf '%s\n' "$stas" | grep -qix "$stamac" || { ok=0; why="$why not-on-backhaul"; }
    printf '%s\n' "$nodes" | grep -qx "$id" || { ok=0; why="$why not-claimed"; }
    wcs=""
    for c in $(seq 1 "$clients"); do
        wc=$pod-wc$c
        wmac=$(lxc exec "$wc" -- cat /sys/class/net/wlan0/address 2>/dev/null)
        wip=$(printf '%s\n' "$leases" | awk -v m="$wmac" 'tolower($2) == tolower(m) {print $3}')
        on=$(lxc exec "$pod" -- iw dev home-ap-24 station dump 2>/dev/null | grep -ci "Station $wmac")
        if [ "$(verdict "$wc")" = PASS ] && [ -n "$wip" ] && [ "$on" -ge 1 ]; then
            wcs="$wcs $wc=$wip"
        else
            ok=0; why="$why $wc(check=$(verdict "$wc") lease=${wip:-none} on-pod=$on)"
        fi
    done
    if [ $ok -eq 1 ]; then
        result PASS "$pod" "$id fronthaul $fhmac, clients:$wcs"
    else
        result FAIL "$pod" "${id:-?}:$why"
    fi
done

# the topology view (local-noc web UI) must show the same location
ui=${MVX_NOC_UI_PORT:-8640}
view=$(curl -fs "http://127.0.0.1:$ui/api/topology" | python3 -c '
import json, sys
c = json.load(sys.stdin)["counts"]
print(c["gateways"], c["extenders"], c["clients"], c["online"])' 2>/dev/null)
if [ "$view" = "1 $pods $((pods * clients)) $((pods + 1))" ]; then
    result PASS "topology view" "http://<host>:$ui/ shows 1 gateway, $pods extenders, $((pods * clients)) clients, all online"
else
    result FAIL "topology view" "api/topology counts '${view:-no answer}' (gateways extenders clients online)"
fi

state=FAIL; [ $fail -eq 0 ] && state=PASS
{ echo "$state $gw+${pods}x$clients $(date -Is)"; printf '%s\n' "${lines[@]}"; } > "$STATE/topology.status"
echo "=== topology: $state ==="
exit $fail
