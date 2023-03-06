#!/bin/bash
FLAG_PATH="/opt/pim/bin/bg_chk_flag"
LOG_PATH="/var/log"
timestamp=`date +"%Y-%m-%d %T,%3N"`

TEST_CONFIG_FILE="/root/shared_v/edgeconf_pim.json"
PCI_FIND=$(lspci | grep -o 'Marvell Technology')

function LogWrite() {
	timestamp=`date +"%Y-%m-%d %T,%3N"`
	if [ $# -eq 1 ]; then
		echo "${timestamp} $1" >> "${LOG_PATH}/bg_chk.log"				
	fi
}


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
	LogWrite "wifi pci fail"
else	
	IW_DEV_RESULT=$(iw dev 2> /dev/null)
	WLAN0_FIND=$(echo $IW_DEV_RESULT | grep -o 'wlp1s0')
		
	if [ "$WLAN0_FIND" != "wlp1s0" ]; then
		echo "${timestamp} WIFI ERR" >> ${FLAG_PATH}/err_wifi.log
            	LogWrite "wifi iw fail"
	else
		val=$(cat "$TEST_CONFIG_FILE" | grep wifi_signal_check | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
		if [ "$val" == "y" ]; then
			WIFI_SSID=$(iw wlp1s0 link | grep SSID | cut -d':' -f2)
			if [ -z "$WIFI_SSID" ] ; then
				LogWrite "WIFI connection fail"
				echo "${timestamp} WIFI ERR" >> ${FLAG_PATH}/err_wifi.log
			else
				_success_value=" 0% packet loss"
				IP_ADDR=$(cat "$TEST_CONFIG_FILE" | grep wifi_test_ip_addr | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
				WIFI_SIG=$(iw wlp1s0 link | grep signal | cut -d':' -f2 | tr -d ' ' | tr -d 'dBm')
				LogWrite "   SSID : $WIFI_SSID"
				LogWrite "   IP addr : $IP_ADDR"
				LogWrite "   Signal : $WIFI_SIG dBm"
				WIFI_PING=$(ping $IP_ADDR -c 3 -W 3 -s 1000)	
				if [[ $WIFI_PING != *"$_success_value"* ]]; then
					LogWrite "wifi ping fail"				
					echo "${timestamp} WIFI ERR" >> ${FLAG_PATH}/err_wifi.log				
				fi
			fi
		fi		
	fi
fi	
