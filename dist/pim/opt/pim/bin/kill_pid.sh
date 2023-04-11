#!/bin/bash

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
list="vcm streamApp PIMCAM"
tag=$(basename "$0")
for service in $list; do
if [ ! -z "$service" ]; then
	while :
	do
		#status=$(pgrep "$service")
                pid=$(ps -C $service |grep $service |awk '{print $1}')
		if [ -n "$pid" ]; then
			echo $service" pid:":${pid}
                	logger -p local0.notice -t $service [SYS] kill $service
                	sudo kill -9 $pid
			sleep 0.5
		fi
			break
	done
fi
done


exit 0
