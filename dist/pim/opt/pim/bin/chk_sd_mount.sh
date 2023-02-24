#!/bin/bash
LOG_PATH="/opt/pim/bin/chk_log"
SUCCESS_VAL="/dev/mmcblk1p1"

CHECK_MOUNT_WELL() {
    chk_mnt=$(df)
    if [[ "$chk_mnt" == *"$SUCCESS_VAL"* ]] ; then
        echo "SDCARD mount success"
        exit 0
    else
        echo "SDCARD mount fail"
        touch ${FLAG_PATH}/err_sdcard.log
        exit 1
    fi
}

CHECK_MOUNT_WELL