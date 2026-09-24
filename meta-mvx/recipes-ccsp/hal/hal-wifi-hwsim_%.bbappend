FILESEXTRAPATHS:prepend := "${THISDIR}/hal-wifi-hwsim:"
SRC_URI += " \
    file://0001-vap-report-the-real-VAP-security-and-state-keep-a-ru.patch \
    file://0002-mlme-forget-a-station-on-deauth-disassoc-and-on-a-ne.patch \
"
