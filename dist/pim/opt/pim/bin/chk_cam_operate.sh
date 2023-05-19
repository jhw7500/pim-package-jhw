#!/bin/bash

FILE_=/tmp/start_video_time_
FILE_JSON=/root/shared_v/edgeconf_pim.json
FILE_JSON_=/root/shared_v/ord_vcm_conf.json
tag=$(basename "$0")
ENABLE_VAL=true
DISABLE_VAL=false
retry=0
touch $FILE_
KEY=RST
logger -p local0.notice [$KEY][$tag:$LINENO] cam-operate daemon start
rec_time=$(cat $FILE_JSON | grep recording_time | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
rec_time=$((rec_time*60))
rec_time=$((rec_time+90))
#rec_time=$((rec_time+90))
#echo rec_time:$rec_time
logger -p local0.notice [$KEY][$tag:$LINENO] "empty reset time : $rec_time sec"
#rec_time=$((rec_time+10))
timer=0
cam_ch0_en=$(cat $FILE_JSON | grep cam_ch0 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
cam_ch1_en=$(cat $FILE_JSON | grep cam_ch1 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
cam_ch2_en=$(cat $FILE_JSON | grep cam_ch2 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
cam_ch3_en=$(cat $FILE_JSON | grep cam_ch3 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
srt_en=$(cat $FILE_JSON_ | grep srt_enable | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
time_rec_en=$(cat $FILE_JSON_ |grep file_time_recording | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
logger -p local0.notice [$KEY][$tag:$LINENO] ch0_en:$cam_ch0_en ch1_en:$cam_ch1_en ch2_en:$cam_ch2_en ch3_en:$cam_ch3_en srt_en:$srt_en time_rec_en:$time_rec_en
while :
do
    check_num=0
    if [[ "$time_rec_en" != *"$ENABLE_VAL"* ]]; then
        sleep 30
        continue
    fi

    startTime=$(cat $FILE_ 2>/dev/null| tr -d '\n')
	if [ -n "$startTime"  ]; then
        #timer=0
		curTimeEpoch=$(date "+%s")
		logger -p local0.info [$KEY][$tag:$LINENO] start_video_time_ : $startTime
		logger -p local0.info [$KEY][$tag:$LINENO] cur_time : $(date "+%Y%m%d %H:%M:%S")
		#echo $(date "+%Y%m%d %H:%M:%S")

		startTimeEpoch=$(date -d "$startTime" "+%s")
		#echo $curTimeEpoch
		#echo $startTimeEpoch
		diffEpoch=$(echo "$curTimeEpoch - $startTimeEpoch" |bc)
		logger -p local0.info "[$KEY][$tag:$LINENO] diffEpoch : $diffEpoch"
		if [ "$diffEpoch" -ge 5 ]; then
            timer=0
			cat /dev/null > $FILE_
			#cam_ch0_en=$(cat $FILE_JSON | grep cam_ch0 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
			#cam_ch1_en=$(cat $FILE_JSON | grep cam_ch1 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
			#cam_ch2_en=$(cat $FILE_JSON | grep cam_ch2 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
			#cam_ch3_en=$(cat $FILE_JSON | grep cam_ch3 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
			mp4date=$(date -d "$startTime" "+%Y%m%d_%H%M%S")
			#ch0_file=$(find /mnt -name *"$mp4date"-ch0.mp4)
			#echo $ch0_file
			#list="cam_ch0_en cam_ch1_en"
			#for ch in $list; do
			#echo $ch
			if [[ "$cam_ch0_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
				if [ -f /mnt/*"$mp4date"-ch0.mp4 ]; then
					logger -p local0.info [$KEY][$tag:$LINENO] *"$mp4date"-ch0.mp4 exist
				else
					logger -p local0.error [$KEY][$tag:$LINENO] *"$mp4date"-ch0.mp4 not exist
                    if [ -f /tmp/ch0.mp4 ]; then
                        ch_time=$(cat /tmp/ch0.mp4 2>/dev/null| tr -d '\n')
                        logger -p local0.error [$KEY][$tag:$LINENO] ch0_time : $ch_time
                        ((check_num--))
                    fi
				fi
                rm /tmp/ch0.mp4
			fi
			#done
            if [[ "$cam_ch1_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f /mnt/*"$mp4date"-ch1.mp4 ]; then
                    logger -p local0.info [$KEY][$tag:$LINENO] *"$mp4date"-ch1.mp4 exist
                else
                    logger -p local0.error [$KEY][$tag:$LINENO] *"$mp4date"-ch1.mp4 not exist
                    if [ -f /tmp/ch1.mp4 ]; then
                        ch_time=$(cat /tmp/ch1.mp4 2>/dev/null| tr -d '\n')
                        logger -p local0.error [$KEY][$tag:$LINENO] ch1_time : $ch_time
                        ((check_num--))
                    fi
                fi
                rm /tmp/ch1.mp4
            fi
            if [[ "$cam_ch2_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f /mnt/*"$mp4date"-ch2.mp4 ]; then
                    logger -p local0.info [$KEY][$tag:$LINENO] *"$mp4date"-ch2.mp4 exist
                else
                    logger -p local0.error [$KEY][$tag:$LINENO] *"$mp4date"-ch2.mp4 not exist
                    if [ -f /tmp/ch2.mp4 ]; then
                        ch_time=$(cat /tmp/ch2.mp4 2>/dev/null| tr -d '\n')
                        logger -p local0.error [$KEY][$tag:$LINENO] ch2_time : $ch_time
                        ((check_num--))
                    fi
                fi
                rm /tmp/ch2.mp4
            fi
            if [[ "$cam_ch3_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f /mnt/*"$mp4date"-ch3.mp4 ]; then
                    logger -p local0.info [$KEY][$tag:$LINENO] *"$mp4date"-ch3.mp4 exist
                else
                    logger -p local0.error [$KEY][$tag:$LINENO] *"$mp4date"-ch3.mp4 not exist
                    if [ -f /tmp/ch3.mp4 ]; then
                        ch_time=$(cat /tmp/ch3.mp4 2>/dev/null| tr -d '\n')
                        logger -p local0.error [$KEY][$tag:$LINENO] ch3_time : $ch_time
                        ((check_num--))
                    fi
                fi
                rm /tmp/ch3.mp4
            fi
			#srt_en=$(cat $FILE_JSON_ | grep srt_enable | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
            if [[ "$srt_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f /mnt/*"$mp4date"-data.srt ]; then
                    logger -p local0.info [$KEY][$tag:$LINENO] *"$mp4date"-data.srt exist
                else
                    logger -p local0.error [$KEY][$tag:$LINENO] *"$mp4date"-data.srt not exist
                    if [ -f /tmp/date.srt ]; then
                        ch_time=$(cat /tmp/data.srt 2>/dev/null| tr -d '\n')
                        logger -p local0.error [$KEY][$tag:$LINENO] srt_time : $ch_time
                        ((check_num--))
                    fi
                fi
                rm /tmp/data.srt
            fi
			#echo $check_num
			#echo $ch0_file
			#echo $mp4date
			filecnt=$(ls -l /mnt/*"$mp4date"* |grep ^- |wc -l)
			#echo $filecnt
			logger -p local0.debug [$KEY][$tag:$LINENO] mp4date:$mp4date
			logger -p local0.debug [$KEY][$tag:$LINENO] check_num:$check_num cnt:$filecnt 
			if [ "$check_num" -gt "$filecnt" ]; then
				((retry++))
				echo "cam file check error and cam reset ($retry)"
				logger -p local0.error "[$KEY][$tag:$LINENO] $check_num !=$filecnt file cnt check fail ($retry)"
#:<<'END'
				if [ "$retry" -le 4 ]; then
					/opt/pim/bin/kill_test.sh
				elif [ "$retry" -le 5 ]; then
					/opt/pim/bin/init_cam.sh
				else
                    logger -p local0.crit "[$KEY][$tag:$LINENO] retry($retry) over"
					logger -p local0.emerg "[$KEY][$tag:$LINENO] over reboot...($retry)"
                    sleep 1
					creboot
				fi
#END
			else
				logger -p local0.info "[$KEY][$tag:$LINENO] mp4,srt file cnt check ok ($retry)"
				retry=0
			fi
		fi
    fi

    if [ "$timer" -gt "$rec_time" ]; then 
        logger -p local0.crit "[$KEY][$tag:$LINENO] streamApp all file not create"
        logger -p local0.emerg "[$KEY][$tag:$LINENO] empty reboot...($retry)"
        sleep 1
        creboot
	fi

	sleep 5
    timer=$((timer+5))
done

