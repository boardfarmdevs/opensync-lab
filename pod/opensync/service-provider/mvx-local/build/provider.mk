# opensync-lab cloud: local-noc on the lab VM's WAN segment (plain-TCP
# OVSDB redirector), and the onboarding credentials local-noc also puts on
# the gateway's backhaul VAP.
VALID_IMAGE_DEPLOYMENT_PROFILES += mvx-local

ifeq ($(IMAGE_DEPLOYMENT_PROFILE),mvx-local)
CONTROLLER_ADDR := "tcp:10.101.0.40:6640"
IMAGE_PROFILE_SUFFIX := "$(IMAGE_DEPLOYMENT_PROFILE)"
# unquoted: ovsdb.mk passes these to the bootstrap hooks inside single quotes
export BACKHAUL_SSID := opensync-lab-bhaul
export BACKHAUL_PASS := opensync-lab-bhaul-psk
# what the OVSDB bootstrap turns into Wifi_Credential_Config rows ("ssid;psk")
PROVIDER_BACKHAUL_CREDS := "opensync-lab-bhaul;opensync-lab-bhaul-psk"
endif
