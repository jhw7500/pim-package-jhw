#!/bin/bash

tag=$(basename "$0")

logger -p local0.notice [FIN][$tag:$LINENO] FACTORY INIT START
#kill streamApp, PIMCAM, sd card format 
/opt/pim/bin/sdcard_fat32_format.sh

#edgeconf_pim.json init
rm /root/shared_v/edgeconf_*.json
cp /opt/pim/config/edgeconf_pim.json /root/shared_v/

#ord_vcm_conf.json init
cp /opt/pim/config/ord_vcm_conf.json /root/shared_v/

#network setting
python3 /opt/pim/bin/update_eap_id.py
python3 /opt/pim/bin/update_network_pim.py

#log init
rm /var/log/cantops/*.*
logger -p local0.notice [FIN][$tag:$LINENO] FACTORY INIT FINISH
