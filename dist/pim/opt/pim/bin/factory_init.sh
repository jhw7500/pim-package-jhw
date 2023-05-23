#!/bin/bash

tag=$(basename "$0")

#kill streamApp, PIMCAM, sd card format 
/opt/pim/bin/sdcard_fat32_format.sh

#edgeconf_pim.json init
cp /opt/pim/config/edgeconf_pim.json /root/shared_v/

#network setting
python3 update_eap_id.py
python3 update_network_pim.py

#log init
rm /var/log/cantops/*.*
logger -p local0.notice [FIN][$tag:$LINENO] FACTORY INIT