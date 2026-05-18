#!/bin/bash
TAG=$(basename "$0")
KEY=MNT
DEVICE=/dev/mmcblk1p1
DIR=/mnt/sd_cam
mnt_state=0
mnt_cnt=0
mnt_dev=0
fsck_cmd=""

if [ ! -z "$1" ]; then
    DEVICE=$1
fi

logger -p local0.notice "[$KEY][$TAG:$LINENO] filesystem check $DEVICE"
systemctl stop sd-mount.service
systemctl stop cam-operate.service

while :; do
    mnt_dev=$(df | grep $DEVICE | awk '{print $1}')
    if [ -z "$mnt_dev" ]; then
        logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE unmount success!"
        break
    else
        ((mnt_cnt++))
        # 큰 임계부터 검사: > 2 cascade bug 회피
        if (( mnt_cnt > 2 )); then
            logger -p local0.crit "[$KEY][$TAG:$LINENO] cannot unmount $DEVICE"
            exit 1
        elif (( mnt_cnt > 1 )); then
            logger -p local0.err "[$KEY][$TAG:$LINENO] umount -f $DEVICE"
            umount -f $DEVICE
        else
            logger -p local0.err "[$KEY][$TAG:$LINENO] umount $DEVICE"
            umount $DEVICE
        fi
    fi
    sleep 2
done

FSTYPE="$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null)"
if [ -z "$FSTYPE" ]; then
    FSTYPE="$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null)"
fi

logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE fstype : $FSTYPE"
#fsck.vfat -v -y $DEVICE
#fsck.vfat -vaw $DEVICE |tee /var/log/cantops/local0.log
#fsck.vfat -vaw "$DEVICE" 2>&1 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /"  | logger -p local0.error
case "$FSTYPE" in
    vfat|fat|fat32|msdos)
        fsck_cmd='fsck.vfat -vaw "$DEVICE" 2>&1 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /" | logger -p local0.notice'
        mount_cmd="mount -t vfat -o noatime,nodiratime,flush,dirsync,utf8=1,shortname=mixed $DEVICE $DIR"
        ;;
    ext4)
        fsck_cmd='fsck.ext4 -y "$DEVICE" 2>&1 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /" | logger -p local0.notice'
        mount_cmd="mount -t ext4 -o noatime,nodiratime,commit=10,data=ordered,barrier=1,errors=remount-ro $DEVICE $DIR"
        #/opt/pim/bin/ext4_downgrade.sh /dev/mmcblk1p1
        ;;
    exfat)
        fsck_cmd='fsck.exfat -y "$DEVICE" 2>&1 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /" | logger -p local0.notice'
        mount_cmd="mount -t exfat -o noatime,nodiratime $DEVICE $DIR"
        ;;
    *)
        logger -p local0.emerg "[$KEY][$TAG:$LINENO] $DEVICE fstype is undefined : $FSTYPE"
        fsck_cmd='fsck -V "$DEVICE" 2>&1 | sed -u "s/^/[${KEY}][${TAG}:${LINENO}] /" | logger -p local0.notice'
        mount_cmd="mount $DEVICE $DIR"
        ;;
    esac

logger -p local0.notice "[$KEY][$TAG:$LINENO] $fsck_cmd"
eval "$fsck_cmd"

#if [ "$FSTYPE" = "ext4" ]; then
#    /opt/pim/bin/ext4_downgrade.sh /dev/mmcblk1p1
#fi

#mount_cmd="mount $DEVICE $DIR"
logger -p local0.notice "[$KEY][$TAG:$LINENO] $mount_cmd"
eval "$mount_cmd"

sleep 1

mnt_folder=$(df | grep $DEVICE | awk '{print $6}')
#mount |grep -i mount |awk '{print $6}' |grep -i '(rw,'

if [ "$mnt_folder" == "$DIR" ]; then
    if [ ! -z "$(mount |grep -i mount |awk '{print $6}' |grep -i '(rw,')" ]; then
        logger -p local0.notice "[$KEY][$TAG:$LINENO] mount success"
    else
        logger -p local0.err "[$KEY][$TAG:$LINENO] mounted not r/w"
    fi
else
    logger -p local0.err "[$KEY][$TAG:$LINENO] mnt_dev : $mnt_dev != $DEVICE"
fi

umount $DEVICE

while :; do
    mnt_dev=$(df | grep $DEVICE | awk '{print $1}')
    if [ -z "$mnt_dev" ]; then
        logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE unmount success!"
        exit 0
    else
        ((mnt_cnt++))
        # 큰 임계부터 검사: > 2 cascade bug 회피
        if (( mnt_cnt > 2 )); then
            logger -p local0.crit "[$KEY][$TAG:$LINENO] cannot unmount $DEVICE"
            exit 1
        elif (( mnt_cnt > 1 )); then
            logger -p local0.err "[$KEY][$TAG:$LINENO] umount -f $DEVICE"
            umount -f $DEVICE
        else
            logger -p local0.err "[$KEY][$TAG:$LINENO] umount $DEVICE"
            umount $DEVICE
        fi
    fi
    sleep 2
done

