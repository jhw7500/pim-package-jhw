#!/bin/bash

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
list="restart_app vcm ord vsd streamApp PIMCAM"
tag=$(basename "$0")
for service in $list; do
if [ ! -z "$service" ]; then
	while :
	do
		#status=$(pgrep "$service")
                #pid=$(ps -C $service |grep $service |awk '{print $1}')
		pid=$(ps -ef |grep $service |grep -v grep |awk '{print $2}')
		#echo $service" pid:"$pid
		if [ -n "$pid" ]; then
			echo $service" pid:"${pid}
                	logger -p local0.notice [CHK][$tag:$LINENO] kill $service
                	#sudo kill -9 $pid
			sudo killall -9 $service
			#sleep 0.5
			#break
		fi
			break
	done
fi
done


exit 0
