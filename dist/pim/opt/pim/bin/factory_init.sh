#!/bin/bash

tag=$(basename "$0")
KEY=FIN

log() {
    echo "[INFO] $*"
    logger -p local0.notice "[$KEY][$tag] $*"
}

log "FACTORY INIT START"
#kill streamApp, PIMCAM, sd card format
/opt/pim/bin/sdcard_ext4_format.sh

log "edgeconf_pim.json init"
rm /root/shared_v/edgeconf_*.json 2> /dev/null
rm /root/shared_v/backup_edgeconf*.json 2> /dev/null
rm /root/shared_v/error_edgeconf_*.json 2> /dev/null
cp /etc/defaultconf.json /root/shared_v/edgeconf_pim.json

log "ord_vcm_conf.json init"
cp /opt/pim/config/ord_vcm_conf.json /root/shared_v/

log ".passwd init"
rm /root/shared_v/.passwd

log "time_sync init"
/opt/pim/bin/update_time_sync.sh

if [ -d "/root/shared_v/pim_gate" ]; then
    log "pim_gate conf remove"
    rm /root/shared_v/pim_gate/*
fi

if [ -f "/root/shared_v/ctsiotbe.json" ]; then
    log "ctsiotbe conf remove"
    rm /root/shared_v/ctsiotbe.json
fi

if [ -d "/root/shared_v/event_module" ]; then
    log "ctsiotbe-event conf remove"
    rm /root/shared_v/event_module/*
fi

#network setting
python3 /opt/cis/bin/init.py power_on
python3 /opt/cis/bin/update_network.py

log "rootfs sizeup"
/opt/pim/bin/auto_fs_sizeup.sh 2 2

log "log init"
rm -rf /var/volatile/log/journal/*
rm -rf /var/log/cantops/*
mkdir -p /var/log/cantops/dot
mkdir -p /var/log/cantops/gst
mkdir -p /var/log/cantops/journald
log "FACTORY INIT FINISH"
