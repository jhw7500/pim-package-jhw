#!/bin/bash

/usr/bin/killall wpa_supplicant
for ((var=0 ; var < 5; var++)); do
	/sbin/wpa_supplicant -c /etc/wpa_supplicant/wpa_supplicant.conf -iwlp1s0 -Dnl80211,wext -B
	if [ $? -eq 0 ];then
	  logger -p local0.notice [WPA][$tag:$LINENO] set_wpa_supplicant chmask success
	  exit 0
	else
	  logger -p local0.notice [WPA][$tag:$LINENO] set_wpa_supplicant try again
	fi
done
logger -p local0.error [WPA][$tag:$LINENO] set_wpa_supplicant chmask fail
exit 1
