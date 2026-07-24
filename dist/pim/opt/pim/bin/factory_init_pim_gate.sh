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

JSON_FILE="/root/shared_v/edgeconf_pim.json"
TMP_FILE=$(mktemp)
jq '
  .VHL_CAM.event_auto_remove = false |
  .VHL_CAM.event_storage_size = 86 |
  .VHL_CAM.app = "gstApp" |
  .VHL_CAM.capture.enable = false |
  .VHL_CAM.capture.rtsp = true |
  .VHL_CAM.tmp_path = "/dev/shm" |
  .VHL_CAM.muxer = "ts"
' "$JSON_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$JSON_FILE"

log "ord_vcm_conf.json init"
cp /opt/pim/config/ord_vcm_conf.json /root/shared_v/

# JSON_FILE="/root/shared_v/ord_vcm_conf.json"
# TMP_FILE=$(mktemp)
# jq '
#   .VCM.srt_enable = false 
# ' "$JSON_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$JSON_FILE"

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

log "pim_gate conf default"
/opt/pim_gate/bin/pim_gate.sh default_cfg DEFAULT

if [ -f "/root/shared_v/ctsiotbe.json" ]; then
    log "ctsiotbe conf remove"
    rm /root/shared_v/ctsiotbe.json 2> /dev/null
fi

if [ -d "/root/shared_v/event_module" ]; then
    log "ctsiotbe-event conf remove"
    rm -rf /root/shared_v/event_module 2> /dev/null
fi

log "enable pim_gate"
systemctl enable pim-gate 1> /dev/null 2>&1

if [ -f "/etc/cts/gyrozerobase" ]; then
    log "gyrozerobase remove"
    rm /etc/cts/gyrozerobase 2> /dev/null
fi

if [ -f "/etc/modprobe.d/lrdmwl.conf" ]; then
    log "lrdmwl.conf remove"
    rm /etc/modprobe.d/lrdmwl.conf 2> /dev/null
fi

tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
[ -z "$tz" ] && tz="Asia/Seoul"
if [ "$tz" != "Asia/Seoul" ]; then
    log "timezone Asia/Seoul"
    timedatectl set-timezone Asia/Seoul 1> /dev/null 2>&1
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
