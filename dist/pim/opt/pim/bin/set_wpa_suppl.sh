#!/bin/bash

/usr/bin/killall wpa_supplicant
for ((var=0 ; var < 5; var++)); do
	/sbin/wpa_supplicant -c /etc/wpa_supplicant/wpa_supplicant.conf -iwlp1s0 -Dnl80211,wext -B
	if [ $? -eq 0 ];then
	  echo "set_wpa_supplicant success"
	  exit 0
	else
	  echo "set wpa_supplicant fail try again"	
	fi
done
echo "set_wpa_supplicant fail"
exit 1
