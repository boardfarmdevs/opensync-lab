# Fresh-VM reproduction (23 September 2026)

[Documents](../README.md)

The lab worked end to end, reproduced from a fresh VM with the scripts alone on
23 September 2026. That VM is not kept: the lab now runs as the base of the EMOSA
reference lab, where EMOSA and a prplMesh controller take the pods over (lab
configurations #3 and #4, in [easymesh-labs](https://mesh.vcpe.dev/)).

## Status

| Goal | Result |
|---|---|
| Pinned offline build | `mv3-lxd-r25-oe40-0923`: installed packages identical to the 0808 reference, all recorded SRCREVs match the pins |
| mv3 internet | erouter0 leases `10.70.0.x` from boardfarm Kea on tagged VLAN 1081; internet, DNS and TLS to the Plume redirector all work |
| OpenSync cloud | `Manager` ACTIVE on the theta dev controller; the `mv3` identity is claimed into a location and receives cloud config |
| Local cloud (local-noc) | the same node connects to `local-noc` over plain TCP (redirector -> controller, all 109 tables monitored and recorded) and switches back and forth with the Plume cloud |
| Topology view | local-noc's web UI on `http://<host>:8640/` shows the live location: 1 gateway, 3 extenders, 6 clients, their Wi-Fi links (band, channel) and the WAN, with draggable spring physics and per-node details |
| OpenSync extenders (GRE backhaul) | three OpenSync 6.6.1.0 pods with only hwsim radios join mv3's backhaul AP, build their GRE uplinks (`cm`), are claimed by local-noc through them and get their fronthaul; local-noc builds mv3's end of each tunnel. Two Alpine `wpa_supplicant` clients per pod, each pinned to its pod's fronthaul, get DHCP from mv3 and reach the internet (ICMP, DNS, HTTP) |

All of the mesh configuration goes through the cloud protocol, with local-noc
as the cloud.
