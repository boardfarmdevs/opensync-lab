#!/usr/bin/env bash
# mac80211_hwsim radio pool, persistent across VM reboots. Same conventions
# as meta-lxd gen/gen-util.sh: load once, never reload, host-resident radios
# are named virt-wlanN and are "free".
source "$(dirname "$0")/common.sh"

radios=${MVX_HWSIM_POOL:-24}
channels=${MVX_HWSIM_CHANNELS:-2}

printf 'options mac80211_hwsim radios=%s channels=%s\n' "$radios" "$channels" \
    > /etc/modprobe.d/mvx-hwsim.conf
echo mac80211_hwsim > /etc/modules-load.d/mvx-hwsim.conf
install -m 0755 "$MVX_GUEST_ROOT/guest/files/mvx-hwsim-pool" /usr/local/sbin/
install -m 0644 "$MVX_GUEST_ROOT/guest/files/mvx-hwsim-pool.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable mvx-hwsim-pool.service >/dev/null 2>&1

if [ -d /sys/module/mac80211_hwsim ]; then
    live_r=$(cat /sys/module/mac80211_hwsim/parameters/radios)
    live_c=$(cat /sys/module/mac80211_hwsim/parameters/channels)
    if [ "$live_r" != "$radios" ] || [ "$live_c" != "$channels" ]; then
        # only safe while no container holds a radio
        if lxc list -c n --format csv 2>/dev/null | grep -q .; then
            die "hwsim loaded with radios=$live_r channels=$live_c, want $radios/$channels; stop all containers first"
        fi
        log "hwsim: reloading ($live_r/$live_c -> $radios/$channels)"
        modprobe -r mac80211_hwsim
    fi
fi
systemctl restart mvx-hwsim-pool.service

free=$(ls /sys/class/net | grep -c '^virt-wlan' || true)
[ "$free" -ge "$radios" ] || warn "only $free of $radios radios are host-resident"
set_status hwsim "ok radios=$radios channels=$channels free=$free"
log "hwsim: $(cat "$STATE/hwsim.status")"
