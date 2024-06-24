#!/bin/bash

TAG=$(basename "$0")
KEY=MNT

mnt_state_=0
mnt_cnt_=0
mnt_folder=$1
mount_dev=0

LOCKFILE="/tmp/automnt_sd_for_emmc_boot.lock"
exec 200>$LOCKFILE
flock -n 200 || exit 1

while true; do
    case $mnt_state_ in
        0)
             logger -p local0.notice "[$KEY][$TAG:$LINENO] case 0"
            if [ -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                logger -p local0.notice "[$KEY][$TAG:$LINENO] sd card file system check : fsck.vfat -a /dev/mmcblk1p1"
                fsck.vfat -a /dev/mmcblk1p1 2>&1 | while IFS= read -r line; do
                    LINENO=$(echo "$line" | awk '{print NR}')
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] $line"
                done
                mout_dev=`df | grep '/mnt/sd_cam' | awk '{print $1}'`
                logger -p local0.notice "[$KEY][$TAG:$LINENO] mount_dev : $mount_dev"
                if [ -z $mout_dev ]; then
                    if [ ! -d /mnt ]; then
                        mkdir -p /mnt
                    fi

                    logger -p local0.notice "[$KEY][$TAG:$LINENO] mount folder clean : rm -rf /mnt/*"
                    rm -rf /mnt/*

                    if [ ! -d $mnt_folder ]; then
                        logger -p local0.notice "[$KEY][$TAG:$LINENO] mkdir -p $mnt_folder"
                        mkdir -p $mnt_folder
                    fi
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] mount /dev/mmcblk1p1 $mnt_folder"
                    mount /dev/mmcblk1p1 $mnt_folder
                elif [ $mout_dev != "/dev/mmcblk1p1" ]; then
                    umount $mnt_folder
                    mount /dev/mmcblk1p1 $mnt_folder
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] remount /dev/mmcblk1p1 $mnt_folder"
                fi
                mnt_state_=1
                mnt_cnt_=0
            fi
        ;;
        1)
            if [ ! -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                mnt_cnt_=`expr $mnt_cnt_ + 1`
                logger -p local0.error "[$KEY][$TAG:$LINENO] mount_cnt : $mnt_cnt"
                if [ $mnt_cnt_ -ge 4 ]; then
                    logger -p local0.error "[$KEY][$TAG:$LINENO] umount $mnt_folder"
                    umount $mnt_folder
                    mnt_state_=0
                fi
            else
                mnt_cnt_=0
                mout_dev=`df | grep '/mnt/sd_cam' | awk '{print $1}'`
                if [ -z $mout_dev ]; then
                    logger -p local0.error "[$KEY][$TAG:$LINENO] not mounted $mnt_folder"
                    mnt_state_=0
                fi
            fi
        ;;
    esac
    sleep 5
done
