#!/bin/bash
#JSON_PREFIX=edgeconf_
#JOSN_SUFFIX=.json
#FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
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

cam_ch_en=$1
# 전 채널 disable 시 deserializer가 power-down되어 i2c NACK이 발생하므로 i2c 트랜잭션 자체를 건너뛴다.
if [ "${cam_ch_en:-0}" -eq 0 ] 2>/dev/null; then
    logger -p local0.info "[CHK][$tag:$LINENO] all camera channels disabled (cam_ch_en=${cam_ch_en:-0}), skip i2c check"
    exit 0
fi
if [[ $((cam_ch_en&0x01)) == 1 ]]; then
    cam_ch0="true"
else
    cam_ch0="false"
fi
if [[ $((cam_ch_en>>1&0x01)) == 1 ]]; then
    cam_ch1="true"
else
    cam_ch1="false"
fi
if [[ $((cam_ch_en>>2&0x01)) == 1 ]]; then
    cam_ch2="true"
else
    cam_ch2="false"
fi
if [[ $((cam_ch_en>>3&0x01)) == 1 ]]; then
    cam_ch3="true"
else
    cam_ch3="false"
fi

#ch0/1 Des check
cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
#ch2/3 Des check
cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)

#if [[ ! -s "$FILE_JSON" ]]; then 
#	logger -p local0.error "[CHK][$tag:$LINENO] Not Found $FILE_JSON"
#	result=1 ; 
#else
    #cam_ch0=$(jq '.VHL_CAM.cam_ch0' "$FILE_JSON")
    #cam_ch1=$(jq '.VHL_CAM.cam_ch1' "$FILE_JSON")
    #cam_ch2=$(jq '.VHL_CAM.cam_ch2' "$FILE_JSON")
    #cam_ch3=$(jq '.VHL_CAM.cam_ch3' "$FILE_JSON")

	#CAM0, CAM1 ENABLE
	if [[ "$cam_ch0" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
		if [[ "$cam01_res" == *"$SUCCESS_VAL"*  ]]; then
			logger -p local0.debug "[CHK][$tag:$LINENO] CAM0 CAM1 OK"
		else
			# Phase 1: read-only retry (no reset write)
			for r in 1 2 3; do
				sleep 0.3
				cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
				if [[ "$cam01_res" == *"$SUCCESS_VAL"* ]]; then
					logger -p local0.info "[CHK][$tag:$LINENO] CAM0 CAM1 OK (read retry $r)"
					break
				fi
			done

			# Phase 2: reset + read (only if read-only retry failed)
			if [[ "$cam01_res" != *"$SUCCESS_VAL"* ]]; then
				logger -p local0.error "[CHK][$tag:$LINENO] CAM01 read retry failed, reset : $cam01_res"
				i2ctransfer -f -y -a 2 w3@0x48 0x00 0x10 0x31
				i2ctransfer -f -y -a 2 w3@0x40 0x00 0x10 0x21
				sleep 1
				cam01_res=$(i2ctransfer -f -y -a 2 w2@0x48 0x00 0x13 r1)
			fi

			# error classification
			if [[ "$cam01_res" == *"$SUCCESS_VAL"* ]]; then
				logger -p local0.info "[CHK][$tag:$LINENO] CAM0 CAM1 recovered after reset"
			elif [[ "$cam01_res" == *"$CAM1_ERR"* ]]; then
				logger -p local0.error "[CHK][$tag:$LINENO] CAM1_ERR : $cam01_res"
				echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
			elif [[ "$cam01_res" == *"$CAM0_ERR"* ]]; then
				logger -p local0.error "[CHK][$tag:$LINENO] CAM0_ERR : $cam01_res"
				echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
			elif [[ "$cam01_res" == *"$CAM01_ERR"* ]]; then
				logger -p local0.error "[CHK][$tag:$LINENO] CAM01_ERR : $cam01_res"
				echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
				echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
			else
				logger -p local0.error "[CHK][$tag:$LINENO] CAM01_ERR : $cam01_res"
				echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
				echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
			fi
		fi
	#CAM0 ENABLE ONLY
	elif [[ "$cam_ch0" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch1" == *"$DISABLE_VAL"* ]]; then
		if [[ "$cam01_res" == *"$CH0_EN_OK"*  ]]; then
            logger -p local0.debug "[CHK][$tag:$LINENO] CAM0 OK"
        elif [[ "$cam01_res" == *"$CH1_EN_OK"*  ]]; then
            logger -p local0.warn "[CHK][$tag:$LINENO] please swap ch0 and ch1(CAM0 enable but CAM1 display) : $cam01_res"
            #echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log
        else
			logger -p local0.error "[CHK][$tag:$LINENO] CAM0_ERR : $cam01_res"
			echo "${timestamp} CAM0 ERR" >> ${FLAG_PATH}/err_cam0.log	
		fi
    #CAM1 ENABLE ONLY
    elif [[ "$cam_ch0" == *"$DISABLE_VAL"* ]] && [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
        if [[ "$cam01_res" == *"$CH1_EN_OK"*  ]]; then
            logger -p local0.debug "[CHK][$tag:$LINENO] CAM1 OK"
        elif [[ "$cam01_res" == *"$CH0_EN_OK"*  ]]; then
            logger -p local0.warn "[CHK][$tag:$LINENO] please swap ch0 and ch1(CAM1 enable but CAM0 display) : $cam01_res"
            #echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
        else
            logger -p local0.error "[CHK][$tag:$LINENO] CAM1_ERR : $cam01_res"
            echo "${timestamp} CAM1 ERR" >> ${FLAG_PATH}/err_cam1.log
        fi
    else
        logger -p local0.info "[CHK][$tag:$LINENO] CAM0 CAM1 disable"
	fi
	
	#CAM2,CAM3 ENABLE
	if [[ "$cam_ch2" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
		if [[ "$cam23_res" == *"$SUCCESS_VAL"*  ]]; then
			logger -p local0.debug "[CHK][$tag:$LINENO] CAM2 CAM3 OK"
		else
			# Phase 1: read-only retry (no reset write)
			for r in 1 2 3; do
				sleep 0.3
				cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)
				if [[ "$cam23_res" == *"$SUCCESS_VAL"* ]]; then
					logger -p local0.info "[CHK][$tag:$LINENO] CAM2 CAM3 OK (read retry $r)"
					break
				fi
			done

			# Phase 2: reset + read (only if read-only retry failed)
			if [[ "$cam23_res" != *"$SUCCESS_VAL"* ]]; then
				logger -p local0.error "[CHK][$tag:$LINENO] CAM23 read retry failed, reset : $cam23_res"
				i2ctransfer -f -y -a 1 w3@0x48 0x00 0x10 0x31
				i2ctransfer -f -y -a 1 w3@0x40 0x00 0x10 0x21
				sleep 1
				cam23_res=$(i2ctransfer -f -y -a 1 w2@0x48 0x00 0x13 r1)
			fi

			# error classification
			if [[ "$cam23_res" == *"$SUCCESS_VAL"* ]]; then
				logger -p local0.info "[CHK][$tag:$LINENO] CAM2 CAM3 recovered after reset"
			elif [[ "$cam23_res" == *"$CAM3_ERR"* ]]; then
				logger -p local0.error "[CHK][$tag:$LINENO] CAM3_ERR : $cam23_res"
				echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
			elif [[ "$cam23_res" == *"$CAM2_ERR"* ]]; then
				logger -p local0.error "[CHK][$tag:$LINENO] CAM2_ERR : $cam23_res"
				echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
			elif [[ "$cam23_res" == *"$CAM23_ERR"* ]]; then
				logger -p local0.error "[CHK][$tag:$LINENO] CAM23_ERR : $cam23_res"
				echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
				echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
			else
				logger -p local0.error "[CHK][$tag:$LINENO] CAM23_ERR : $cam23_res"
				echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
				echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
			fi
		fi
	#CAM2 ENABLE ONLY
	elif [[ "$cam_ch2" == *"$ENABLE_VAL"* ]] && [[ "$cam_ch3" == *"$DISABLE_VAL"* ]]; then
		if [[ "$cam23_res" == *"$CH2_EN_OK"*  ]]; then
            logger -p local0.debug "[CHK][$tag:$LINENO] CAM2 OK"
        elif [[ "$cam23_res" == *"$CH3_EN_OK"*  ]]; then
            logger -p local0.warn "[CHK][$tag:$LINENO] please swap ch2 and ch3(CAM2 enable but CAM3 display) : $cam23_res"
            #echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
        else
			logger -p local0.error "[CHK][$tag:$LINENO] CAM2_ERR : $cam23_res"
			echo "${timestamp} CAM2 ERR" >> ${FLAG_PATH}/err_cam2.log
		fi
    #CAM3 ENABLE ONLY
    elif [[ "$cam_ch2" == *"$DISABLE_VAL"* ]] && [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
        if [[ "$cam23_res" == *"$CH3_EN_OK"*  ]]; then
            logger -p local0.debug "[CHK][$tag:$LINENO] CAM3 OK"
        elif [[ "$cam23_res" == *"$CH2_EN_OK"*  ]]; then
            logger -p local0.warn "[CHK][$tag:$LINENO] please swap ch2 and ch3(CAM3 enable but CAM2 display) : $cam23_res"
            #echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
        else
            logger -p local0.error "[CHK][$tag:$LINENO] CAM3_ERR : $cam23_res"
            echo "${timestamp} CAM3 ERR" >> ${FLAG_PATH}/err_cam3.log
        fi
    else
        logger -p local0.info "[CHK][$tag:$LINENO] CAM2 CAM3 disable"
	fi
#fi

