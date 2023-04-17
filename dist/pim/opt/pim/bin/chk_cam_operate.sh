#!/bin/bash

FILE_=/tmp/start_video_time_
FILE_JSON=/root/shared_v/edgeconf_pim.json
FILE_JSON_=/root/shared_v/ord_vcm_conf.json
tag=$(basename "$0")
ENABLE_VAL=true
DISABLE_VAL=false
retry=0
touch $FILE_

while :
do
	startTime=$(cat $FILE_ 2>/dev/null| tr -d '\n')
	check_num=0
	if [ -n "$startTime"  ]; then
		curTimeEpoch=$(date "+%s")
		logger -p local0.info [CHK][$tag:$LINENO] start_video_time_ : $startTime
		logger -p local0.info [CHK][$tag:$LINENO] cur_time : $(date "+%Y%m%d %H:%M:%S")
		#echo $(date "+%Y%m%d %H:%M:%S")

		startTimeEpoch=$(date -d "$startTime" "+%s")
		#echo $curTimeEpoch
		#echo $startTimeEpoch
		diffEpoch=$(echo "$curTimeEpoch - $startTimeEpoch" |bc)
		logger -p local0.info [CHK][$tag:$LINENO] diffEpoch : $diffEpoch
		if [ "$diffEpoch" -ge 5 ]; then
			cat /dev/null > $FILE_
			cam_ch0_en=$(cat $FILE_JSON | grep cam_ch0 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
			cam_ch1_en=$(cat $FILE_JSON | grep cam_ch1 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
			cam_ch2_en=$(cat $FILE_JSON | grep cam_ch2 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
			cam_ch3_en=$(cat $FILE_JSON | grep cam_ch3 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
			mp4date=$(date -d "$startTime" "+%Y%m%d_%H%M%S")
			#ch0_file=$(find /mnt -name *"$mp4date"-ch0.mp4)
			#echo $ch0_file
			#list="cam_ch0_en cam_ch1_en"
			#for ch in $list; do
			#echo $ch
			if [[ "$cam_ch0_en" == *"$ENABLE_VAL"* ]]; then
				if [ -f /mnt/*"$mp4date"-ch0.mp4 ]; then
					logger -p local0.notice [CHK][$tag:$LINENO] *"$mp4date"-ch0.mp4 exist
				else
					logger -p local0.error [CHK][$tag:$LINENO] *"$mp4date"-ch0.mp4 not exist
				fi
				((check_num++))
			fi
			#done
                        if [[ "$cam_ch1_en" == *"$ENABLE_VAL"* ]]; then
                                if [ -f /mnt/*"$mp4date"-ch1.mp4 ]; then
                                        logger -p local0.notice [CHK][$tag:$LINENO] *"$mp4date"-ch1.mp4 exist
                                else
                                        logger -p local0.error [CHK][$tag:$LINENO] *"$mp4date"-ch1.mp4 not exist
                                fi
				((check_num++))
                        fi
                        if [[ "$cam_ch2_en" == *"$ENABLE_VAL"* ]]; then
                                if [ -f /mnt/*"$mp4date"-ch2.mp4 ]; then
                                        logger -p local0.notice [CHK][$tag:$LINENO] *"$mp4date"-ch2.mp4 exist
                                else
                                        logger -p local0.error [CHK][$tag:$LINENO] *"$mp4date"-ch2.mp4 not exist
                                fi
				((check_num++))
                        fi
                        if [[ "$cam_ch3_en" == *"$ENABLE_VAL"* ]]; then
                                if [ -f /mnt/*"$mp4date"-ch3.mp4 ]; then
                                        logger -p local0.notice [CHK][$tag:$LINENO] *"$mp4date"-ch3.mp4 exist
                                else
                                        logger -p local0.error [CHK][$tag:$LINENO] *"$mp4date"-ch3.mp4 not exist
                                fi
				((check_num++))
                        fi
			srt_en=$(cat $FILE_JSON_ | grep srt_enable | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
                        if [[ "$srt_en" == *"$ENABLE_VAL"* ]]; then
                                if [ -f /mnt/*"$mp4date"-data.srt ]; then
                                        logger -p local0.notice [CHK][$tag:$LINENO] *"$mp4date"-data.srt exist
                                else
                                        logger -p local0.error [CHK][$tag:$LINENO] *"$mp4date"-data.srt exist
                                fi
				((check_num++))
                        fi

			#echo $check_num
			#echo $ch0_file
			#echo $mp4date
			filecnt=$(ls -l /mnt/*"$mp4date"* |grep ^- |wc -l)
			#echo $filecnt
			logger -p local0.info [CHK][$tag:$LINENO] mp4date:$mp4date
			logger -p local0.info [CHK][$tag:$LINENO] check_num:$check_num cnt:$filecnt 
			if [ "$check_num" -gt "$filecnt" ]; then
				((retry++))
				#echo "cam file check error and reset($retry)"
				logger -s -p local0.alert [CHK][$tag:$LINENO] $check_num !=$filecnt file cnt check fail retry:$retry
				if [ "$retry" -le 3 ]; then
					/opt/pim/bin/kill_test.sh				
				elif [ "$retry" -le 5 ]; then
					/opt/pim/bin/init_cam.sh
				else
					logger -s -p local0.alert [CHK][$tag:$LINENO] "retry:$retry reboot..."
					reboot
				fi
			else
				logger -s -p local0.alert [CHK][$tag:$LINENO]  mp4,srt file cnt check ok
				retry=0
			fi
		fi
	fi
	sleep 5
done
