#!/bin/bash
JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
TEST_CONFIG_FILE=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
FLAG_PATH="/tmp"
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

CH0_EN_OK="0xea"
CH1_EN_OK="0xda"
CH2_EN_OK="0xea"
CH3_EN_OK="0xda"

CH0_EN_FAIL="0x26"
CH1_EN_FAIL="0x16"
CH2_EN_FAIL="0x26"
CH3_EN_FAIL="0x16"

#ch0/1 Des check
cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
#ch2/3 Des check
cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)

if [[ ! -s "$TEST_CONFIG_FILE" ]]; then 
	logger -p local0.error "[CHK][$tag:$LINENO] Not Found $TEST_CONFIG_FILE"
	result=1 ; 
else
	cam_ch0_en=$(cat $TEST_CONFIG_FILE | grep cam_ch0 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	cam_ch1_en=$(cat $TEST_CONFIG_FILE | grep cam_ch1 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	cam_ch2_en=$(cat $TEST_CONFIG_FILE | grep cam_ch2 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	cam_ch3_en=$(cat $TEST_CONFIG_FILE | grep cam_ch3 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	
	#CAM0, CAM1 ENABLE
	if [[ "$cam_ch0_en" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch1_en" == *"$ENABLE_VAL"* ]]; then
		if [[ "$cam01_res" == *"$SUCCESS_VAL"*  ]]; then
			logger -p local0.info "[CHK][$tag:$LINENO] CAM0 CAM1 OK"
		else
			for i in {1..5}; do
				i2ctransfer -f -y -a 2 w3@0x48 0x00 0x10 0x31
				sleep 3

				i2ctransfer -f -y -a 2 w3@0x40 0x00 0x10 0x21
				sleep 3

				cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
				
				if [[ "$cam01_res" == *"$CAM1_ERR"* ]]; then
					logger -p local0.error "[CHK][$tag:$LINENO] CAM1_ERR : $cam01_res $i"
					echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
					break
				elif [[ "$cam01_res" == *"$CAM0_ERR"* ]]; then
					logger -p local0.error "[CHK][$tag:$LINENO] CAM0_ERR : $cam01_res $i"
					echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
					break
				elif [[ "$cam01_res" == *"$CAM01_ERR"* ]]; then
					logger -p local0.error "[CHK][$tag:$LINENO] CAM0_ERR : $cam01_res $i"
					logger -p local0.error "[CHK][$tag:$LINENO] CAM1_ERR : $cam01_res $i"
					echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
					echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
					break
				else 
					logger -p local0.error "[CHK][$tag:$LINENO] CAM0_ERR : $cam01_res $i"
					logger -p local0.error "[CHK][$tag:$LINENO] CAM1_ERR : $cam01_res $i"
					echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
					echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
				fi	
			done
		fi
	#CAM0 ENABLE ONLY
	elif [[ "$cam_ch0_en" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch1_en" == *"$DISABLE_VAL"* ]]; then
		if [[ "$cam01_res" == *"$CH0_EN_OK"*  ]]; then
            logger -p local0.info "[CHK][$tag:$LINENO] CAM0 OK"
        elif [[ "$cam01_res" == *"$CH1_EN_OK"*  ]]; then
            logger -p local0.warn "[CHK][$tag:$LINENO] please swap ch0 and ch1(CAM0 enable but CAM1 display)"
            #echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
        else
			logger -p local0.error "[CHK][$tag:$LINENO] CAM0_ERR : $cam01_res $i"
			echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log	
		fi
    #CAM1 ENABLE ONLY
    elif [[ "$cam_ch0_en" == *"$DISABLE_VAL"* ]] && [[ "$cam_ch1_en" == *"$ENABLE_VAL"* ]]; then
        if [[ "$cam01_res" == *"$CH1_EN_OK"*  ]]; then
            logger -p local0.info "[CHK][$tag:$LINENO] CAM1 OK"
        elif [[ "$cam01_res" == *"$CH0_EN_OK"*  ]]; then
            logger -p local0.warn "[CHK][$tag:$LINENO] please swap ch0 and ch1(CAM1 enable but CAM0 display)"
            #echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
        else
            logger -p local0.error "[CHK][$tag:$LINENO] CAM1_ERR : $cam01_res $i"
            echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
        fi
    else
        logger -p local0.info "[CHK][$tag:$LINENO] CAM0 CAM1 disable"
	fi
	
	#CAM2,CAM3 ENABLE
	if [[ "$cam_ch2_en" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch3_en" == *"$ENABLE_VAL"* ]]; then
		if [[ "$cam23_res" == *"$SUCCESS_VAL"*  ]]; then
			logger -p local0.info "[CHK][$tag:$LINENO] CAM2 CAM3 OK"
		else
			for i in {1..5}; do	
				i2ctransfer -f -y -a 1 w3@0x48 0x00 0x10 0x31
				sleep 3
				i2ctransfer -f -y -a 1 w3@0x40 0x00 0x10 0x21
				sleep 3
				cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)
				if [[ "$cam23_res" == *"$CAM3_ERR"* ]]; then
					logger -p local0.error "[CHK][$tag:$LINENO] CAM3_ERR : $cam23_res $i"
					echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
					break
				elif [[ "$cam23_res" == *"$CAM2_ERR"* ]]; then
					logger -p local0.error "[CHK][$tag:$LINENO] CAM2_ERR : $cam23_res $i"
					echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
					break
				elif [[ "$cam23_res" == *"$CAM23_ERR"* ]]; then
					logger -p local0.error "[CHK][$tag:$LINENO] CAM3_ERR : $cam23_res $i"
					logger -p local0.error "[CHK][$tag:$LINENO] CAM2_ERR : $cam23_res $i"
					echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
					echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
					break
				else
					logger -p local0.error "[CHK][$tag:$LINENO] CAM3_ERR : $cam23_res $i"
					logger -p local0.error "[CHK][$tag:$LINENO] CAM2_ERR : $cam23_res $i"
					echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
					echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
				fi
			done
		fi
	#CAM2 ENABLE ONLY
	elif [[ "$cam_ch2_en" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch3_en" == *"$DISABLE_VAL"* ]]; then
		if [[ "$cam23_res" == *"$CH2_EN_OK"*  ]]; then
            logger -p local0.info "[CHK][$tag:$LINENO] CAM2 OK"
        elif [[ "$cam23_res" == *"$CH3_EN_OK"*  ]]; then
            logger -p local0.warn "[CHK][$tag:$LINENO] please swap ch2 and ch3(CAM2 enable but CAM3 display)"
            #echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
        else
			logger -p local0.error "[CHK][$tag:$LINENO] CAM2_ERR : $cam23_res $i"
			echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
		fi
    #CAM3 ENABLE ONLY
    elif [[ "$cam_ch2_en" == *"$DISABLE_VAL"* ]] && [[ "$cam_ch3_en" == *"$ENABLE_VAL"* ]]; then
        if [[ "$cam23_res" == *"$CH3_EN_OK"*  ]]; then
            logger -p local0.info "[CHK][$tag:$LINENO] CAM3 OK"
        elif [[ "$cam23_res" == *"$CH2_EN_OK"*  ]]; then
            logger -p local0.warn "[CHK][$tag:$LINENO] please swap ch2 and ch3(CAM3 enable but CAM2 display)"
            #echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
        else
            logger -p local0.error "[CHK][$tag:$LINENO] CAM3_ERR : $cam23_res $i"
            echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
        fi
	fi
fi
