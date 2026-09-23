#!/usr/bin/env bash
# local-noc: plain-TCP OpenSync cloud stand-in (local-noc/noc.py), a docker
# container on boardfarm's WAN segment (network wan-cpe1, like boardfarm's own
# services), so any CPE behind wan-cpe1 reaches it through the WAN NAT.
source "$(dirname "$0")/common.sh"

ip=${MVX_LOCAL_NOC_IP:-10.101.0.40}
rport=${MVX_LOCAL_NOC_REDIRECTOR_PORT:-6640}
cport=${MVX_LOCAL_NOC_CONTROLLER_PORT:-6641}

log "local-noc: building image"
docker build -q -t local-noc:latest "$MVX_GUEST_ROOT/local-noc" >/dev/null
docker rm -f local-noc >/dev/null 2>&1 || true
docker run -d --name local-noc --restart unless-stopped \
    -v local-noc-data:/var/lib/local-noc local-noc:latest \
    --advertise "$ip" --redirector-port "$rport" --controller-port "$cport" \
    --mesh-gateway "${MVX_MESH_GATEWAY:-mv3}" --mesh-bhaul-if "${MVX_MESH_BHAUL_IF:-wl1.1}" \
    --mesh-bhaul-ssid "${MVX_MESH_BHAUL_SSID:-mvx-opensync-bhaul}" \
    --mesh-bhaul-psk "${MVX_MESH_BHAUL_PSK:-mvx-opensync-bhaul-psk}" \
    --mesh-home-ssid "${MVX_MESH_HOME_SSID:-mvx-opensync-home}" \
    --mesh-home-psk "${MVX_MESH_HOME_PSK:-mvx-opensync-home-psk}" >/dev/null

cat > /etc/default/local-noc <<EOT
LOCAL_NOC_IP=$ip
EOT
install -m 0755 "$MVX_GUEST_ROOT/guest/files/local-noc-net" /usr/local/sbin/
install -m 0644 "$MVX_GUEST_ROOT/guest/files/local-noc-net.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable local-noc-net.service >/dev/null 2>&1
systemctl restart local-noc-net.service

reach() { docker exec wan-cpe1 sh -c "nc -z -w3 $ip $rport && nc -z -w3 $ip $cport"; }
wait_for 30 2 "local-noc reachable from wan-cpe1" reach || die "local-noc not reachable at $ip:$rport/$cport"
set_status local-noc "ok redirector tcp:$ip:$rport controller tcp:$ip:$cport"
log "local-noc: $(cat "$STATE/local-noc.status")"
