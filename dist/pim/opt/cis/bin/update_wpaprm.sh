#!/bin/bash
_dev_wlan=$(python3 /opt/cis/bin/getconfval.py dev_wlan | tr -d '\r\n')
_wpa_bgscan_parm=$(python3 /opt/cis/bin/getconfval.py WIFI_BGSCAN_PARAM | tr -d '\r\n')
if [ ! -z "$_wpa_bgscan_parm" -o "$_wpa_bgscan_parm" == " " -o "$_wpa_bgscan_parm" == "" ]; then
    wpa_cli -p /run/wpa_supplicant -i $_dev_wlan set_network 0 bgscan '"'$_wpa_bgscan_parm'"' > /dev/null 2> /dev/null
fi

_wpa_autoscan_parm=$(python3 /opt/cis/bin/getconfval.py WIFI_AUTOSCAN_PARAM | tr -d '\r\n')
if [ ! -z "$_wpa_autoscan_parm" -o "$_wpa_autoscan_parm" == " " -o "$_wpa_autoscan_parm" == "" ]; then
    wpa_cli -p /run/wpa_supplicant -i $_dev_wlan autoscan $_wpa_autoscan_parm > /dev/null 2> /dev/null
fi
