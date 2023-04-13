#!/bin/bash

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
tag=$(basename "$0")
logger -p local0.notice -t $tag kill_test.sh start

list="BG_Check_for_pim.sh vcm streamApp PIMCAM"

for service in $list; do
if [ ! -z "$service" ]; then
	#pgrep "$service" >/dev/null; status=$?
	#echo $service:$status
	#if [ "$status" -eq 0 ]; then
		#pid=$(ps -C $service |grep $service |awk '{print $1}')
		#echo $service" pid:":${pid}
		logger -p local0.notice -t $tag [SYS] killall $service
		#sudo kill -9 $pid
		sudo killall -s KILL $service
	#fi
fi

done
#/opt/pim/bin/vcm &
exit "$status"
