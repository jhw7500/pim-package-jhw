#!/bin/bash
_root_path="/bin/"
success_val="simple:3:-70:300"

while true; do
    IW_DEV_RESULT=$(iw dev)
    BGSCAN_CHK=$(wpa_cli -p /run/wpa_supplicant -i wlp1s0 get_network 0 bgscan)
    if [[ "$BGSCAN_CHK" == *"$success_val"* ]]; then
      # echo "BGSCAN OK $BGSCAN_CHK $success_val"
	   sleep 60
    else
		wpa_cli -p /run/wpa_supplicant -i wlp1s0 set_network 0 bgscan '"simple:3:-70:300"'
		wpa_cli -p /run/wpa_supplicant -i wlp1s0 autoscan "periodic:30" 
		#echo "BGSCAN FAIL $BGSCAN_CHK $success_val"
		sleep 5
	fi
done


