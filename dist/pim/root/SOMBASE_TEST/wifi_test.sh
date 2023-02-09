#!/bin/bash

IP_ADDR="192.168.0.2"

function WIFI_TEST() {
	PCI_FIND=$(lspci | grep -o 'Marvell Technology')
	for ((i=1;i<3;i++)); do
		if [ "$PCI_FIND" != "Marvell Technology" ]; then
			sleep 0.5
			echo "try again.."
			PCI_FIND=$(lspci | grep -o 'Marvell Technology')
		else 
			break;
		fi	
	done
	
	if [ $i == 3 ] ; then
		echo "   fail"
	else	
		IW_DEV_RESULT=$(iw dev 2> /dev/null)
		WLAN0_FIND=$(echo $IW_DEV_RESULT | grep -o 'wlp1s0')
		
		if [ "$WLAN0_FIND" != "wlp1s0" ]; then
			echo "   fail"
		else
			val="y"
			if [ "$val" == "y" ]; then
				WIFI_SSID=$(iw wlp1s0 link | grep SSID | cut -d':' -f2)
				if [ -z "$WIFI_SSID" ] ; then
					echo "   WIFI connection fail"
				else
					_success_value=" 0% packet loss"
					
					WIFI_SIG=$(iw wlp1s0 link | grep signal | cut -d':' -f2 | tr -d ' ' | tr -d 'dBm')
					echo "   SSID : $WIFI_SSID"
					echo "   IP addr : $IP_ADDR"
					echo "   Signal : $WIFI_SIG dBm"
					WIFI_PING=$(ping $IP_ADDR -c 3 -W 3 -s 1000)	
					if [[ $WIFI_PING != *"$_success_value"* ]]; then
						echo "   wifi ping fail"				
					else
						echo "   wifi ping pass"				
					fi
				fi
			else
				
				echo "   pass"				
			fi
			
		fi
	fi	
}
_error_value="iperf3: error" 

function IPERF_TEST
{
	IPERF_RES=$(iperf3 -c $IP_ADDR)
	if [[ $IPERF_RES == *"$_error_value"* ]]; then
		echo "   wifi iperf fail"				
	else
		echo "   wifi iperf pass"				
	fi
}

WIFI_TEST;
IPERF_TEST;