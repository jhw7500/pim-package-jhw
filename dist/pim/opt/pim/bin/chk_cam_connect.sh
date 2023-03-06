#!/bin/bash

TEST_CONFIG_FILE="/root/shared_v/edgeconf_pim.json"
FLAG_PATH="/opt/pim/bin/bg_chk_flag"
LOG_PATH="/var/log"
SUCCESS_VAL="true"
FAIL_VAL="error"
result=0;
timestamp=`date +"%Y-%m-%d %T,%3N"`

function LogWrite() {
	timestamp=`date +"%Y-%m-%d %T,%3N"`
	if [ $# -eq 1 ]; then
		echo "${timestamp} $1" >> "${LOG_PATH}/bg_chk.log"						
	fi
}



if [[ ! -s "$TEST_CONFIG_FILE" ]]; then 
	LogWrite "can't find $TEST_CONFIG_FILE"
	result=1 ; 
else
	cam_ch0_en=$(cat $TEST_CONFIG_FILE | grep cam_ch0 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	if [[ "$cam_ch0_en" == *"$SUCCESS_VAL"* ]] ; then
		cam0_rot=$(cat $TEST_CONFIG_FILE | grep cam_ch0_rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
		if [[ "$cam0_rot" == *"$SUCCESS_VAL"* ]] ; then
			i2ctransfer -f -y -a 2 w4@0x11 0x10 0x0c 0x00 0x03         #rotate ch0
		else 
			i2ctransfer -f -y -a 2 w4@0x11 0x10 0x0c 0x00 0x00         #default ch0
		fi
        
		if [ $? -ne 0 ];then
	        	LogWrite "cam0 disconected!"
			echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log	
			result=1;
		fi
	fi	

	cam_ch1_en=$(cat $TEST_CONFIG_FILE | grep cam_ch1 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	if [[ "$cam_ch1_en" == *"$SUCCESS_VAL"* ]] ; then
		cam1_rot=$(cat $TEST_CONFIG_FILE | grep cam_ch1_rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
		if [[ "$cam1_rot" == *"$SUCCESS_VAL"* ]] ; then
			i2ctransfer -f -y -a 2 w4@0x12 0x10 0x0c 0x00 0x03         #rotate ch1
		else 
			i2ctransfer -f -y -a 2 w4@0x12 0x10 0x0c 0x00 0x00         #default ch1
		fi
		if [ $? -ne 0 ];then
	        	LogWrite "cam1 disconected!"
            		echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log	
			result=1;
	    	fi
	fi	

	cam_ch2_en=$(cat $TEST_CONFIG_FILE | grep cam_ch2 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	if [[ "$cam_ch2_en" == *"$SUCCESS_VAL"* ]] ; then
		cam2_rot=$(cat $TEST_CONFIG_FILE | grep cam_ch2_rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
		if [[ "$cam2_rot" == *"$SUCCESS_VAL"* ]] ; then
			i2ctransfer -f -y -a 1 w4@0x11 0x10 0x0c 0x00 0x03         #rotate ch2
		else 
			i2ctransfer -f -y -a 1 w4@0x11 0x10 0x0c 0x00 0x00         #default ch2
		fi
        
        	if [ $? -ne 0 ];then
	        	LogWrite "cam2 disconected!"
            		echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log	
			result=1;
	   	 fi
	fi	

	cam_ch3_en=$(cat $TEST_CONFIG_FILE | grep cam_ch3 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	if [[ "$cam_ch3_en" == *"$SUCCESS_VAL"* ]] ; then		
		cam3_rot=$(cat $TEST_CONFIG_FILE | grep cam_ch3_rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
		if [[ "$cam3_rot" == *"$SUCCESS_VAL"* ]] ; then
			i2ctransfer -f -y -a 1 w4@0x12 0x10 0x0c 0x00 0x03         #rotate ch3
		else 
			i2ctransfer -f -y -a 1 w4@0x12 0x10 0x0c 0x00 0x00         #default ch3
		fi

        	if [ $? -ne 0 ];then
	        	LogWrite "cam3 disconected!"
            		echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log	
			result=1;
	    	fi
	fi	
fi

if [ $result -eq 1 ]
then
	exit 1
else
	exit 0
fi
