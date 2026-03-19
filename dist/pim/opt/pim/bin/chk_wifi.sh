#!/bin/bash
FLAG_PATH="/tmp"
tag=$(basename "$0")
timestamp=`date +"%Y-%m-%d %T,%3N"`

write_wifi_err() {
    local msg="$1"
    printf "%s %s\n" "$timestamp" "$msg" > "${FLAG_PATH}/err_wifi.log"
}

write_wifi_connected() {
    local msg="$1"
    printf "%s %s\n" "$timestamp" "$msg" > "${FLAG_PATH}/wifi_connected.log"
}

JSON_PREFIX=edgeconf_
JSON_SUFFIX=.json
TEST_CONFIG_FILE=""
for f in /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX}; do
    [ -e "$f" ] || continue
    if [ -z "$TEST_CONFIG_FILE" ] || [ "$f" -nt "$TEST_CONFIG_FILE" ]; then
        TEST_CONFIG_FILE="$f"
    fi
done
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
	write_wifi_err "WIFI ERR"
	logger -p local0.error "[CHK][$tag:$LINENO] WIFI PCI ERR"
else	
	IW_DEV_RESULT=$(iw dev 2> /dev/null)
	WLAN0_FIND=$(echo $IW_DEV_RESULT | grep -o 'wlp1s0')
		
	if [ "$WLAN0_FIND" != "wlp1s0" ]; then
		logger -p local0.error "[CHK][$tag:$LINENO] WIFI IW ERR"
		write_wifi_err "WIFI ERR"
	else
		WIFI_IP=$(ifconfig wlp1s0 | awk '/inet / {print $2}')
		if [ "$WIFI_IP" ] ; then
			logger -p local0.debug "[CHK][$tag:$LINENO] WIFI IP ADDR : $WIFI_IP"
			write_wifi_connected "$WIFI_IP"
		fi
			
		
		val=$(cat "$TEST_CONFIG_FILE" | grep wifi_signal_check | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
		if [ "$val" == "y" ]; then
			WIFI_SSID=$(iw wlp1s0 link | grep SSID | cut -d':' -f2)
			if [ -z "$WIFI_SSID" ] ; then
				logger -p local0.error "[CHK][$tag:$LINENO] WIFI CONNECT ERR"
				write_wifi_err "${WIFI_IP}"
			else
				_success_value=" 0% packet loss"
				IP_ADDR=$(cat "$TEST_CONFIG_FILE" | grep wifi_test_ip_addr | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
				WIFI_SIG=$(iw wlp1s0 link | grep signal | cut -d':' -f2 | tr -d ' ' | tr -d 'dBm')
				logger -p local0.debug "[CHK][$tag:$LINENO] WIFI SSID : $WIFI_SSID"
				logger -p local0.debug "[CHK][$tag:$LINENO] WIFI Signal : $WIFI_SIG dBm"	
				logger -p local0.debug "[CHK][$tag:$LINENO] SERVER IP ADDR : $IP_ADDR"
				WIFI_PING=$(ping $IP_ADDR -c 3 -W 3 -s 1000)	
				if [[ $WIFI_PING != *"$_success_value"* ]]; then
					logger -p local0.info "[CHK][$tag:$LINENO] WIFI PING ERR"
					write_wifi_err "WIFI ERR"
				fi
			fi
		fi		
	fi
fi	
