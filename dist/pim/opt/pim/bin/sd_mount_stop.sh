#!/bin/bash
TAG=$(basename "$0")
KEY=MNT
DEVICE="/dev/mmcblk1p1"
logger -p local0.notice "[$KEY][$TAG:$LINENO] systemctl stop cam-operate"
systemctl stop cam-operate
sleep 1
logger -p local0.notice "[$KEY][$TAG:$LINENO] umount $DEVICE"
umount $DEVICE
sleep 1
for i in {1..3}; do
    mnt_dev=$(df | grep $DEVICE | awk '{print $1}')
    if [ -z "$mnt_dev" ]; then
        logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE is not mounted"
    else
        logger -p local0.err "[$KEY][$TAG:$LINENO] umount -f /dev/mmcblk1p1"
        umount -f /dev/mmcblk1p1
    fi
    sleep 3
done

mnt_dev=$(df | grep $DEVICE | awk '{print $1}')
if [ -z "$mnt_dev" ]; then
    logger -p local0.emerg "[$KEY][$TAG:$LINENO] $DEVICE cannot unmounted"
else
    logger -p local0.tnoice "[$KEY][$TAG:$LINENO] $DEVICE is not mounted"
fi

