#!/bin/bash
FLAG_PATH="/opt/pim/bin/chk_log"
LOG_PATH="/var/log"
SUCCESS_VAL="/dev/mmcblk1p1"
timestamp=`date +"%Y-%m-%d %T,%3N"`

function LogWrite() {
	timestamp=`date +"%Y-%m-%d %T,%3N"`
	if [ $# -eq 1 ]; then
		echo "${timestamp} $1" >> "${LOG_PATH}/bg_chk.log"
	fi
}


CHECK_MOUNT_WELL() {
    chk_mnt=$(df)
    if [[ "$chk_mnt" == *"$SUCCESS_VAL"* ]] ; then
        exit 0
    else
        LogWrite "SDCARD mount error"
	echo "${timestamp} SDCARD MNT ERR" >> ${FLAG_PATH}/err_sdcard.log
        exit 1
    fi
}

CHECK_MOUNT_WELL
