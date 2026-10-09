# opensync-lab OpenSync pod: an LXD *system* container image (systemd), built
# with docker and exported as a rootfs. OpenSync 6.6.1.0 HWSIM_POD target
# (build-pod.sh), OVS ovsdb-server 2.8.7 and hostapd/wpa_supplicant from the
# build environment, runtime libraries from the same Ubuntu release.
ARG BUILDENV=mvx-pod-buildenv:focal
FROM ${BUILDENV} AS buildenv

# odhcp6c, OpenSync's DHCPv6 client (CONFIG_OSN_ODHCP6_PATH=/usr/sbin/odhcp6c), which
# Ubuntu does not package. The lab's pods never start it (their uplink is a GRE); a pod
# with an Ethernet uplink does, when its router offers DHCPv6 (an RDK gateway's LAN
# does), and without it nm fails on every try, then crashes, and dm takes OpenSync down
# (found with opensync-rpi's physical pods). OpenWrt's odhcp6c at the last commit that
# builds without libubox (OpenWrt 23.05's).
FROM ubuntu:20.04 AS odhcp6c
ARG DEBIAN_FRONTEND=noninteractive
ARG ODHCP6C_COMMIT=bcd283632ac13391aac3ebdd074d1fd832d76fa3
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc libc6-dev make cmake git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone -q https://github.com/openwrt/odhcp6c.git /src && cd /src \
    && git checkout -q "$ODHCP6C_COMMIT" && cmake . >/dev/null && make && strip odhcp6c

FROM ubuntu:20.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus kmod udev procps psmisc less vim-tiny ca-certificates \
        iproute2 iw iputils-ping bridge-utils ebtables iptables busybox tcpdump dnsmasq-base \
        libev4 libjansson4 libmosquitto1 libprotobuf-c1 libmxml1 libzmq5 libcurl4 libssl1.1 \
        libnl-3-200 libnl-genl-3-200 libnl-route-3-200 libpcap0.8 libmnl0 libjson-c4 \
        libsqlite3-0 zlib1g liblzo2-2 libuuid1 \
    && rm -rf /var/lib/apt/lists/*

# c-ares 1.18 (ares_getaddrinfo), as in the build environment
COPY --from=buildenv /tmp/libc-ares2_1.18.1-1ubuntu0.22.04.3_amd64.deb /tmp/
RUN dpkg -i /tmp/libc-ares2_*.deb && rm /tmp/*.deb

# Open vSwitch 2.8.7 (ovsdb only) and hostap at Plume's base commit + patches
COPY --from=buildenv /usr/sbin/ovsdb-server /usr/sbin/
COPY --from=buildenv /usr/bin/ovsdb-client /usr/bin/ovsdb-tool /usr/bin/ovs-appctl /usr/bin/
COPY --from=buildenv /usr/lib/libopenvswitch-2.8.so.0.0.7 /usr/lib/libovsdb-2.8.so.0.0.7 /usr/lib/
RUN ln -sf libopenvswitch-2.8.so.0.0.7 /usr/lib/libopenvswitch-2.8.so.0 \
    && ln -sf libovsdb-2.8.so.0.0.7 /usr/lib/libovsdb-2.8.so.0
COPY --from=buildenv /usr/local/bin/hostapd /usr/local/bin/hostapd_cli /usr/local/bin/
COPY --from=buildenv /usr/local/sbin/wpa_supplicant /usr/local/sbin/wpa_cli /usr/local/sbin/
COPY --from=odhcp6c /src/odhcp6c /usr/sbin/odhcp6c.openwrt
# OpenSync passes Plume's odhcp6c options (-Q, -X); the wrapper maps them
COPY files/odhcp6c /usr/sbin/odhcp6c

# OpenSync: only what belongs on an Ubuntu system (not the OpenWrt /etc files)
COPY rootfs/usr/opensync /usr/opensync
COPY rootfs/lib/systemd/system/opensync.service /lib/systemd/system/
# Plan B's restart under systemd (core patch 0005: its child no longer aborts)
COPY files/opensync-restart.conf /etc/systemd/system/opensync.service.d/restart.conf
COPY rootfs/etc/sysctl.d/ /etc/sysctl.d/
COPY files/openvswitch.init /etc/init.d/openvswitch
COPY files/wpad.init /etc/init.d/wpad
COPY files/opensync.init /usr/opensync/scripts/opensync.init
COPY files/mvx-pod-prep files/mvx-pod-bootstrap /usr/local/sbin/
# the DHCP lease's DNS servers into OpenSync's resolver (files/udhcpc-lease-dns)
COPY files/udhcpc-lease-dns /usr/opensync/scripts/udhcpc.d/50-lease-dns
COPY files/mvx-pod-prep.service /lib/systemd/system/
COPY files/journald-50-lab.conf /etc/systemd/journald.conf.d/50-lab.conf
RUN echo /usr/opensync/lib > /etc/ld.so.conf.d/opensync.conf && ldconfig \
    && mkdir -p /var/log/opensync/crash \
    && ln -sf /usr/opensync/scripts/opensync_functions.sh /lib/opensync_functions.sh \
    && ln -sf /bin/busybox /sbin/udhcpc \
    && for a in route ifconfig; do command -v $a >/dev/null || ln -s /bin/busybox /sbin/$a; done \
    && systemctl enable mvx-pod-prep.service \
    && ln -sf /lib/systemd/system/opensync.service /etc/systemd/system/multi-user.target.wants/opensync.service \
    && systemctl mask systemd-networkd.service systemd-resolved.service apt-daily.timer apt-daily-upgrade.timer \
    && /usr/opensync/bin/cm -h >/dev/null 2>&1; ldd /usr/opensync/bin/cm /usr/opensync/bin/owm | grep "not found" && exit 1 || true

# (udhcpc.sh installs the DHCP default route with net-tools' `route`, which
# busybox provides as on OpenWrt; without it the pod has no default route.)
# OpenSync's scripts are written for OpenWrt's /bin/sh, busybox ash (e.g.
# 52_owm_prep.sh's ${mac:2} substring expansion, which dash lacks and which
# silently yields empty MAC addresses for the AP VIFs). Match it.
RUN ln -sf /bin/busybox /bin/sh
