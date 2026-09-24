# HWSIM_POD: the cfg80211 platform built with the native toolchain of the
# mvx-pod-buildenv container (Ubuntu 20.04) instead of an OpenWrt SDK.
TOOLCHAIN_DIR := /usr
TOOLCHAIN_PREFIX :=
# Nothing is staged: the layers add -I$(STAGING_DIR)/usr/include/openvswitch,
# which on a native build would put OVS's own util.h ahead of OpenSync's. Point
# STAGING_DIR at an empty dir and list the includes we do need, as core's
# native build does (OVS headers straight from its source tree).
STAGING_DIR := /opt/no-staging
STAGING_USR_LIB := /usr/lib/hostap-objs
OS_CFLAGS += -I/usr/include/protobuf-c -I$(OVS_SOURCE) -I$(OVS_SOURCE)/include
OS_CFLAGS += -fPIC -DARCH_X86
OS_LDFLAGS += -lssl -lcrypto -lpcap
# glibc 2.31 lacks strlcpy (the platform assumes musl)
OS_CFLAGS += -include $(CURDIR)/vendor/openwrt-template/build/compat/hwsim_pod_compat.h
# hostap: the platform links os_unix.o/wpa_ctrl.o from STAGING_USR_LIB. Core's
# src/lib/target adds the same two objects again whenever HOSTAP_SOURCE is set
# (meant for its unit-test native build), which duplicates them in libtarget.a,
# so clear it for make and name the tree separately.
HWSIM_POD_HOSTAP := /usr/src/hostap
override HOSTAP_SOURCE :=
# control-interface headers (OpenWrt's hostapd package would stage these)
OS_CFLAGS += -idirafter $(HWSIM_POD_HOSTAP)/src/common
# libnl3 (core adds these only in the HOSTAP_SOURCE block cleared above)
OS_CFLAGS += -I/usr/include/libnl3
OS_LDFLAGS += -lnl-genl-3 -lnl-3
