#!/bin/bash
tag=$(basename "$0")

dev_wlan=$(python3 /opt/cis/bin/getconfval.py dev_wlan | tr -d '\r\n')
chmask_en=$(python3 /opt/cis/bin/getconfval.py WIFI_CHMASK_EN | tr -d '\r\n')
old_chmask_en=""
wpa_bgscan_parm=$(python3 /opt/cis/bin/getconfval.py WIFI_BGSCAN_PARAM | tr -d '\r\n')
wpa_autoscan_parm=$(python3 /opt/cis/bin/getconfval.py WIFI_AUTOSCAN_PARAM | tr -d '\r\n')

DISABLE_VAL="False"
BGSCAN_CHK=0

while true; do
	chmask_en=$(python3 /opt/cis/bin/getconfval.py WIFI_CHMASK_EN | tr -d '\r\n')
	if [[ "$chmask_en" != "$old_chmask_en" ]] ; then
		if [[ "$chmask_en" == *"$DISABLE_VAL"* ]] ; then
			logger -p local0.notice [BGS][$tag:$LINENO] channel mask disable
		else
			logger -p local0.notice [BGS][$tag:$LINENO] channel mask enable
		fi
		old_chmask_en="$chmask_en"
	fi

	if [[ "$chmask_en" == *"$DISABLE_VAL"* ]] ; then
		BGSCAN_CHK=$(wpa_cli -p /run/wpa_supplicant -i $dev_wlan get_network 0 bgscan)
		if [[ "$BGSCAN_CHK" == *"$wpa_bgscan_parm"* ]]; then
			#logger -p local0.notice [BGS][$tag:$LINENO] success bgscan ${BGSCAN_CHK}
			sleep 60
		else
			#logger -p local0.notice [BGS][$tag:$LINENO] fail bgscan ${wpa_bgscan_parm}
			wpa_cli -p /run/wpa_supplicant -i $dev_wlan set_network 0 bgscan '"'$wpa_bgscan_parm'"' > /dev/null 2> /dev/null
			wpa_cli -p /run/wpa_supplicant -i $dev_wlan autoscan '"'$wpa_autoscan_parm'"' > /dev/null 2> /dev/null
			sleep 5
		fi
	else
		sleep 5
	fi
done
