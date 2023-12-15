#!/bin/bash

TAG=$(basename "$0")
KEY=MNT

mnt_state_=0
mnt_cnt_=0
mnt_folder=$1

while true; do
    case $mnt_state_ in
        0)
             logger -p local0.notice "[$KEY][$TAG:$LINENO] case 0"
            if [ -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                mout_dev=`df | grep '/mnt/sd_cam' | awk '{print $1}'`
                logger -p local0.notice "[$KEY][$TAG:$LINENO] mount_dev : $mount_dev"
                if [ -z $mout_dev ]; then
                    if [ ! -d /mnt ]; then
                        mkdir -p /mnt
                    fi

                    if [ ! -d $mnt_folder ]; then
                        mkdir -p $mnt_foler
                    fi

                    mount /dev/mmcblk1p1 /mnt/sd_cam
                elif [ $mout_dev != "/dev/mmcblk1p1" ]; then
                    umount $mnt_folder
                    mount /dev/mmcblk1p1 $mnt_folder
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] mount /dev/mmcblk1p1 /mnt/sd_cam"
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
                    mnt_state_ = 0
                fi
            fi
        ;;
    esac
    sleep 1
done
