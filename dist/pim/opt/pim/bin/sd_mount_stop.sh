#!/bin/bash
TAG=$(basename "$0")
KEY="MNT"
DIR="/mnt/sd_cam"
DEVICE="/dev/mmcblk1p1"
JSON_PREFIX="edgeconf_"
JOSN_SUFFIX=".json"
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
tmp_path=$(jq -r '.VHL_CAM.tmp_path' "$FILE_JSON")
if [ "$tmp_path" == "$DIR" ]; then
    daemon_name=cam-operate
    status=$(systemctl is-active $daemon_name 2>/dev/null)
    if [ "$status" != "active" ]; then
        logger -p local0.notice "[$KEY][$TAG:$LINENO] systemctl stop cam-operate"
        systemctl stop $daemon_name
        sleep 1
    fi
fi

logger -p local0.notice "[$KEY][$TAG:$LINENO] umount $DEVICE"
umount $DEVICE
sleep 1
for i in {1..3}; do
    mnt_dev=$(df | grep $DEVICE | awk '{print $1}')
    if [ -z "$mnt_dev" ]; then
        logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE unmount success!"
        rm /dev/shm/sd_mount_flag
        exit 0
    else
        logger -p local0.err "[$KEY][$TAG:$LINENO] umount -f /dev/mmcblk1p1"
        umount -f /dev/mmcblk1p1
    fi
    sleep 3
done

mnt_dev=$(df | grep $DEVICE | awk '{print $1}')
if [ -z "$mnt_dev" ]; then
    logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE unmount success!"
    rm /dev/shm/sd_mount_flag
    exit 0
else
    logger -p local0.emerg "[$KEY][$TAG:$LINENO] $DEVICE cannot unmounted"
    exit 1
fi


