#!/bin/sh

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
                echo $service" pid:":${pid}
		if [ "$pid" -ne 0 ]; then
                	logger -p local0.notice -t $service [SYS] kill $service
                	sudo kill -9 $pid
			sleep 1
		fi
			break
	done
fi
done

/opt/pim/bin/vcm &
/usr/bin/PIMCAM -j /root/shared_v/edgeconf_pim.json &

exit "$status"
