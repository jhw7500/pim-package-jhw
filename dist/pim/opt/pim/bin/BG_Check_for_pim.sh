#!/bin/bash
source /opt/pim/lib/cam_state.sh

FLAG_PATH="/tmp"
tag=$(basename "$0")
result=0
delay=25
i=0
# bg_cam_err_streak는 cam_state/streak로 통합됨
JSON_PREFIX=edgeconf_
JSON_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
#cam_ch0=$(jq '.VHL_CAM.i2c2.ch0.enable' "$FILE_JSON")
#cam_ch1=$(jq '.VHL_CAM.i2c2.ch1.enable' "$FILE_JSON")
#cam_ch2=$(jq '.VHL_CAM.i2c1.ch2.enable' "$FILE_JSON")
#cam_ch3=$(jq '.VHL_CAM.i2c1.ch3.enable' "$FILE_JSON")
IFS=$'\t' read -r \
    cam_ch0 cam_ch1 cam_ch2 cam_ch3 vhl_name tmp_path muxer < <(
    jq -r '[
        (.VHL_CAM.i2c2.ch0.enable // false),
        (.VHL_CAM.i2c2.ch1.enable // false),
        (.VHL_CAM.i2c1.ch2.enable // false),
        (.VHL_CAM.i2c1.ch3.enable // false),
        (.VHL_CAM.vhl_name // "VD3001"),
        (.VHL_CAM.tmp_path // "/dev/shm"),
        (.VHL_CAM.muxer // "mp4")
    ] | @tsv' "$FILE_JSON"
)
unset IFS

if [[ $cam_ch0 == "true" ]]; then
    cam_ch0=1
else
    cam_ch0=0
fi
if [[ $cam_ch1 == "true" ]]; then
    cam_ch1=1
else
    cam_ch1=0
fi
if [[ $cam_ch2 == "true" ]]; then
    cam_ch2=1
else
    cam_ch2=0
fi
if [[ $cam_ch3 == "true" ]]; then
    cam_ch3=1
else
    cam_ch3=0
fi
cam_ch_bit=$((cam_ch3<<3|cam_ch2<<2|cam_ch1<<1|cam_ch0))

ORD_VCM_JSON="/root/shared_v/ord_vcm_conf.json"
if [ ! -f "$ORD_VCM_JSON" ]; then
    ORD_VCM_JSON="/tmp/shared_v/ord_vcm_conf.json"
fi

startup_grace_extra_sec=$(jq -r '(.ETC.startup_grace_extra_sec // 10)' "$ORD_VCM_JSON" 2>/dev/null || echo 10)
# 기본값 40은 패키지 배포 설정(opt/pim/config/ord_vcm_conf.json)·update_ordvcmconf.sh·
# chk_cam_operate.sh 와 일치시킨 값이다. 어긋나면 설정 키가 없는 장비에서 두 스크립트가
# 서로 다른 쿨다운으로 동작한다.
init_cooldown_sec=$(jq -r '(.ETC.init_cooldown_sec // 40)' "$ORD_VCM_JSON" 2>/dev/null || echo 40)
now_ts() { date +%s; }
read_ts() { [ -f "$1" ] && cat "$1" 2>/dev/null | tr -d '\n' || echo 0; }

in_startup_grace() {
    local start_ts start_delay now grace
    now=$(now_ts)
    start_ts=$(read_ts "/tmp/cam_state/last_start_ts")
    start_delay=$(read_ts "/tmp/pim_cam_start_delay")
    grace=$((start_delay + startup_grace_extra_sec))
    [ "$start_ts" -gt 0 ] && [ $((now - start_ts)) -lt "$grace" ]
}

in_init_cooldown() {
    local now last
    now=$(now_ts)
    last=$(read_ts "/tmp/last_init_cam_ts")
    [ "$last" -gt 0 ] && [ $((now - last)) -lt "$init_cooldown_sec" ]
}

SYSFS_LINK_I2C2="/sys/bus/i2c/devices/2-0048/link_status"
SYSFS_LINK_I2C1="/sys/bus/i2c/devices/1-0048/link_status"

# 비트마스크를 "ch0 ch1" 형태로 나열한다 (restart_app.sh 의 dc_chs 표기와 동일).
mask_to_chs() {
    local ch out=""
    for ch in 0 1 2 3; do
        [ $(( ($1 >> ch) & 1 )) -eq 1 ] && out="${out}ch${ch} "
    done
    printf '%s' "${out% }"
}

# 에러 플래그 파일이 있는 채널을 "ch0 ch1" 형태로 나열한다.
err_cam_chs() {
    local ch out=""
    for ch in 0 1 2 3; do
        [ -f "${FLAG_PATH}/err_cam${ch}.log" ] && out="${out}ch${ch} "
    done
    printf '%s' "${out% }"
}

# check_driver_disconnect() 의 부가 출력. 함수는 리턴값으로 유무만 알려주므로
# 어느 채널인지는 전역으로 넘긴다(command substitution 을 쓰면 서브셸이라 안 된다).
drv_disconnect_mask=0
drv_mask_i2c2=0
drv_mask_i2c1=0

# disconnect 로그 억제. 루프가 수 초 단위라 매번 찍으면 이 줄이 저널을 메워,
# 채널을 특정해 주는 줄(chk_cam_connect 의 rx3/link)이 뒤로 밀려 사라진다.
# 상태가 바뀌면 즉시 찍고, 같은 상태가 이어지면 이 간격으로만 재확인한다.
DISCONNECT_LOG_REPEAT_SEC=60
drv_log_sig=""
drv_log_ts=0

# sysfs link_status 비트마스크를 읽어서 disconnect된 채널에 에러 플래그 생성
# 비트마스크: bit0=ch0, bit1=ch1, bit2=ch2, bit3=ch3 (cam_ch_bit과 동일)
# sysfs 값: -1=미확인, 0=정상, 1~15=disconnect 비트마스크
# 리턴: 0=disconnect 없음, 1=하나 이상 disconnect
check_driver_disconnect() {
    local mask_i2c2 mask_i2c1 disconnect_mask actual_disconnect

    mask_i2c2=$(cat "$SYSFS_LINK_I2C2" 2>/dev/null | tr -d '\n')
    mask_i2c1=$(cat "$SYSFS_LINK_I2C1" 2>/dev/null | tr -d '\n')
    [ -z "$mask_i2c2" ] || [ "$mask_i2c2" -lt 0 ] 2>/dev/null && mask_i2c2=0
    [ -z "$mask_i2c1" ] || [ "$mask_i2c1" -lt 0 ] 2>/dev/null && mask_i2c1=0

    disconnect_mask=$((mask_i2c2 | mask_i2c1))
    actual_disconnect=$((disconnect_mask & cam_ch_bit))

    # 로그에 채널을 찍기 위해 전역으로 올린다. 원시 마스크도 함께 남기는데,
    # 합쳐진 마스크만으로는 어느 버스(des)에서 온 보고인지 알 수 없기 때문이다.
    drv_mask_i2c2=$mask_i2c2
    drv_mask_i2c1=$mask_i2c1
    drv_disconnect_mask=$actual_disconnect

    if [ "$actual_disconnect" -ne 0 ]; then
        for ch in 0 1 2 3; do
            if [ $(( (actual_disconnect >> ch) & 1 )) -eq 1 ]; then
                echo "$(date +'%Y-%m-%d %T,%3N') CAM${ch} DRIVER_DISCONNECT" \
                    > "${FLAG_PATH}/err_cam${ch}.log"
            fi
        done
        return 0
    fi

    return 1
}

if [[ -n "$1" ]]; then
    delay=$1
fi

cam_state_init

function CLEAR_CHK_LOG() {
	touch $FLAG_PATH/bg_chk_flag.bin
	rm ${FLAG_PATH}/err_* 2>/dev/null
	rm ${FLAG_PATH}/wifi_connected.log 2>/dev/null
}

function MAKE_RESULT_FLAG() {
	result=0
	if [[ -e ${FLAG_PATH}/err_cam0.log ]]; then 
		result=$(echo "$result + 1" | bc)
		#echo "bg_chk_flag : $result"
	fi
	if [[ -e ${FLAG_PATH}/err_cam1.log ]]; then 
		result=$(echo "$result + 2" | bc)
		#echo "bg_chk_flag : $result"
	fi	
	if [[ -e ${FLAG_PATH}/err_cam2.log ]]; then 
		result=$(echo "$result + 4" | bc)
		#echo "bg_chk_flag : $result"
	fi		
	if [[ -e ${FLAG_PATH}/err_cam3.log ]]; then 
		result=$(echo "$result + 8" | bc)
		#echo "bg_chk_flag : $result"
	fi		
	if [[ -e ${FLAG_PATH}/err_wifi.log ]]; then 
		result=$(echo "$result + 16" | bc)
		#echo "bg_chk_flag : $result"
	fi		
	if [[ -e ${FLAG_PATH}/err_sdcard.log ]]; then 
		result=$(echo "$result + 32" | bc)
		#echo "bg_chk_flag : $result"
	fi		
	if [[ -e ${FLAG_PATH}/err_cpu_temp.log ]]; then 
		result=$(echo "$result + 64" | bc)
		#echo "bg_chk_flag : $result"
	fi		
	if [[ -e ${FLAG_PATH}/err_voltage.log ]]; then 
		result=$(echo "$result + 128" | bc)
		#echo "bg_chk_flag : $result"
	fi
	#echo "$result" >> ${FLAG_PATH}/bg_chk_flag.bin
	
	printf "%d" $result > ${FLAG_PATH}/bg_chk_flag.bin
}

streak_get() {
	local v
	v=$(cat /tmp/cam_state/streak 2>/dev/null | tr -d '\n')
	if [[ ! "$v" =~ ^[0-9]+$ ]]; then
		echo 0
		return 0
	fi
	echo "$v"
}

streak_set() {
	printf "%s" "$1" > /tmp/cam_state/streak 2>/dev/null
}

update_cam_state_from_errors() {
	if [ -f "${FLAG_PATH}/err_cam0.log" ]; then
		cam_channel_error 0
	fi
	if [ -f "${FLAG_PATH}/err_cam1.log" ]; then
		cam_channel_error 1
	fi
	if [ -f "${FLAG_PATH}/err_cam2.log" ]; then
		cam_channel_error 2
	fi
	if [ -f "${FLAG_PATH}/err_cam3.log" ]; then
		cam_channel_error 3
	fi
}

CLEAR_CHK_LOG
sleep $delay
logger -p local0.notice "[CHK][$tag:$LINENO] BG check loop start(ch0:$cam_ch0, ch1:$cam_ch1, ch2:$cam_ch2, ch3:$cam_ch3)"

#/opt/pim/bin/chk_cam_disconnect.sh $cam_ch_bit 3 2>/dev/null

while true; do
    sleep 1
    #echo "START!! BG_CHK"
    CLEAR_CHK_LOG
    #wifi check
    #echo "wifi"
    /opt/pim/bin/chk_wifi.sh 2>/dev/null
    #eth0 check
    #echo "eth0"
    /opt/pim/bin/chk_eth1.sh 2>/dev/null
    #sd mount check
    #echo "sd"
    /opt/pim/bin/chk_sd_mount.sh 2>/dev/null
    #cpu temp check
    #echo "temp"
    /opt/pim/bin/chk_cpu_temp.sh 2>/dev/null
    #power check
    #echo "volt"
    /opt/pim/bin/chk_voltage.sh 2>/dev/null
    #cam connect check
    #echo "cam"
    drv_disconnect=0
    if check_driver_disconnect; then
        drv_disconnect=1
        # 드라이버 마스크는 splitter 에서 한쪽만 빠져도 두 채널을 다 세운다(실측
        # i2c2=3). 여기서 chk_cam_connect 를 건너뛰므로, 채널을 갈라 주는 RX3 를
        # 읽는 경로가 이 분기밖에 없다. 캐시하지 않고 매번 읽는다 — stale 값을
        # 현재처럼 찍으면 drv 와 똑같은 함정이 된다. 보고가 있는 버스만 읽는다.
        # rx3_sig 는 억제 판정용, rx3_info 는 표시용으로 나눈다. hint 에는 경과
        # 시간이 들어가 매초 달라지므로, 서명에 섞으면 억제가 통째로 무력화된다.
        rx3_info=""; rx3_sig=""
        if [ "$drv_mask_i2c2" -ne 0 ]; then
            rx3_r=$(read_rx3_links 2)
            rx3_sig="$rx3_sig|$rx3_r"
            rx3_info="$rx3_info rx3_2=$rx3_r$(rx3_link_hint 2 "$rx3_r")"
        fi
        if [ "$drv_mask_i2c1" -ne 0 ]; then
            rx3_r=$(read_rx3_links 1)
            rx3_sig="$rx3_sig|$rx3_r"
            rx3_info="$rx3_info rx3_1=$rx3_r$(rx3_link_hint 1 "$rx3_r")"
        fi
        drv_log_now=$(now_ts)
        drv_log_cur="$drv_disconnect_mask|$drv_mask_i2c2|$drv_mask_i2c1|$rx3_sig"
        if [ "$drv_log_cur" != "$drv_log_sig" ] ||
           [ $((drv_log_now - drv_log_ts)) -ge "$DISCONNECT_LOG_REPEAT_SEC" ]; then
            logger -p local0.notice "[CHK][$tag:$LINENO] driver detected disconnect($(mask_to_chs "$drv_disconnect_mask")), skip chk_cam_connect (i2c2=$drv_mask_i2c2 i2c1=$drv_mask_i2c1$rx3_info)"
            drv_log_sig="$drv_log_cur"
            drv_log_ts=$drv_log_now
        fi
    elif [ ! -f /tmp/start_video_time_chk ]; then
        drv_log_sig=""
        logger -p local0.info "[CHK][$tag:$LINENO] skip chk_cam_connect: gstApp not yet playing"
    else
        # disconnect 가 풀렸다. 다음에 다시 빠지면 같은 값이라도 즉시 찍히도록
        # 억제 상태를 비운다. 안 그러면 짧게 붙었다 떨어질 때 로그가 통째로 빠진다.
        drv_log_sig=""
        /opt/pim/bin/chk_cam_connect.sh $cam_ch_bit 2>/dev/null
    fi

    if in_startup_grace || in_init_cooldown; then
        if [ "$drv_disconnect" -eq 0 ]; then
            rm ${FLAG_PATH}/err_cam* 2>/dev/null
        fi
		streak_set 0
		cam_reset_streak
    else
        update_cam_state_from_errors
    fi
    #make result cmd
    #echo "make flag"
    MAKE_RESULT_FLAG
    #echo "led"
    /opt/pim/bin/led_ctrl.sh 2>/dev/null

    if [ -f /tmp/init_cam_flag ] || [ -f /tmp/restart_flag ]; then
        i=0
		streak_set 0
		cam_reset_streak
        continue
    fi

	err_chs=$(err_cam_chs)
	if [ -n "$err_chs" ]; then
		# streak 증가는 cam_inc_streak(cam_state.sh)이 단독으로 수행한다.
		# 같은 /tmp/cam_state/streak 파일을 streak_set으로 또 쓰면 2씩 증가한다.
		cam_inc_streak
		streak=$(streak_get)
		# streak 은 연속 실패 '횟수'다. 채널 번호로 오해하기 쉬워 채널을 함께 찍는다.
		logger -p local0.crit "[CHK][$tag:$LINENO] cam disconnect : streak=$streak ($err_chs)"
	else
		streak_set 0
		cam_reset_streak
	fi

done
