#!/bin/bash
FLAG_PATH="/tmp"
SUCCESS_VAL="/dev/mmcblk1p1"
timestamp=`date +"%Y-%m-%d %T,%3N"`
tag=$(basename "$0")
folder=/mnt/event
file=sd_write_test

CHECK_MOUNT_WELL() {
    chk_mnt=$(df)
    if [[ "$chk_mnt" == *"$SUCCESS_VAL"* ]] ; then
	if [ ! -d "$folder" ]; then
		mkdir $folder
		if [ $? -ne 0 ]; then
			logger -p local0.error "[CHK][$tag:$LINENO] sd mkdir $folder error"
			echo "${timestamp} SDCARD MNT ERR" >> ${FLAG_PATH}/err_sdcard.log
			exit 1
		fi
	fi
	
	touch $folder/$file > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		#echo "touch ok"
		rm $folder/$file > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			#echo "rm ok"
			logger -p local0.info "[CHK][$tag:$LINENO] sd mount & write ok"
			exit 0
		else
			#echo "rm error"
			echo "${timestamp} SDCARD MNT ERR" >> ${FLAG_PATH}/err_sdcard.log
			exit 1
		fi
	else
		echo "${timestamp} SDCARD MNT ERR" >> ${FLAG_PATH}/err_sdcard.log
		exit 1
	fi
    else
        logger -p local0.error [CHK][$tag:$LINENO] SD MOUNT ERR
	echo "${timestamp} SDCARD MNT ERR" >> ${FLAG_PATH}/err_sdcard.log
        exit 1
    fi
}

CHECK_MOUNT_WELL
