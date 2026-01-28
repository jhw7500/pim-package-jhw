#!/bin/bash
tag=$(basename "$0")
KEY=RST

GetConfig_() {
    IFS=$'\t' read -r \
        srt_en file_chk_reboot time_rec_en file_check_delay < <(
        jq -r '[
            (.VCM.srt_enable // false),
            (.ETC.file_check_reboot // false),
            (.VCM.file_time_check // false),
            (.ETC.file_check_delay // 10)
        ] | @tsv' "$FILE_JSON_"
    )
    unset IFS

    #read  srt_en file_chk_reboot time_rec_en file_check_delay < <(jq -r '[.VCM.srt_enable, .ETC.file_check_reboot, .VCM.file_time_check, .ETC.file_check_delay] | @tsv' $FILE_JSON_)
}

GetConfig() {
    IFS=$'\t' read -r \
        app vhl_name rec_min cap_en cap_record_en cap_rtsp_en \
        tmp_path sd_tmp_path final_path muxer cam_ch0 cam_ch1 cam_ch2 cam_ch3 < <(
        jq -r '[
            (.VHL_CAM.app // "streamApp"),
            (.VHL_CAM.vhl_name // "VD3001"),
            (.VHL_CAM.recording_time // 1),
            (.VHL_CAM.capture.enable // false),
            (.VHL_CAM.capture.record // false),
            (.VHL_CAM.capture.rtsp   // false),
            (.VHL_CAM.tmp_path // "/mnt/sd_cam/tmp"),
            (.VHL_CAM.sd_tmp_path // .VHL_CAM.tmp_path // "/mnt/sd_cam/tmp"),
            (.VHL_CAM.final_path // "/mnt/sd_cam"),
            (.VHL_CAM.muxer // "mp4"),
            (.VHL_CAM.i2c2.ch0.enable // false),
            (.VHL_CAM.i2c2.ch1.enable // false),
            (.VHL_CAM.i2c1.ch2.enable // false),
            (.VHL_CAM.i2c1.ch3.enable // false)
        ] | @tsv' "$FILE_JSON"
    )
    unset IFS

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
        app_delay=22
    else
        rst_time=25
        app_delay=11
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

# .part 파일을 2단계로 이동하는 함수 (경로 동일 케이스 대응)
MovePartFile() {
    local part_file="$1"
    local filename=$(basename "$part_file")
    local final_name="${filename%.part}"  # .part 제거
    local src_file="$part_file"

    if [ ! -f "$part_file" ]; then
        logger -p local0.warning "[$KEY][$tag:$LINENO] part file not found: $part_file"
        return 1
    fi

    logger -p local0.info "[$KEY][$tag:$LINENO] processing: $filename"

    # Stage 1: tmp_path → sd_tmp_path (경로가 다를 때만 실행)
    if [ "$tmp_path" != "$sd_tmp_path" ]; then
        # cross-filesystem copy
        if ! cp "$part_file" "${sd_tmp_path}/${filename}"; then
            logger -p local0.error "[$KEY][$tag:$LINENO] Stage1 cp failed: $filename"
            return 1
        fi

        # 파일 flush
        sync -f "${sd_tmp_path}/${filename}" 2>/dev/null || sync

        # 디렉토리 flush
        sync -f "$sd_tmp_path" 2>/dev/null || sync

        # 원본 삭제 (RAM)
        rm -f "$part_file"

        logger -p local0.info "[$KEY][$tag:$LINENO] Stage1: $filename → sd_tmp"

        # Stage 2의 소스는 sd_tmp_path
        src_file="${sd_tmp_path}/${filename}"
    fi

    # Stage 2: sd_tmp_path → final_path (.part 제거)
    if ! mv "$src_file" "${final_path}/${final_name}"; then
        logger -p local0.error "[$KEY][$tag:$LINENO] Stage2 mv failed: $filename"
        return 1
    fi

    logger -p local0.notice "[$KEY][$tag:$LINENO] Complete: $final_name"
    return 0
}

# 완료된 세션의 모든 .part 파일 처리
ProcessCompletedSessions() {
    local done_file
    local timestamp
    local success_count=0
    local fail_count=0

    for done_file in /tmp/session_*.all_done; do
        [ -f "$done_file" ] || continue

        # 타임스탬프 추출 (session_20260127_1430.all_done -> 20260127_1430)
        timestamp=$(basename "$done_file" | sed 's/session_\(.*\)\.all_done/\1/')

        logger -p local0.notice "[$KEY][$tag:$LINENO] processing session: $timestamp"

        # 해당 타임스탬프의 모든 .part 파일 처리
        for part_file in "${tmp_path}"/*"${timestamp}"*.part; do
            [ -f "$part_file" ] || continue

            if MovePartFile "$part_file"; then
                ((success_count++))
            else
                ((fail_count++))
            fi
        done

        # final_path 디렉토리 flush (한 번만)
        sync -f "$final_path" 2>/dev/null || sync

        # 완료 마커 제거
        rm -f "$done_file"

        if [ $fail_count -eq 0 ]; then
            logger -p local0.notice "[$KEY][$tag:$LINENO] session $timestamp completed: $success_count files"
        else
            logger -p local0.error "[$KEY][$tag:$LINENO] session $timestamp: $success_count ok, $fail_count failed"
        fi

        # 카운터 초기화
        success_count=0
        fail_count=0
    done
}

# Stale .part 파일 정리 (10분 이상 방치된 파일)
CleanupStalePartFiles() {
    local stale_timeout=600  # 10분 (초)
    local current_time=$(date +%s)
    local file_mtime
    local age
    local removed_count=0

    # tmp_path 정리
    if [ -d "$tmp_path" ]; then
        for part_file in "${tmp_path}"/*.part; do
            [ -f "$part_file" ] || continue

            file_mtime=$(stat -c %Y "$part_file" 2>/dev/null)
            [ -z "$file_mtime" ] && continue

            age=$((current_time - file_mtime))

            if [ $age -gt $stale_timeout ]; then
                logger -p local0.warning "[$KEY][$tag:$LINENO] removing stale tmp: $(basename $part_file) (age=${age}s)"
                rm -f "$part_file"
                ((removed_count++))
            fi
        done
    fi

    # sd_tmp_path 정리 (tmp_path와 다를 때만)
    if [ "$tmp_path" != "$sd_tmp_path" ] && [ -d "$sd_tmp_path" ]; then
        for part_file in "${sd_tmp_path}"/*.part; do
            [ -f "$part_file" ] || continue

            file_mtime=$(stat -c %Y "$part_file" 2>/dev/null)
            [ -z "$file_mtime" ] && continue

            age=$((current_time - file_mtime))

            if [ $age -gt $stale_timeout ]; then
                # Stage1 완료 후 Stage2 실패한 경우 - 복구 시도
                logger -p local0.warning "[$KEY][$tag:$LINENO] recovering stale sd_tmp: $(basename $part_file) (age=${age}s)"
                if MovePartFile "$part_file"; then
                    logger -p local0.notice "[$KEY][$tag:$LINENO] recovered: $(basename $part_file)"
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] recovery failed, removing: $(basename $part_file)"
                    rm -f "$part_file"
                fi
                ((removed_count++))
            fi
        done
    fi

    if [ $removed_count -gt 0 ]; then
        logger -p local0.notice "[$KEY][$tag:$LINENO] processed $removed_count stale .part files"
    fi
}

# Disk 사용량 체크
CheckDiskSpace() {
    if [ ! -d "$final_path" ]; then
        return
    fi

    local usage=$(df "$final_path" | awk 'NR==2 {print $5}' | tr -d '%')

    if [ "$usage" -ge 95 ]; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] CRITICAL: disk usage ${usage}% >= 95%"
        # 가장 오래된 파일 삭제 (file_manager.sh와 중복될 수 있음)
        return 1
    elif [ "$usage" -ge 90 ]; then
        logger -p local0.error "[$KEY][$tag:$LINENO] WARNING: disk usage ${usage}% >= 90%"
        return 1
    fi

    return 0
}

logger -p local0.emerg "[$KEY][$tag:$LINENO] cam-operate daemon start : Booting"
#/opt/pim/bin/automnt_sd_for_emmc_boot.sh /mnt/sd_cam &
modprobe rtc_ds1307
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
csi1_en=0
csi2_en=0
timestamp=0

GetConfig

if [ -f /dev/shm/sd_mount_flag ] && grep -qE '^(1|2)$' /dev/shm/sd_mount_flag; then
    logger -p local0.info "[$KEY][$tag:$LINENO] sd flag is 1 or 2"
else
    logger -p local0.err "[$KEY][$tag:$LINENO] invalid sd flag or not exist"
    if [ "$tmp_path" != "/dev/shm" ]; then
        jq '.VHL_CAM.tmp_path = "/dev/shm"' "$FILE_JSON" > tmp.$$ && mv tmp.$$ "$FILE_JSON"
        logger -p local0.notice "[$KEY][$tag:$LINENO] fallback tmp_path : $tmp_path -> /dev/shm"
        tmp_path="/dev/shm"
    fi
fi

if [ ! -d "$tmp_path" ]; then
    mkdir -p "$tmp_path"
fi

if [ ! -d "$sd_tmp_path" ]; then
    mkdir -p "$sd_tmp_path"
fi

if [ ! -d "$final_path" ]; then
    mkdir -p "$final_path"
fi

logger -p local0.info "[$KEY][$tag:$LINENO] /opt/pim/bin/start_cam.sh $app_delay"
/opt/pim/bin/start_cam.sh $app_delay
#rst_time=60
#StartApp start_cam.sh
#StartScript restart_app.sh

GetConfig_

logger -p local0.notice "[$KEY][$tag:$LINENO] ch0:$cam_ch0, ch1:$cam_ch1, ch2:$cam_ch2, ch3:$cam_ch3, srt:$srt_en, time_rec_en:$time_rec_en, vhl_name:$vhl_name, rec_time:$rec_time, rst_time:$rst_time, cap_en:$cap_en, mnt_path:$mnt_path, tmp_path:$tmp_path, sd_tmp_path:$sd_tmp_path, final_path:$final_path, app_delay:$app_delay, muxer:$muxer, file_check_delay:$file_check_delay file_chk_reboot:$file_chk_reboot"

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

    if [[ "$csi1_en" -eq 0 ]] && [[ "$csi2_en" -eq 0 ]]; then
        sleep 5
        continue
    fi

    # === 이벤트 기반: 완료된 세션 처리 ===
    ProcessCompletedSessions

    #if [ -e "$FILE_" ]; then
    startTime=$(cat $FILE_ 2>/dev/null| tr -d '\n' 2>/dev/null)
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
                elif compgen -G "${tmp_path}/*${vhl_name}_${datetime_}*ch0*" > /dev/null; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch0* exist"
                    ((file_cnt++))
	    		else
		    		logger -p local0.error "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch0* not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
			fi


            if [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch1.${muxer}" ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-ch1.${muxer} exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/*${vhl_name}_${datetime_}*ch1*" > /dev/null; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch1* exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch1* not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

            if [[ "$cam_ch2" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch2.${muxer}" ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-ch2.${muxer} exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/*${vhl_name}_${datetime_}*ch2*" > /dev/null; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch2* exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch2* not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

            if [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch3.${muxer}" ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-ch3.${muxer} exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/*${vhl_name}_${datetime_}*ch3*" > /dev/null; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch3* exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*ch3* not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

            if [[ "$srt_en" == *"$ENABLE_VAL"* ]]; then
                ((check_num++))
                if [ -f "${tmp_path}/${vhl_name}_${datetime}-data.srt" ]; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/${vhl_name}_${datetime}-data.srt exist"
                    ((file_cnt++))
                elif compgen -G "${tmp_path}/*${vhl_name}_${datetime_}*data*" > /dev/null; then
                    logger -p local0.info "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*data* exist"
                    ((file_cnt++))
                else
                    logger -p local0.error "[$KEY][$tag:$LINENO] ${tmp_path}/*${vhl_name}_${datetime_}*data* not exist"
                    #((file_cnt--))
                    #((file_time_err++))
                fi
            fi

            # === 기존 1분 이동 로직: .part 기반 로직으로 대체됨 ===
            # if [ "$mnt_path" != "$tmp_path" ]; then
            #     if [ -f /dev/shm/sd_mount_flag ] && grep -qE '^(1|2)$' /dev/shm/sd_mount_flag; then
            #         timestamp=$(date -d '1 min ago' '+%Y%m%d_%H%M')
            #         cmd="mv ${tmp_path}/*${vhl_name}_${timestamp}* ${mnt_path}/ 2>/dev/null"
            #         logger -p local0.notice "[$KEY][$tag:$LINENO] $cmd"
            #         eval "$cmd"
            #         if [ "$rec_min" -gt 1 ]; then
            #             timestamp=$(date -d "${rec_min} min ago" '+%Y%m%d_%H%M')
            #             cmd="mv ${tmp_path}/*${vhl_name}_${timestamp}* ${mnt_path}/ 2>/dev/null"
            #             logger -p local0.notice "[$KEY][$tag:$LINENO] $cmd"
            #             eval "$cmd"
            #         fi
            #     else
            #         logger -p local0.err "[$KEY][$tag:$LINENO] sd mount err...dont move ${tmp_path} to ${mnt_path}"
            #     fi
            # fi
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

    # === 주기적 정리 작업 (30초마다) ===
    if [ $((timer % 30)) -eq 0 ]; then
        CleanupStalePartFiles
        CheckDiskSpace
    fi

	sleep 2
    ((timer+=2))
    #GetConfig
    #logger -p local0.notice "[$KEY][$tag:$LINENO] timer:$timer"
done

logger -p local0.notice "[$KEY][$tag:$LINENO] cam-operate stop"
