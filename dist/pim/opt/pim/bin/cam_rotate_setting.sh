#!/bin/bash

JSON_PREFIX=edgeconf_
JSON_SUFFIX=.json
TEST_CONFIG_FILE=""
for f in /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX}; do
    [ -e "$f" ] || continue
    if [ -z "$TEST_CONFIG_FILE" ] || [ "$f" -nt "$TEST_CONFIG_FILE" ]; then
        TEST_CONFIG_FILE="$f"
    fi
done
SUCCESS_VAL="true"
FAIL_VAL="error"
result=1;

sleep 15

if [[ ! -s "$TEST_CONFIG_FILE" ]]; then 
	echo "can't find $TEST_CONFIG_FILE"
	result=1 ; 
else
	cam_ch0_en=$(cat $TEST_CONFIG_FILE | grep cam_ch0 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	if [[ "$cam_ch0_en" == *"$SUCCESS_VAL"* ]] ; then
		cam0_rot=$(cat $TEST_CONFIG_FILE | grep cam_ch0_rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
		if [[ "$cam0_rot" == *"$SUCCESS_VAL"* ]] ; then
			i2ctransfer -f -y -a 2 w4@0x11 0x10 0x0c 0x00 0x03         #rotate ch0
			echo "cam_ch0 set rotate $cam0_rot"
		else 
			i2ctransfer -f -y -a 2 w4@0x11 0x10 0x0c 0x00 0x00         #default ch0
			echo "cam_ch0 set rotate $cam0_rot"
		fi
	else
			echo "cam_ch0 disable"
	fi	

	cam_ch1_en=$(cat $TEST_CONFIG_FILE | grep cam_ch1 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	if [[ "$cam_ch1_en" == *"$SUCCESS_VAL"* ]] ; then
		cam1_rot=$(cat $TEST_CONFIG_FILE | grep cam_ch1_rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
		if [[ "$cam1_rot" == *"$SUCCESS_VAL"* ]] ; then
			i2ctransfer -f -y -a 2 w4@0x12 0x10 0x0c 0x00 0x03         #rotate ch1
			echo "cam_ch1 set rotate $cam1_rot"
		else 
			i2ctransfer -f -y -a 2 w4@0x12 0x10 0x0c 0x00 0x00         #default ch1
			echo "cam_ch1 set rotate $cam1_rot"
		fi
	else
			echo "cam_ch1 disable"
	fi	

	cam_ch2_en=$(cat $TEST_CONFIG_FILE | grep cam_ch2 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	if [[ "$cam_ch2_en" == *"$SUCCESS_VAL"* ]] ; then
		cam2_rot=$(cat $TEST_CONFIG_FILE | grep cam_ch2_rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
		if [[ "$cam2_rot" == *"$SUCCESS_VAL"* ]] ; then
			i2ctransfer -f -y -a 1 w4@0x11 0x10 0x0c 0x00 0x03         #rotate ch2
			echo "cam_ch2 set rotate $cam2_rot"
		else 
			i2ctransfer -f -y -a 1 w4@0x11 0x10 0x0c 0x00 0x00         #default ch2
			echo "cam_ch2 set rotate $cam2_rot"
		fi
	else
			echo "cam_ch2 disable"
	fi	

	cam_ch3_en=$(cat $TEST_CONFIG_FILE | grep cam_ch3 | grep -v rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
	if [[ "$cam_ch3_en" == *"$SUCCESS_VAL"* ]] ; then		
		cam3_rot=$(cat $TEST_CONFIG_FILE | grep cam_ch3_rotate | cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n')	
		if [[ "$cam3_rot" == *"$SUCCESS_VAL"* ]] ; then
			i2ctransfer -f -y -a 1 w4@0x12 0x10 0x0c 0x00 0x03         #rotate ch3
			echo "cam_ch3 set rotate $cam3_rot"
		else 
			i2ctransfer -f -y -a 1 w4@0x12 0x10 0x0c 0x00 0x00         #default ch3
			echo "cam_ch3 set rotate $cam3_rot"
		fi
	else
			echo "cam_ch3 disable"
	fi	
	result=0;
fi

if [ $result -eq 1 ]
then
	timestamp=`date +"%Y-%m-%d %T,%3N"`
	echo "$timestamp cam rotation fail"
	exit 1
else
	timestamp=`date +"%Y-%m-%d %T,%3N"`
	echo "$timestamp cam rotation success"	
	exit 0
fi
