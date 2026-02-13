#!/bin/bash
FLAG_PATH="/tmp"
tag=$(basename "$0")
result=0
delay=25
i=0
JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
#cam_ch0=$(jq '.VHL_CAM.i2c2.ch0.enable' "$FILE_JSON")
#cam_ch1=$(jq '.VHL_CAM.i2c2.ch1.enable' "$FILE_JSON")
#cam_ch2=$(jq '.VHL_CAM.i2c1.ch2.enable' "$FILE_JSON")
#cam_ch3=$(jq '.VHL_CAM.i2c1.ch3.enable' "$FILE_JSON")
IFS=$'\t' read -r \
    cam_ch0 cam_ch1 cam_ch2 cam_ch3 vhl_name tmp_path muxer delay < <(
    jq -r '[
        (.VHL_CAM.i2c2.ch0.enable // false),
        (.VHL_CAM.i2c2.ch1.enable // false),
        (.VHL_CAM.i2c1.ch2.enable // false),
        (.VHL_CAM.i2c1.ch3.enable // false),
        (.VHL_CAM.vhl_name // "VD3001"),
        (.VHL_CAM.tmp_path // "/dev/shm"),
        (.VHL_CAM.muxer // "mp4"),
        (.VHL_CAM.delay // 5)
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

now_ts() { date +%s; }
read_ts() { [ -f "$1" ] && cat "$1" 2>/dev/null | tr -d '\n' || echo 0; }

stream_active() {
    local win now newest ts f
    win=${1:-10}
    now=$(now_ts)
    newest=0
    shopt -s nullglob
    for f in "${tmp_path}/${vhl_name}"_*"-ch"*."${muxer}".part; do
        ts=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        [ "$ts" -gt "$newest" ] && newest="$ts"
    done
    shopt -u nullglob
    [ "$newest" -gt 0 ] && [ $((now - newest)) -le "$win" ]
}

in_startup_grace() {
    local start_ts start_delay now grace
    now=$(now_ts)
    start_ts=$(read_ts "/tmp/pim_cam_start_ts")
    start_delay=$(read_ts "/tmp/pim_cam_start_delay")
    grace=$((start_delay + 10))
    [ "$start_ts" -gt 0 ] && [ $((now - start_ts)) -lt "$grace" ]
}

in_init_cooldown() {
    local now last
    now=$(now_ts)
    last=$(read_ts "/tmp/last_init_cam_ts")
    [ "$last" -gt 0 ] && [ $((now - last)) -lt 40 ]
}

if [[ -n "$1" ]]; then
    delay=$1
fi

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
    #/opt/pim/bin/chk_eth1.sh 2>/dev/null
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
    /opt/pim/bin/chk_cam_connect.sh $cam_ch_bit 2>/dev/null

    if in_startup_grace || in_init_cooldown || stream_active 10; then
        rm ${FLAG_PATH}/err_cam* 2>/dev/null
    fi
    #make result cmd
    #echo "make flag"
    MAKE_RESULT_FLAG
    #echo "led"
    /opt/pim/bin/led_ctrl.sh 2>/dev/null

    if [ -f /tmp/init_cam_flag ] || [ -f /tmp/restart_flag ]; then
        i=0
        continue
    fi

    if [ -f "${FLAG_PATH}"/err_cam0.log ] || [ -f "${FLAG_PATH}"/err_cam1.log ] || [ -f "${FLAG_PATH}"/err_cam2.log ]  || [ -f "${FLAG_PATH}"/err_cam3.log ] ; then
        #echo "cam_err"
        #err_file=$(ls ${FLAG_PATH}/err_cam*)
        ((i++))
        logger -p local0.emerg "[CHK][$tag:$LINENO] cam disconnect : $i"
        #creboot
        if [ "$i" -gt 1 ]; then
                #logger -p local0.emerg "[CHK][$tag:$LINENO] reboot because cam disconnect"
                #sleep 1
                #reboot
                # Recovery ownership: request init_cam; chk_cam_operate.sh performs retry/init/reboot.
                if [ ! -f /tmp/recover_req_init_cam ]; then
                    logger -p local0.error  "[CHK][$tag:$LINENO] request init_cam because cam disconnect"
                    touch /tmp/recover_req_init_cam
                fi
        fi
    else
        i=0
    fi

done
