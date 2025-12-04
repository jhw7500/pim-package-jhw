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
    cam_ch0 cam_ch1 cam_ch2 cam_ch3 < <(
    jq -r '[
        (.VHL_CAM.i2c2.ch0.enable // false),
        (.VHL_CAM.i2c2.ch1.enable // false),
        (.VHL_CAM.i2c1.ch2.enable // false),
        (.VHL_CAM.i2c1.ch3.enable // false)
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
                logger -p local0.error  "[$KEY][$tag:$LINENO] /opt/pim/bin/init_cam.sh"
                /opt/pim/bin/init_cam.sh
        fi
    else
        i=0
    fi

done
