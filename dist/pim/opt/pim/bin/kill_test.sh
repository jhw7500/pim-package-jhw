#!/bin/bash

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
tag=$(basename "$0")
KEY=RST
logger -p local0.notice [$KEY][$tag:$LINENO] kill_test.sh start
#list="BG_Check_for_pim.sh vcm streamApp PIMCAM"
list="BG_Check_for_pim.sh vcm streamApp PIMCAM"

touch /tmp/kill_flag
for service in $list; do
#logger -p local0.notice [$KEY][$tag:$LINENO] $service 
if [ ! -z "$service" ]; then
	#pgrep "$service" >/dev/null; status=$?
	#echo $service:$status
	#if [ "$status" -eq 0 ]; then
		#pid=$(ps -C $service |grep $service |awk '{print $1}')
		#echo $service" pid:":${pid}
		logger -p local0.notice "[$KEY][$tag:$LINENO] kill $service"
		#sudo kill -9 $pid
		sudo killall -s KILL $service
	#fi
fi
done
logger -p local0.notice [$KEY][$tag:$LINENO] kill_test.sh end
#/opt/pim/bin/vcm &
exit 0
