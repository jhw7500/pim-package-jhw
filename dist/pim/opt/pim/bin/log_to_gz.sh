#!/bin/bash
INPUT_PATH=$1
LIMIT_DATE=$2
if [ -z "$INPUT_PATH" ];then
    echo "failed : you should input path"
    exit 1
fi

#echo "========================="
#echo "input path : " $INPUT_PATH

if [ ! -d "$INPUT_PATH" ]; then
    echo "failed : $INPUT_PATH is not directory"
    exit 1
fi

#echo "convert log to gz start"
#echo "========================="

TO_DAY=$(date +"%Y%m%d")

#echo "today is "${TO_DAY}
#echo "========================="

for log in $INPUT_PATH*/*.log
    do
        log_name=${log:(${#INPUT_PATH}+1):-4}
	#echo "log_name:"${log_name}
        #log_name=${log: -12:8}
        #echo "log_name:"${log_name}
        if [ $log_name -lt ${TO_DAY} ]; then

            gzip ${INPUT_PATH}/${log_name}.log
            mv ${INPUT_PATH}/${log_name}.log.gz ${INPUT_PATH}/g${log_name}.log.gz
            #echo "${log_name}.log converted"
            #echo "========================="
        fi

    done

FILE=$(find /var/log/cantops -name *gz)

if [[ "$FILE" == *.log.gz ]]; then
echo "exist"
for gz in $INPUT_PATH*/*.log.gz
    do
	echo $gz
        gz_name=${gz:(${#INPUT_PATH}+2):-7}
        #echo "gz_name:"$gz_name
        #echo "TO_DAY:"$TO_DAY
        day1_epoch=`date "+%s"`
        day2_epoch=`date -d "${gz_name}" "+%s"`
        #echo "epoch1:"${day1_epoch}
        #echo "epoch2:"${day2_epoch}
        date_diff=`echo "(${day1_epoch} - ${day2_epoch})/86400" |bc`
        #echo "date_diff:"$date_diff
        if [[ ${date_diff} -gt ${LIMIT_DATE} ]]; then
            rm ${INPUT_PATH}/g${gz_name}.log.gz
            #echo "rm "g${gz_name}".log.gz"
            #gzip ${INPUT_PATH}/${log_name}.log &\
            #echo "========================="
        fi

    done
fi
