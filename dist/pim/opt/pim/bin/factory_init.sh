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

#update_edgeconf
/opt/pim/bin/update_edgeconf.sh

log "ord_vcm_conf.json init"
cp /opt/pim/config/ord_vcm_conf.json /root/shared_v/

log "check OLD_USER."
# exclude_users를 제외한 계정 삭제.
is_excluded() {
    local old_user="$1"
    local exclude_users=(
        root
        user
        admin
    )

    for ex in "${exclude_users[@]}"; do
        if [[ "$old_user" == "$ex" ]]; then
            return 0
        fi
    done

    return 1
}

# UID 1000 이상 일반 사용자 검색.
awk -F: '$3 >= 1000 && $3 < 65534 { print $1 }' /etc/passwd | while read -r old_user
do
    if is_excluded "$old_user"; then
        continue
    fi
    log "OLD_USER '$old_user' exists. Deleting..."
    pkill -u "$old_user" 2> /dev/null
    userdel -r "$old_user" 2> /dev/null
    sed -i "/^${old_user}\$/d" /etc/vsftpd.userlist
done

log "passwd init"
# vsd init command ( change /root/shared_v/.passwd and user passwd )
printf "{\"REQ\":\"INIT_PASSWORD\"}" | nc -w 2 -q 1 127.0.0.1 10008 > /dev/null 2>&1
echo user:user | chpasswd
echo admin:admin | chpasswd

log "time_sync init"
/opt/pim/bin/update_time_sync.sh

if [ -d "/root/shared_v/pim_gate" ]; then
    log "pim_gate conf remove"
    rm -rf /root/shared_v/pim_gate 2> /dev/null
fi

if [ -f "/root/shared_v/ctsiotbe.json" ]; then
    log "ctsiotbe conf remove"
    rm /root/shared_v/ctsiotbe.json 2> /dev/null
fi

if [ -d "/root/shared_v/event_module" ]; then
    log "ctsiotbe-event conf remove"
    rm -rf /root/shared_v/event_module 2> /dev/null
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
