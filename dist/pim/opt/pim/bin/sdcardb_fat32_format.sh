#!/bin/bash
SUCCESS_VAL="/dev/mmcblk0p1"
tag=$(basename "$0")

#SD card check
CHECK_SDCARD() {
	SDCARDB_FIND=$(cat /proc/partitions | grep -o 'mmcblk0p1')
	if [ "$SDCARDB_FIND" != "mmcblk0p1" ]; then
		echo "SDCARD B insert error"
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

#fdisk partition process
MAKE_PARTIOTION() {
    umount /dev/mmcblk0*
    sleep 2
    echo "umount sdcard"
    cat <<EOF | fdisk /dev/mmcblk0    
d
n   
p
1


t
c
w
EOF
    echo "make FAT32 file system "
    mkfs.fat -F 32 -I /dev/mmcblk0p1
    sleep 1
    mount /dev/mmcblk0p1 /mnt_b
    sleep 1
	logger -p local0.notice [SDC][$tag:$LINENO] SD card B fat32 format
}

CHECK_MOUNT_WELL() {
    chk_mnt=$(df)
    if [[ "$chk_mnt" == *"$SUCCESS_VAL"* ]] ; then
        echo "SDCARD B mount success"
        exit 0
    else
        echo "SDCARD B mount fail"
        exit 1
    fi
}

CHECK_SDCARD
KILL_PIM_CAMERA_APP
MAKE_PARTIOTION
CHECK_MOUNT_WELL

