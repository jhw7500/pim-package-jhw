#!/bin/bash

FILE_=/tmp/start_video_time_
#FILE_JSON=/root/shared_v/edgeconf_pim.json
FILE_JSON_=/root/shared_v/ord_vcm_conf.json
tag=$(basename "$0")
ENABLE_VAL=true
DISABLE_VAL=false
retry=0
#touch $FILE_
KEY=RST
logger -p local0.notice "[$KEY][$tag:$LINENO] cam-operate daemon start"
JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
rec_time=$(cat $FILE_JSON | grep recording_time | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
rec_time=$((rec_time*60))
rst_time=$((rec_time+90))
#rst_time=40
#rec_time=$((rec_time+90))
#echo rec_time:$rec_time
#rec_time=$((rec_time+10))
timer=0
cam_ch0_en=$(cat $FILE_JSON | grep cam_ch0 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
cam_ch1_en=$(cat $FILE_JSON | grep cam_ch1 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
cam_ch2_en=$(cat $FILE_JSON | grep cam_ch2 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
cam_ch3_en=$(cat $FILE_JSON | grep cam_ch3 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
srt_en=$(cat $FILE_JSON_ | grep srt_enable | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
time_rec_en=$(cat $FILE_JSON_ |grep file_time_recording | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')
vhl_name=$(cat $FILE_JSON | grep vhl_name | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n' | tr -d ' ' )
logger -p local0.notice "[$KEY][$tag:$LINENO] ch0:$cam_ch0_en, ch1:$cam_ch1_en, ch2:$cam_ch2_en, ch3:$cam_ch3_en, srt:$srt_en, time_rec_en:$time_rec_en"
logger -p local0.notice "[$KEY][$tag:$LINENO] vhl_name:$vhl_name, rec_time:$rec_time, rst_time:$rst_time"
mnt_folder="/mnt/sd_cam"

while :
do
    check_num=0
    file_cnt=0
    #file_time_err=0
    if [[ "$time_rec_en" != *"$ENABLE_VAL"* ]]; then
        sleep 30
        continue
    fi

    if [ -f /tmp/kill_flag ]; then
        logger -p local0.notice "[$KEY][$tag:$LINENO] kill_flag set"
        rm /tmp/kill_flag
        cat /dev/null > $FILE_
        timer=0
    fi

    #if [ -e "$FILE_" ]; then
    startTime=$(cat $FILE_ 2>/dev/null| tr -d '\n')

	if [ -n "$startTime"  ]; then
        #timer=0
		curTimeEpoch=$(date "+%s")
		startTimeEpoch=$(date -d "$startTime" "+%s")
		diffEpoch=$(echo "$curTimeEpoch - $startTimeEpoch" |bc)
        logger -p local0.info "[$KEY][$tag:$LINENO] start_video_time_:$startTime, cur_time:$(date '+%Y%m%d %H:%M:%S'), diff:$diffEpoch"
		if [ "$diffEpoch" -ge 5 ]; then
            timer=0
			cat /dev/null > $FILE_
            #logger -p local0.info "[$KEY][$tag:$LINENO] startTime : $startTime"
			mp4date=$(date -d "$startTime" "+%Y%m%d_%H%M%S")
            mp4date2=$(date -d "$startTime" "+%Y%m%d_%H%M")
            #mp4date=$(echo $startTime)
            logger -p local0.info "[$KEY][$tag:$LINENO] check_date : $mp4date"
:<<'END'
            logger -p local0.info "[$KEY][$tag:$LINENO] startTimeEpoch : $startTimeEpoch"
            startTimeEpoch=$((startTimeEpoch+rec_time))
            logger -p local0.info "[$KEY][$tag:$LINENO] next startTimeEpoch : $startTimeEpoch"
            startTime=$(date -d @$startTimeEpoch +"%Y%m%d %H:%M:%S")
            echo "$startTime" > $FILE_
            logger -p local0.info "[$KEY][$tag:$LINENO] next startTime : $startTime"
END
			if [[ "$cam_ch0_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${mnt_folder}/${vhl_name}_${mp4date}"-ch0.mp4 ]; then
			        logger -p local0.info "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date}-ch0.mp4 exist"
                    ((file_cnt++))
                elif [ -f "${mnt_folder}/${vhl_name}_${mp4date2}"*-ch0.mp4 ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date2}*-ch0.mp4 exist"
                    ((file_cnt++))
	    		else
		    		logger -p local0.error "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date}-ch0.mp4 not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
:<<'END'
                    test=$(echo ${vhl_name}_${ch_time:0:8}_${ch_time:9:2}${ch_time:12:2}${ch_time:15:2}-ch0.mp4)
                    logger -p local0.notice "[$KEY][$tag:$LINENO] rename:$test"
                    if [[ "$mp4date" == "$ch_time" ]]; then
                        echo ok > /dev/null
                    else
                        logger -p local0.error "[$KEY][$tag:$LINENO] ch0 time error ( ch0.mp4 : $ch_time )"
                    fi
END
			fi


            if [[ "$cam_ch1_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${mnt_folder}/${vhl_name}_${mp4date}"-ch1.mp4 ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date}-ch1.mp4 exist"
                    ((file_cnt++))
                elif [ -f "${mnt_folder}/${vhl_name}_${mp4date2}"*-ch1.mp4 ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date2}*-ch1.mp4 exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date}-ch1.mp4 not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

            if [[ "$cam_ch2_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${mnt_folder}/${vhl_name}_${mp4date}"-ch2.mp4 ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date}-ch2.mp4 exist"
                    ((file_cnt++))
                elif [ -f "${mnt_folder}/${vhl_name}_${mp4date2}"*-ch2.mp4 ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date2}*-ch2.mp4 exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date}-ch2.mp4 not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

            if [[ "$cam_ch3_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${mnt_folder}/${vhl_name}_${mp4date}"-ch3.mp4 ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date}-ch3.mp4 exist"
                    ((file_cnt++))
                elif [ -f "${mnt_folder}/${vhl_name}_${mp4date2}"*-ch3.mp4 ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date2}*-ch3.mp4 exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date}-ch3.mp4 not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

            if [[ "$srt_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${mnt_folder}/${vhl_name}_${mp4date}"-data.srt ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date}-data.srt exist"
                    ((file_cnt++))
                elif [ -f "${mnt_folder}/${vhl_name}_${mp4date2}"*-data.srt ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date2}*-data.srt exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${vhl_name}_${mp4date}-data.srt not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

			#logger -p local0.debug [$KEY][$tag:$LINENO] mp4date:$mp4date
			logger -p local0.info "[$KEY][$tag:$LINENO] check_num:$check_num cnt:$file_cnt"
			if [ "$check_num" -ne "$file_cnt" ]; then
				((retry++))
				logger -p local0.error "[$KEY][$tag:$LINENO] $check_num != $file_cnt file cnt check fail"
				if [ "$retry" -le 1 ]; then
                    logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/kill_test.sh (retry:$retry)"
					/opt/pim/bin/kill_test.sh
				elif [ "$retry" -le 4 ]; then
                    logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/init_cam.sh (retry:$retry)"
					/opt/pim/bin/init_cam.sh
				else
                    logger -p local0.error "[$KEY][$tag:$LINENO] retry:$retry over"
					logger -p local0.emerg "[$KEY][$tag:$LINENO] Rebooting...(retry:$retry)"
                    sleep 1
					creboot
                    logger -p local0.emerg "[$KEY][$tag:$LINENO] creboot end"
				fi
			else
				logger -p local0.notice "[$KEY][$tag:$LINENO] mp4,srt file cnt check ok (retry:$retry)"
				retry=0
			fi
:<<'END'
            if [ "$file_time_err" -ne 0 ]; then
                logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/kill_test.sh (file_time_err:$file_time_err)"
                /opt/pim/bin/kill_test.sh
            fi
END
		fi
    fi

    if [ "$timer" -gt "$rst_time" ]; then 
        logger -p local0.error "[$KEY][$tag:$LINENO] streamApp all file not create"
        logger -p local0.emerg "[$KEY][$tag:$LINENO] Rebooting...($retry)"
        sleep 1
        creboot
        logger -p local0.emerg "[$KEY][$tag:$LINENO] creboot end"
        timer=0
	fi

	sleep 1
    ((timer++))
done

