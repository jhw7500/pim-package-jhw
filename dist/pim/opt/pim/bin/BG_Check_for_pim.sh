#!/bin/bash
FLAG_PATH="/tmp"

function CLEAR_CHK_LOG() {
	rm ${FLAG_PATH}/err_* 2>/dev/null
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
sleep 20
while true; do
    #echo "START!! BG_CHK"
    CLEAR_CHK_LOG
    #wifi check
    #echo "wifi"
    /opt/pim/bin/chk_wifi.sh
    #eth0 check
    #echo "eth0"
    /opt/pim/bin/chk_eth0.sh
    #sd mount check
    #echo "sd"
    /opt/pim/bin/chk_sd_mount.sh
    #cpu temp check
    #echo "temp"
    /opt/pim/bin/chk_cpu_temp.sh
    #power check
    #echo "volt"
    /opt/pim/bin/chk_voltage.sh
    #cam connect check
    #echo "cam"
    /opt/pim/bin/chk_cam_connect.sh 2>/dev/null
    #make result cmd
    #echo "make flag"
    MAKE_RESULT_FLAG
    #echo "led"
    /opt/pim/bin/led_ctrl.sh
    sleep 1
done
