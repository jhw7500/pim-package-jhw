#!/bin/bash
FLAG_PATH="/tmp"
tag=$(basename "$0")
timestamp=`date +"%Y-%m-%d %T,%3N"`

TEST_CONFIG_FILE="/root/shared_v/edgeconf_pim.json"
PCI_FIND=$(lspci | grep -o 'Marvell Technology')


for ((i=1;i<3;i++)); do
	if [ "$PCI_FIND" != "Marvell Technology" ]; then
		sleep 0.5
		PCI_FIND=$(lspci | grep -o 'Marvell Technology')
	else 
		break;
	fi	
done
	
if [ $i == 3 ] ; then
	echo "${timestamp} WIFI ERR" >> ${FLAG_PATH}/err_wifi.log
	logger -p local0.error -t $tag [CHK] WIFI PCI ERR
else	
	IW_DEV_RESULT=$(iw dev 2> /dev/null)
	WLAN0_FIND=$(echo $IW_DEV_RESULT | grep -o 'wlp1s0')
		
	if [ "$WLAN0_FIND" != "wlp1s0" ]; then
		logger -p local0.error -t $tag [CHK] WIFI IW ERR
		echo "${timestamp} WIFI ERR" >> ${FLAG_PATH}/err_wifi.log
	else
		val=$(cat "$TEST_CONFIG_FILE" | grep wifi_signal_check | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
		if [ "$val" == "y" ]; then
			WIFI_SSID=$(iw wlp1s0 link | grep SSID | cut -d':' -f2)
			if [ -z "$WIFI_SSID" ] ; then
				logger -p local0.error -t $tag [CHK] WIFI CONNECT ERR
				echo "${timestamp} WIFI ERR" >> ${FLAG_PATH}/err_wifi.log
			else
				_success_value=" 0% packet loss"
				IP_ADDR=$(cat "$TEST_CONFIG_FILE" | grep wifi_test_ip_addr | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
				WIFI_SIG=$(iw wlp1s0 link | grep signal | cut -d':' -f2 | tr -d ' ' | tr -d 'dBm')
				logger -p local0.error -t $tag [CHK] WIFI SSID : $WIFI_SSID
				logger -p local0.error -t $tag [CHK] WIFI IP ADDR : $IP_ADDR
				logger -p local0.error -t $tag [CHK] WIFI Signal : $WIFI_SIG dBm
				WIFI_PING=$(ping $IP_ADDR -c 3 -W 3 -s 1000)	
				if [[ $WIFI_PING != *"$_success_value"* ]]; then
					logger -p local0.error -t $tag [CHK] WIFI PING ERR
					echo "${timestamp} WIFI ERR" >> ${FLAG_PATH}/err_wifi.log				
				fi
			fi
		fi		
	fi
fi	
