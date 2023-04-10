#!/bin/bash
FLAG_PATH="/tmp"
SUCCESS_VAL="/dev/mmcblk1p1"
timestamp=`date +"%Y-%m-%d %T,%3N"`
tag=$(basename "$0")

CHECK_MOUNT_WELL() {
    chk_mnt=$(df)
    if [[ "$chk_mnt" == *"$SUCCESS_VAL"* ]] ; then
        exit 0
    else
        logger -p local0.error -t $tag [CHK] SD MOUNT ERR
		echo "${timestamp} SDCARD MNT ERR" >> ${FLAG_PATH}/err_sdcard.log
        exit 1
    fi
}

CHECK_MOUNT_WELL
