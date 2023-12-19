#!/bin/bash
KEY=DOT
INPUT_PATH=$1
LIMIT=$2
tag=$(basename "$0")
cnt=0
tailcnt=0
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

cnt=$(ls -lt $1 | grep ^- | wc -l)
if [ $cnt -gt $LIMIT ]; then
    tailcnt=$(($cnt-$LIMIT))
    logger -p local0.notice "[$KEY][$tag:$LINENO] dot file cnt $cnt > $LIMIT ($tailcnt)"
    #ls -pr $INPUT_PATH | grep -v '/$' | tail -n 1 | xargs -t -I %% sh -c '{ rm -f /var/log/cantops/dot/%%; }'
    find /var/log/cantops/dot/ -maxdepth 1 -type f | sort -r | tail -$tailcnt| xargs rm -f
fi
