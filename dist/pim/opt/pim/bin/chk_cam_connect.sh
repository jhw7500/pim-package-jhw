#!/bin/bash
TEST_CONFIG_FILE="/root/shared_v/edgeconf_pim.json"
FLAG_PATH="/opt/pim/bin/bg_chk_flag"
tag=$(basename "$0")

SUCCESS_VAL="0xfa"
CAM0_ERR="0xda"
CAM1_ERR="0xea"
CAM01_ERR="0x16"

CAM0_EN_ERR="0x26"
CAM012_EN_ERR="0x26"

CAM2_ERR="0xda"
CAM3_ERR="0xea"
CAM23_ERR="0x16"

ENABLE_VAL="true"
DISABLE_VAL="false"
result=0;
timestamp=`date +"%Y-%m-%d %T,%3N"`


#ch0/1 Des check
cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
#ch2/3 Des check
cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)


if [[ ! -s "$TEST_CONFIG_FILE" ]]; then 
	logger -p local0.error -t $tag [CHK] Not Found $TEST_CONFIG_FILE
	result=1 ; 
else
	cam_ch0_en=$(cat $TEST_CONFIG_FILE | grep cam_ch0 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	cam_ch1_en=$(cat $TEST_CONFIG_FILE | grep cam_ch1 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	cam_ch2_en=$(cat $TEST_CONFIG_FILE | grep cam_ch2 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	cam_ch3_en=$(cat $TEST_CONFIG_FILE | grep cam_ch3 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	
	#CAM0, CAM1 ENABLE
	if [[ "$cam_ch0_en" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch1_en" == *"$ENABLE_VAL"* ]]; then
		if [[ "$cam01_res" == *"$SUCCESS_VAL"*  ]]; then
			logger -p local0.info -t $tag [CHK] CAM0 CAM1 OK
		else
			for i in {1..5}; do
				i2ctransfer -f -y -a 2 w3@0x48 0x00 0x10 0x31
				sleep 3

				i2ctransfer -f -y -a 2 w3@0x40 0x00 0x10 0x21
				sleep 3

				cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
				
				if [[ "$cam01_res" == *"$CAM1_ERR"* ]]; then
					logger -p local0.error -t $tag [CHK] CAM1_ERR : $cam01_res $i
					echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log	
					break
				elif [[ "$cam01_res" == *"$CAM0_ERR"* ]]; then
					logger -p local0.error -t $tag [CHK] CAM0_ERR : $cam01_res $i
					echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log	
					break
				elif [[ "$cam01_res" == *"$CAM01_ERR"* ]]; then
					logger -p local0.error -t $tag [CHK] CAM0_ERR : $cam01_res $i
					logger -p local0.error -t $tag [CHK] CAM1_ERR : $cam01_res $i
					echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log	
					echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log	
					break
				else 
					logger -p local0.error -t $tag [CHK] CAM0_ERR : $cam01_res $i
					logger -p local0.error -t $tag [CHK] CAM1_ERR : $cam01_res $i
					echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log	
					echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log	
				fi	
			done
		fi
	fi
	
	#CAM0 ENABLE ONLY
	if [[ "$cam_ch0_en" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch1_en" == *"$DISABLE_VAL"* ]]; then
		if [[ "$cam01_res" == *"$CAM0_EN_ERR"*  ]]; then
			logger -p local0.error -t $tag [CHK] CAM0_ERR : $cam01_res $i
			echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log	
		else
			logger -p local0.info -t $tag [CHK] CAM0 OK
		fi
	fi
	
	#CAM2,CAM3 ENABLE
	if [[ "$cam_ch2_en" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch3_en" == *"$ENABLE_VAL"* ]]; then
		if [[ "$cam23_res" == *"$SUCCESS_VAL"*  ]]; then
			logger -p local0.info -t $tag [CHK] CAM2 CAM3 OK
		else
			for i in {1..5}; do	
				i2ctransfer -f -y -a 1 w3@0x48 0x00 0x10 0x31
				sleep 3
				i2ctransfer -f -y -a 1 w3@0x40 0x00 0x10 0x21
				sleep 3
				cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)
				if [[ "$cam23_res" == *"$CAM3_ERR"* ]]; then
					logger -p local0.error -t $tag [CHK] CAM3_ERR : $cam23_res $i
					echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log	
					break
				elif [[ "$cam23_res" == *"$CAM2_ERR"* ]]; then
					logger -p local0.error -t $tag [CHK] CAM2_ERR : $cam23_res $i
					echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log	
					break
				elif [[ "$cam23_res" == *"$CAM23_ERR"* ]]; then
					logger -p local0.error -t $tag [CHK] CAM3_ERR : $cam23_res $i
					logger -p local0.error -t $tag [CHK] CAM2_ERR : $cam23_res $i
					echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log	
					echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log	
					break
				else
					logger -p local0.error -t $tag [CHK] CAM3_ERR : $cam23_res $i
					logger -p local0.error -t $tag [CHK] CAM2_ERR : $cam23_res $i					
					echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log	
					echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log						
				fi
			done	
		fi
	fi
	
	#CAM0, CAM1, CAM2 ENABLE
	if [[ "$cam_ch2_en" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch3_en" == *"$DISABLE_VAL"* ]]; then
		if [[ "$cam23_res" == *"$CAM012_EN_ERR"*  ]]; then
			logger -p local0.error -t $tag [CHK] CAM2_ERR : $cam23_res $i
			echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log	
		else
			logger -p local0.notice -t $tag [CHK] CAM2 OK
		fi
	fi
fi
