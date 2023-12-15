#!/bin/bash
FLAG_PATH="/tmp"
ERR_CNT="ping_err_cnt"
tag=$(basename "$0")
_success_value=" 0% packet loss"
timestamp=`date +"%Y-%m-%d %T,%3N"`
MAX_CNT=2

ETH1_PING=$(ping 199.10.100.20 -c 3 -W 3 -s 1000)

function err_count_check(){
	if [ -e ${FLAG_PATH}/"$ERR_CNT" ]; then
		old_w_count=$(cat ${FLAG_PATH}/$ERR_CNT)
		rm ${FLAG_PATH}/"$ERR_CNT"
		new_w_count=$(expr $old_w_count + 1);
		echo $new_w_count >> ${FLAG_PATH}/"$ERR_CNT"
	else
		echo 1 > ${FLAG_PATH}/"$ERR_CNT"
	fi
}

if [[ $ETH1_PING != *"$_success_value"* ]]; then
	#ping fail
	#logger -p local0.debug [CHK][$tag:$LINENO] ETH1 199.10.100.20 PING ERR	
	err_count_check
	err_count=$(cat ${FLAG_PATH}/$ERR_CNT)	
	if [[ $(echo "$err_count > $MAX_CNT" | bc) -eq 1 ]]; then
		echo "${timestamp} ETH1 PING ERR" >> ${FLAG_PATH}/err_eth1.log
		logger -p local0.error [CHK][$tag:$LINENO] ETH1 199.10.100.20 PING ERR 3TIME	
		echo $MAX_CNT > ${FLAG_PATH}/"$ERR_CNT"
	fi
else	
	#ping success
	if [ -e ${FLAG_PATH}/"$ERR_CNT" ]; then
		rm ${FLAG_PATH}/"$ERR_CNT" 
	fi
	if [ -e ${FLAG_PATH}/err_eth1.log ]; then
		rm ${FLAG_PATH}/err_eth1.log
	fi
fi	
