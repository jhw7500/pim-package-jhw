#!/bin/bash
tag=$(basename "$0")
KEY=RST

GetConfig_() {
    read  srt_en file_chk_reboot time_rec_en file_check_delay < <(jq -r '[.VCM.srt_enable, .ETC.file_check_reboot, .VCM.file_time_check, .ETC.file_check_delay] | @tsv' $FILE_JSON_)
}
GetConfig() {
    read app vhl_name rec_min cap_en cap_record_en cap_rtsp_en tmp_path muxer cam_ch0 cam_ch1 cam_ch2 cam_ch3 < <(
    jq -r '[.VHL_CAM.app, .VHL_CAM.vhl_name, .VHL_CAM.recording_time, .VHL_CAM.capture.enable, .VHL_CAM.capture.record, .VHL_CAM.capture.rtsp, .VHL_CAM.tmp_path, .VHL_CAM.muxer, .VHL_CAM.i2c2.ch0.enable, .VHL_CAM.i2c2.ch1.enable, .VHL_CAM.i2c1.ch2.enable, .VHL_CAM.i2c1.ch3.enable] | @tsv' $FILE_JSON)

:<<'END'
    app=$(jq '.VHL_CAM.app' "$FILE_JSON")
    cam_ch0=$(jq '.VHL_CAM.i2c2.ch0.enable' "$FILE_JSON")
    cam_ch1=$(jq '.VHL_CAM.i2c2.ch1.enable' "$FILE_JSON")
    cam_ch2=$(jq '.VHL_CAM.i2c1.ch2.enable' "$FILE_JSON")
    cam_ch3=$(jq '.VHL_CAM.i2c1.ch3.enable' "$FILE_JSON")
    srt_en=$(jq '.VCM.srt_enable' "$FILE_JSON_")
    file_chk_reboot=$(jq '.ETC.file_check_reboot' "$FILE_JSON_")
    time_rec_en=$(jq '.VCM.file_time_check' "$FILE_JSON_")
    file_check_delay=$(jq '.ETC.file_check_delay' "$FILE_JSON_")
    vhl_name=$(jq -r '.VHL_CAM.vhl_name' "$FILE_JSON")
    rec_min=$(jq '.VHL_CAM.recording_time' "$FILE_JSON")
    cap_en=$(jq '.VHL_CAM.capture.enable' "$FILE_JSON")
    cap_record_en=$(jq '.VHL_CAM.capture.record' "$FILE_JSON")
    cap_rtsp_en=$(jq '.VHL_CAM.capture.rtsp' "$FILE_JSON")
    tmp_path=$(jq -r '.VHL_CAM.tmp_path' "$FILE_JSON")
    muxer=$(jq -r '.VHL_CAM.muxer' "$FILE_JSON")
END
    rec_time=$((rec_min*60))
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
        rst_time=35
        app_delay=20
    else
        rst_time=25
        app_delay=10
    fi
}

StartScript() {
pid=$(ps -ef |grep $1 |grep -v grep |awk '{print $2}')
if [ ! -n "$pid" ]; then
    #echo "no" >/dev/null
    logger -p local0.notice "[$KEY][$tag:$LINENO] $service start"
    /opt/pim/bin/$1 &
fi
}

logger -p local0.emerg "[$KEY][$tag:$LINENO] cam-operate daemon start"
#/opt/pim/bin/automnt_sd_for_emmc_boot.sh /mnt/sd_cam &
modprobe max9296
modprobe imx8-media-dev
#/opt/pim/bin/start_cam.sh 20

FILE_="/tmp/start_video_time_chk"
#FILE_JSON=/root/shared_v/edgeconf_pim.json
FILE_JSON_=/root/shared_v/ord_vcm_conf.json
FILE_CHECK=/tmp/file_check
FLAG_PATH=/tmp
ENABLE_VAL="true"
DISABLE_VAL="false"
retry=0
retry_boot=0
retry_total=0
#touch $FILE_

JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
timer=0
mnt_path="/mnt/sd_cam"
tmp_path="/tmp"
start_f=0
curTimeEpoch=0
startTimeEpoch=0
diffEpoch=0
check_num=0
file_cnt=0
datetime=0
datetime_=0
file_check_delay=10
muxer=""
cap_en="false"
cap_record_en="false"
cap_rtsp_en="false"
startTime=""
startTime_=""
rec_time=0
rec_min=0

GetConfig

if [ ! -d "$tmp_path" ]; then
    mkdir -p "$tmp_path"
fi

logger -p local0.notice "[$KEY][$tag:$LINENO] /opt/pim/bin/start_cam.sh $app_delay"
/opt/pim/bin/start_cam.sh $app_delay
#rst_time=60
#StartApp start_cam.sh
#StartScript restart_app.sh

GetConfig_

logger -p local0.notice "[$KEY][$tag:$LINENO] ch0:$cam_ch0, ch1:$cam_ch1, ch2:$cam_ch2, ch3:$cam_ch3, srt:$srt_en, time_rec_en:$time_rec_en, vhl_name:$vhl_name, rec_time:$rec_time, rst_time:$rst_time, cap_en:$cap_en, mnt_path:$mnt_path, tmp_path:$tmp_path, app_delay:$app_delay, muxer:$muxer, file_check_delay:$file_check_delay file_chk_reboot:$file_chk_reboot"

if [ ! -f /dev/shm/sd_mount_flag ]; then
    tmp_path="/dev/shm"
    logger -p local0.err "[$KEY][$tag:$LINENO] sd_mount_flag not exist : tmp_path:${tmp_path}"
fi

while :
do

    check_num=0
    file_cnt=0

    if [ -f /tmp/init_cam_flag ] || [ -f /tmp/restart_flag ]; then
        sleep 5
        timer=0
        continue
    fi

    if [ -f /tmp/kill_flag ]; then
        logger -p local0.notice "[$KEY][$tag:$LINENO] kill_flag set"
        rm /tmp/kill_flag
        cat /dev/null > $FILE_
        timer=0
    fi

    if [[ "$time_rec_en" != *"$ENABLE_VAL"* ]]; then
        sleep 5
        continue
    fi

    if [[ "$cap_en" == *"$ENABLE_VAL"* && "$cap_record_en" != *"$ENABLE_VAL"* ]]; then
        sleep 5
        continue
    fi

    #if [ -e "$FILE_" ]; then
    startTime=$(cat $FILE_ 2>/dev/null| tr -d '\n')
    #startTime=$(cat "$FILE_" 2>/dev/null | tr -d '\n' | sed 's/:[0-9][0-9]$/:00/')
	if [ -n "$startTime"  ]; then
        timer=0
        start_f=1
		curTimeEpoch=$(date "+%s")
		startTimeEpoch=$(date -d "$startTime" "+%s")
		diffEpoch=$(echo "$curTimeEpoch - $startTimeEpoch" |bc)
        #logger -p local0.info "[$KEY][$tag:$LINENO] start_video_time_:$startTime, cur_time:$(date '+%Y%m%d %H:%M:%S'), diff:$diffEpoch"
		if [ "$diffEpoch" -ge "$file_check_delay" ]; then
            logger -p local0.info "[$KEY][$tag:$LINENO] start_video_time_:$startTime, cur_time:$(date '+%Y%m%d %H:%M:%S'), diff:$diffEpoch"
            #timer=0
			cat /dev/null > $FILE_
			datetime=$(date -d "$startTime" "+%Y%m%d_%H%M%S")
            datetime_=$(date -d "$startTime" "+%Y%m%d_%H%M")
			if [[ "$cam_ch0" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch0.${muxer}" ]; then
			        logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-ch0.${muxer} exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/${vhl_name}_${datetime_}"*ch0* > /dev/null; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime_}*ch0* exist"
                    ((file_cnt++))
	    		else
		    		logger -p local0.error "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime_}*ch0* not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
			fi


            if [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch1.${muxer}" ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-ch1.${muxer} exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/${vhl_name}_${datetime_}"*ch1* > /dev/null; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime_}*ch1* exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime_}*ch1* not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

            if [[ "$cam_ch2" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch2.${muxer}" ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-ch2.${muxer} exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/${vhl_name}_${datetime_}"*ch2* > /dev/null; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime_}*ch2* exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime_}*ch2* not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

            if [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch3.${muxer}" ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-ch3.${muxer} exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/${vhl_name}_${datetime_}"*ch3* > /dev/null; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime_}*ch3* exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime_}*ch3* not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

            if [[ "$srt_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-data.srt" ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-data.srt exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/${vhl_name}_${datetime_}"*data* > /dev/null; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime_}*data* exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime_}*data* not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

            if [ "$mnt_path" != "$tmp_path" ]; then
                if [ -f /dev/shm/sd_mount_flag ];  then
                    cmd="mv ${tmp_path}/${vhl_name}_$(date -d '1 min ago' '+%Y%m%d_%H%M')* ${mnt_path}/ 2>/dev/null"
                    logger -p local0.notice "[$KEY][$tag:$LINENO] $cmd"
                    eval "$cmd"
                    if [ "$rec_min" -gt 1 ]; then
                        timestamp=$(date -d "${rec_min} min ago" '+%Y%m%d_%H%M')
                        cmd="mv ${tmp_path}/${vhl_name}_${timestamp}* ${mnt_path}/ 2>/dev/null"
                        logger -p local0.notice "[$KEY][$tag:$LINENO] $cmd"
                        eval "$cmd"
                    fi
                else
                    logger -p local0.err "[$KEY][$tag:$LINENO] no sd mount...don't move ${tmp_path} to ${mnt_path}"
                    timestamp=$(date -d "${rec_min} min ago" '+%Y%m%d_%H%M')
                    cmd="rm ${tmp_path}/${vhl_name}_${timestamp}*"
                    logger -p local0.notice "[$KEY][$tag:$LINENO] $cmd"
                    eval "$cmd"
                fi
            fi
            sync
			logger -p local0.info "[$KEY][$tag:$LINENO] check_num:$check_num cnt:$file_cnt"
			if [ "$check_num" -ne "$file_cnt" ]; then
                logger -p local0.error "[$KEY][$tag:$LINENO] $check_num != $file_cnt file cnt check fail"
                start_f=0
                echo "NG" > $FILE_CHECK
                value=$(cat $FLAG_PATH/bg_chk_flag.bin)
                value=$(( 0x$(printf '%x' "$value") ))
                cam_disconnect_flag=$((value&0xf))
                if (( cam_disconnect_flag == 0x0 )); then
                    ((retry++))
                    retry_total=$(($retry+$retry_boot))
                    if [ "$retry_total" -le 3 ]; then
                        logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/kill_test.sh ($retry/$retry_boot/$retry_total)"
                        /opt/pim/bin/kill_test.sh
                    elif [ "$retry_total" -le 5 ]; then
                        logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/init_cam.sh ($retry/$retry_boot/$retry_total)"
                        /opt/pim/bin/init_cam.sh
                    else
                        logger -p local0.error "[$KEY][$tag:$LINENO] retry total $retry_total is over"
                        if [[ "$file_chk_reboot" == *"$ENABLE_VAL"* ]]; then
                            logger -p local0.emerg "[$KEY][$tag:$LINENO] rebooting because file check fail ($retry/$retry_boot/$retry_total)"
                            sleep 1
                            #creboot
                            reboot
                        else
                            logger -p local0.notice "[$KEY][$tag:$LINENO] retry count reset because file_check_reboot is not true"
                            retry=0
                            retry_boot=0
                            retry_total=0
                        fi
                    fi
                else
                    logger -p local0.err  "[$KEY][$tag:$LINENO] no retry because cam is disconnect($cam_disconnect_flag)"
                fi
			else
				logger -p local0.notice "[$KEY][$tag:$LINENO] ${muxer},srt file cnt check ok ($retry/$retry_boot/$retry_total)"
				retry=0
                retry_boot=0
                retry_total=0
                echo "OK" > $FILE_CHECK
			fi
		fi
    else
        if [ "$timer" -ge $((rec_time+file_check_delay)) ]; then
            logger -p local0.error "[$KEY][$tag:$LINENO start_f init beacause file not create"
            start_f=0
        fi
    fi

    if [ "$start_f" -eq 0 ]; then
        if [ "$timer" -ge "$rst_time" ]; then 
            logger -p local0.error "[$KEY][$tag:$LINENO] $app all file not create($timer >= $rst_time), $FILE_:$startTime"
            timer=0
            start_f=0
            if [ "$csi1_en" -eq 0 ] && [ "$csi2_en" -eq 0 ]; then
                logger -p local0.error "[$KEY][$tag:$LINENO] all channel disabled at $FILE_JSON"
                continue;
            fi

            echo "NG" > $FILE_CHECK
            value=$(cat $FLAG_PATH/bg_chk_flag.bin)
            value=$(( 0x$(printf '%x' "$value") ))
            cam_disconnect_flag=$((value&0xf))
            if (( cam_disconnect_flag == 0x0 )); then
                ((retry_boot++))
                retry_total=$(($retry+$retry_boot))
                #if [ "$retry_boot" -le 1 ]; then
                #    logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/kill_test.sh ($retry/$retry_boot/$retry_total)"
                #    /opt/pim/bin/kill_test.sh
                if [ "$retry_total" -le 3 ]; then
                    logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/kill_test.sh ($retry/$retry_boot/$retry_total)"
                    /opt/pim/bin/kill_test.sh
                elif [ "$retry_total" -le 5 ]; then
                    logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/init_cam.sh ($retry/$retry_boot/$retry_total)"
                    /opt/pim/bin/init_cam.sh
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] retry_total $retry_total is over"
                    if [[ "$file_chk_reboot" == *"$ENABLE_VAL"* ]]; then
                        logger -p local0.emerg "[$KEY][$tag:$LINENO] rebooting because all file not create ($retry/$retry_boot/$retry_total)"
                        sleep 1
                        #creboot
                        reboot
                    else
                        logger -p local0.notice "[$KEY][$tag:$LINENO] retry count reset because file_check_reboot is not true"
                        retry=0
                        retry_boot=0
                        retry_total=0
                    fi
                fi
            else
                logger -p local0.err  "[$KEY][$tag:$LINENO] no retry because cam is disconnect($cam_disconnect_flag)"
            fi
	    fi
    fi

	sleep 2
    ((timer+=2))
    #GetConfig
    #logger -p local0.notice "[$KEY][$tag:$LINENO] timer:$timer"
done

logger -p local0.notice "[$KEY][$tag:$LINENO] cam-operate stop"
