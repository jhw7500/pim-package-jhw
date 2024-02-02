#!/bin/bash
FILE_=/tmp/start_video_time_
#FILE_JSON=/root/shared_v/edgeconf_pim.json
FILE_JSON_=/root/shared_v/ord_vcm_conf.json
FILE_CHECK=/tmp/file_check
tag=$(basename "$0")
ENABLE_VAL=true
DISABLE_VAL=false
retry=0
retry_boot=0
retry_total=0
#touch $FILE_
KEY=RST
logger -p local0.notice "[$KEY][$tag:$LINENO] cam-operate daemon start"
JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
timer=0
mnt_folder="/mnt/sd_cam"
start_f=0
rst_time=25
csi1_en=0
csi2_en=0
curTimeEpoch=0
startTimeEpoch=0
diffEpoch=0
check_num=0
file_cnt=0
mp4date=0
mp4date2=0
GetConfig() {
    cam_ch0=$(jq '.VHL_CAM.cam_ch0' "$FILE_JSON")
    cam_ch1=$(jq '.VHL_CAM.cam_ch1' "$FILE_JSON")
    cam_ch2=$(jq '.VHL_CAM.cam_ch2' "$FILE_JSON")
    cam_ch3=$(jq '.VHL_CAM.cam_ch3' "$FILE_JSON")
    srt_en=$(jq '.VCM.srt_enable' "$FILE_JSON_")
    time_rec_en=$(jq '.VCM.file_time_recording' "$FILE_JSON_")
    vhl_name=$(jq -r '.VHL_CAM.vhl_name' "$FILE_JSON")
    rec_time=$(jq '.VHL_CAM.recording_time' "$FILE_JSON")
    rec_time=$((rec_time*60))
    #rst_time=$((rec_time+90))
    #rst_time=20
    if [[ "$cam_ch0" == *"$ENABLE_VAL"* ]] || [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
        #logger -p local0.notice "[$key][$tag:$LINENO] csi1 enable"
        csi1_en=1
    fi

    if [[ "$cam_ch2" == *"$ENABLE_VAL"* ]] || [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
        #logger -p local0.notice "[$key][$tag:$LINENO] csi2 enable"
        csi2_en=1
    fi
    
    if [[ "$csi1_en" -eq 1 ]] && [[ "$csi2_en" -eq 1 ]]; then
        rst_time=30
    else
        rst_time=18
    fi
}

GetConfig
logger -p local0.notice "[$KEY][$tag:$LINENO] ch0:$cam_ch0, ch1:$cam_ch1, ch2:$cam_ch2, ch3:$cam_ch3, srt:$srt_en, time_rec_en:$time_rec_en"
logger -p local0.notice "[$KEY][$tag:$LINENO] vhl_name:$vhl_name, rec_time:$rec_time, rst_time:$rst_time"

service=restart_app.sh
pid=$(ps -ef |grep $service |grep -v grep |awk '{print $2}')
if [ ! -n "$pid" ]; then
    #echo "no" >/dev/null
    logger -p local0.notice "[$KEY][$tag:$LINENO] $service start"
    /opt/pim/bin/$service &
fi

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
        start_f=1
		curTimeEpoch=$(date "+%s")
		startTimeEpoch=$(date -d "$startTime" "+%s")
		diffEpoch=$(echo "$curTimeEpoch - $startTimeEpoch" |bc)
        #logger -p local0.info "[$KEY][$tag:$LINENO] start_video_time_:$startTime, cur_time:$(date '+%Y%m%d %H:%M:%S'), diff:$diffEpoch"
		if [ "$diffEpoch" -ge 5 ]; then
            logger -p local0.info "[$KEY][$tag:$LINENO] start_video_time_:$startTime, cur_time:$(date '+%Y%m%d %H:%M:%S'), diff:$diffEpoch"
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
			if [[ "$cam_ch0" == *"$ENABLE_VAL"* ]]; then
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


            if [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
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

            if [[ "$cam_ch2" == *"$ENABLE_VAL"* ]]; then
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

            if [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
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
                start_f=0
				((retry++))
                retry_total=$(($retry+$retry_boot))
				logger -p local0.error "[$KEY][$tag:$LINENO] $check_num != $file_cnt file cnt check fail"
                echo "NG" > $FILE_CHECK
				if [ "$retry_total" -le 1 ]; then
                    logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/kill_test.sh ($retry/$retry_boot/$retry_total)"
                    #rm ${mnt_folder}/${vhl_name}_${mp4date2}*
					/opt/pim/bin/kill_test.sh
				elif [ "$retry_total" -le 3 ]; then
                    logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/init_cam.sh ($retry/$retry_boot/$retry_total)"
                    #rm ${mnt_folder}/${vhl_name}_${mp4date2}*
					/opt/pim/bin/init_cam.sh
				else
                    logger -p local0.error "[$KEY][$tag:$LINENO] retry:$retry over"
					logger -p local0.emerg "[$KEY][$tag:$LINENO] Rebooting...($retry/$retry_boot/$retry_total)"
                    sleep 1
					creboot
				fi
			else
				logger -p local0.notice "[$KEY][$tag:$LINENO] mp4,srt file cnt check ok ($retry/$retry_boot/$retry_total)"
				retry=0
                retry_boot=0
                retry_total=0
                echo "OK" > $FILE_CHECK
			fi
:<<'END'
            if [ "$file_time_err" -ne 0 ]; then
                logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/kill_test.sh (file_time_err:$file_time_err)"
                rm ${mnt_folder}/${vhl_name}_${mp4date2}*
                /opt/pim/bin/kill_test.sh
            fi
END
		fi
    fi

    if [ "$start_f" -eq 0 ]; then
        if [ "$timer" -ge "$rst_time" ]; then 
            logger -p local0.error "[$KEY][$tag:$LINENO] streamApp all file not create"
            ((retry_boot++))
            retry_total=$(($retry+$retry_boot))
            #if [ "$retry_boot" -le 1 ]; then
            #    logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/kill_test.sh ($retry/$retry_boot/$retry_total)"
            #    /opt/pim/bin/kill_test.sh
            if [ "$retry_total" -le 3 ]; then
                logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/init_cam.sh ($retry/$retry_boot/$retry_total)"
                /opt/pim/bin/init_cam.sh
            else
                logger -p local0.emerg "[$KEY][$tag:$LINENO] Rebooting...($retry/$retry_boot/$retry_total)"
                sleep 1
                creboot
                logger -p local0.emerg "[$KEY][$tag:$LINENO] creboot end"
            fi
            start_f=0
            timer=0
	    fi
    fi

	sleep 2
    ((timer+=2))
    #GetConfig
    #logger -p local0.notice "[$KEY][$tag:$LINENO] timer:$timer"
done

logger -p local0.notice "[$KEY][$tag:$LINENO] cam-operate stop"
