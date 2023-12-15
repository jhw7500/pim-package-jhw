#!/bin/bash
KEY=DOT
INPUT_PATH=$1
LIMIT=$2
tag=$(basename "$0")
if [ -z "$INPUT_PATH" ];then
    logger -p local0.crit "[$KEY][$tag:$LINENO] failed : you should input path"
    exit 1
fi

#echo "========================="
#echo "input path : " $INPUT_PATH
logger -p local0.notice "[$KEY][$tag:$LINENO] dot path : $INPUT_PATH, limit : $LIMIT"

if [ ! -d "$INPUT_PATH" ]; then
    logger -p local0.crit "[$KEY][$tag:$LINENO] failed : $INPUT_PATH is not directory"
    exit 1
fi

if [ $LIMIT -le 1 ]; then
    logger -p local0.crit "[$KEY][$tag:$LINENO] failed : LIMIT:$LIMIT greater than 1"
    exit 1
fi

while :
do
cnt=$(ls -lt $1 | grep ^- | wc -l)
if [ $cnt -gt $LIMIT ]; then
    logger -p local0.notice "[$KEY][$tag:$LINENO] dot file cnt $cnt > $LIMIT"
    #ls -pr $INPUT_PATH | grep -v '/$' | tail -n 1 | xargs -t -I %% sh -c '{ rm -f /var/log/cantops/dot/%%; }'
    find /var/log/cantops/dot/ -maxdepth 1 -type f | sort -r | tail -n 1 | head -n 1 | xargs rm -f
fi
sleep 60
done


:<<'END'
#echo "convert log to gz start"
#echo "========================="

TO_DAY=$(date +"%Y%m%d")

#echo "today is "${TO_DAY}
#echo "========================="

for log in $INPUT_PATH*/*.dot; do
        log_name=${log:(${#INPUT_PATH}+11):-12}
        #echo $(($log_name+$LIMIT_DATE))
	    #echo "log_name:"${log_name}
        #log_name=${log: -12:8}
        #echo "log_name:"${log_name}
        if [ $(($log_name+$LIMIT)) -lt ${TO_DAY} ]; then
            logger -p local0.notice "[CHK][$tag:$LINENO] ${log_name} dot file remove" 
            rm ${INPUT_PATH}/*${log_name}*
            #gzip ${INPUT_PATH}/${log_name}.log
            #mv ${INPUT_PATH}/${log_name}.log.gz ${INPUT_PATH}/g${log_name}.log.gz
            #logger -p local0.notice [CHK][$tag:$LINENO] ${log_name}.log converted
        fi
done
END
