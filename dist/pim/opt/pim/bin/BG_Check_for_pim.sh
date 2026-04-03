#!/bin/bash
source /opt/pim/lib/cam_state.sh

FLAG_PATH="/tmp"
tag=$(basename "$0")
result=0
delay=25
i=0
# bg_cam_err_streak는 cam_state/streak로 통합됨
JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
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
init_cooldown_sec=$(jq -r '(.ETC.init_cooldown_sec // 30)' "$ORD_VCM_JSON" 2>/dev/null || echo 30)
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
        logger -p local0.notice "[CHK][$tag:$LINENO] driver detected disconnect, skip chk_cam_connect"
    elif [ ! -f /tmp/start_video_time_chk ]; then
        logger -p local0.info "[CHK][$tag:$LINENO] skip chk_cam_connect: gstApp not yet playing"
    else
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

	streak=$(streak_get)
	if [ -f "${FLAG_PATH}"/err_cam0.log ] || [ -f "${FLAG_PATH}"/err_cam1.log ] || [ -f "${FLAG_PATH}"/err_cam2.log ]  || [ -f "${FLAG_PATH}"/err_cam3.log ] ; then
		streak=$((streak + 1))
		streak_set "$streak"
		cam_inc_streak
		logger -p local0.crit "[CHK][$tag:$LINENO] cam disconnect : $streak"
	else
		streak_set 0
		cam_reset_streak
	fi

done
