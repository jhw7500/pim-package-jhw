#!/bin/bash
SUCCESS_VAL="/dev/mmcblk1p1"
tag=$(basename "$0")

#SD card check
CHECK_SDCARD() {
    if [ -d /sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1 ]; then
        echo "sd card check"
    else
        exit 1
    fi
}

#kill pim camera app
KILL_PIM_CAMERA_APP() {
    systemctl stop cam-operate
    pid=`ps -ef | grep 'restart_app' | grep -v 'grep' | awk '{print $2}'`
    if [ -z $pid ]
    then
        echo "already killed restart_app"
    else
        kill $pid
        sleep 1
        echo "kill $pid"
    fi
	/opt/pim/bin/kill_test.sh
}

#umount /mnt/sd_cam
UMOUNT_SDCARD() {
    MOUNT_POINT="/mnt/sd_cam"
    PROCESSES=$(lsof +D "$MOUNT_POINT" | awk 'NR>1 {print $2}' | sort -u)
    if [ -n "$PROCESSES" ]; then
        echo "Terminating processes using $MOUNT_POINT..."
        for PID in $PROCESSES; do
            echo "Killing process $PID"
            kill -9 $PID
        done
    fi
    umount -l "$MOUNT_POINT"
    if [ $? -eq 0 ]; then
        echo "Successfully unmounted $MOUNT_POINT"
    else
        echo "Failed to unmount $MOUNT_POINT"
    fi
}

#fdisk partition process
MAKE_PARTIOTION() {
    umount /dev/mmcblk1*
    sleep 2
    echo "umount sdcard"
    cat <<EOF | fdisk /dev/mmcblk1    
d
n   
p
1


t
c
w
EOF
    echo "make FAT32 file system "
    mkfs.fat -F 32 -I /dev/mmcblk1p1
    sleep 1
    mount /dev/mmcblk1p1 /mnt/sd_cam
    sleep 1
	logger -p local0.notice [SDC][$tag:$LINENO] SD card fat32 format
}

CHECK_MOUNT_WELL() {
    chk_mnt=$(df)
    if [[ "$chk_mnt" == *"$SUCCESS_VAL"* ]] ; then
        echo "SDCARD mount success"
        exit 0
    else
        echo "SDCARD mount fail"
        exit 1
    fi
}

CHECK_SDCARD
KILL_PIM_CAMERA_APP
UMOUNT_SDCARD
MAKE_PARTIOTION
CHECK_MOUNT_WELL

