#!/bin/bash
JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
TEST_CONFIG_FILE=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
success_val="simple:3:-70:300"
ENABLE_VAL="true"
DISABLE_VAL="false"
tag=$(basename "$0")
chmask_en=0
IW_DEV_RESULT=0
BGSCAN_CHK=0

if [[ ! -s "$TEST_CONFIG_FILE" ]]; then 
	logger -p local0.error [BGS][$tag:$LINENO] Not Found $TEST_CONFIG_FILE
else
	chmask_en=$(cat $TEST_CONFIG_FILE | grep chmask | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	if [[ "$chmask_en" == *"$DISABLE_VAL"* ]] ; then	
		logger -p local0.notice [BGS][$tag:$LINENO] channel mask disable
		while true; do
			IW_DEV_RESULT=$(iw dev)
			BGSCAN_CHK=$(wpa_cli -p /run/wpa_supplicant -i wlp1s0 get_network 0 bgscan)
			if [[ "$BGSCAN_CHK" == *"$success_val"* ]]; then
			   #echo "BGSCAN OK $BGSCAN_CHK $success_val"
			   sleep 60
			else
				wpa_cli -p /run/wpa_supplicant -i wlp1s0 set_network 0 bgscan '"simple:3:-70:300"'
				wpa_cli -p /run/wpa_supplicant -i wlp1s0 autoscan "periodic:30" 
				#echo "BGSCAN FAIL $BGSCAN_CHK $success_val"
				sleep 5
			fi
		done
	else
		/opt/pim/bin/set_wpa_suppl.sh
		logger -p local0.notice [BGS][$tag:$LINENO] channel mask enable	
	fi
fi

