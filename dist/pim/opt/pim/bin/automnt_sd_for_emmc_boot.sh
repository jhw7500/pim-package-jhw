#!/bin/bash

mnt_state_=0
mnt_cnt_=0

while true; do
    case $mnt_state_ in
        0)
            if [ -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                mout_dev=`df | grep '/mnt' | awk '{print $1}'`
                if [ -z $mout_dev ]; then
                    if [ ! -d /mnt ]; then
                        mkdir -p /mnt
                    fi
                    mount /dev/mmcblk1p1 /mnt
                elif [ $mout_dev != "/dev/mmcblk1p1" ]; then
                    umount /mnt
                    mount /dev/mmcblk1p1 /mnt
                fi
                mnt_state_=1
                mnt_cnt_=0
            fi
        ;;
        1)
            if [ ! -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
                mnt_cnt_=`expr $mnt_cnt_ + 1`
                if [ $mnt_cnt_ -ge 4 ]; then
                    umount /mnt
                    mnt_state_=0
                fi
            else
                mnt_cnt_=0
            fi
        ;;
    esac
    sleep 0.5
done
