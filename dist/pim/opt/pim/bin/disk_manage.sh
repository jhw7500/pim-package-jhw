#!/bin/bash
tag=$(basename "$0")
KEY=DSK
logger -p local0.notice [$KEY][$tag:$LINENO] disk_manage.sh start target:$1 size:$2 cnt:$3
mount /dev/mmcblk1p1 $1
#echo disk_manage.sh start target:$1 size:${2} cnt:${3}
#mnt=$(df -h |grep $1 |awk '{print $5}'|sed 's/[^0-9]//g')
#mnt_s=$(df -h |grep /mnt |awk '{print $5}'|sed -r 's/^0+/g')
#int=$((mnt))

while :
do
mnt=$(df -h |grep $1 |awk '{print $5}'|sed 's/[^0-9]//g')
use=$((mnt))
if [ $use -gt $2 ]; then
    logger -p local0.notice "[$KEY][$tag:$LINENO] size $use% > $2%"
    ls -pr /mnt | grep -v '/$' | tail -n 10 | xargs -t -I %% sh -c '{ rm -f /mnt/%%; }'
fi
cnt=$(ls -lt $1 | grep ^- | wc -l)
if [ $cnt -gt $3 ]; then
    logger -p local0.notice "[$KEY][$tag:$LINENO] cnt $cnt > $3"
    ls -pr /mnt | grep -v '/$' | tail -n 10 | xargs -t -I %% sh -c '{ rm -f /mnt/%%; }'
fi

sleep 30
done
