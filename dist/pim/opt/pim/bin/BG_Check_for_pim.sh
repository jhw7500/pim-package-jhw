#!/bin/bash
FLAG_PATH="/opt/pim/bin/bg_chk_flag"

function CLEAR_CHK_LOG() {
    rm ${FLAG_PATH}/*.*
}


function MAKE_RESULT_FLAG() {
	result=0
	if [[ -e ${FLAG_PATH}/err_cam0.log ]]; then 
		result=$(echo "$result + 1" | bc)
		echo "bg_chk_flag : $result"
	fi
	if [[ -e ${FLAG_PATH}/err_cam1.log ]]; then 
		result=$(echo "$result + 2" | bc)
		echo "bg_chk_flag : $result"
	fi	
	if [[ -e ${FLAG_PATH}/err_cam2.log ]]; then 
		result=$(echo "$result + 4" | bc)
		echo "bg_chk_flag : $result"
	fi		
	if [[ -e ${FLAG_PATH}/err_cam3.log ]]; then 
		result=$(echo "$result + 8" | bc)
		echo "bg_chk_flag : $result"
	fi		
	if [[ -e ${FLAG_PATH}/err_wifi.log ]]; then 
		result=$(echo "$result + 16" | bc)
		echo "bg_chk_flag : $result"
	fi		
	if [[ -e ${FLAG_PATH}/err_sdcard.log ]]; then 
		result=$(echo "$result + 32" | bc)
		echo "bg_chk_flag : $result"
	fi		
	if [[ -e ${FLAG_PATH}/err_cpu_temp.log ]]; then 
		result=$(echo "$result + 64" | bc)
		echo "bg_chk_flag : $result"
	fi		
	if [[ -e ${FLAG_PATH}/err_voltage.log ]]; then 
		result=$(echo "$result + 128" | bc)
		echo "bg_chk_flag : $result"
	fi
	
	printf "0x%x" $result > ${FLAG_PATH}/bg_chk_flag.bin
}

CLEAR_CHK_LOG
while true; do
	sleep 10
    #cam connect check
    /opt/pim/bin/chk_cam_connect.sh
    #wifi check
    /opt/pim/bin/chk_wifi.sh
    #eth0 check
    /opt/pim/bin/chk_eth0.sh
    #sd mount check
    /opt/pim/bin/chk_sd_mount.sh
    #cpu temp check
    /opt/pim/bin/chk_cpu_temp.sh
    #power check
    /opt/pim/bin/chk_voltage.sh
    #make result cmd
    MAKE_RESULT_FLAG
done
