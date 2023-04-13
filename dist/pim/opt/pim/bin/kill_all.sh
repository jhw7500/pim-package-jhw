#!/bin/bash

tag=$(basename "$0")
logger -p local0.notice -t $tag kill_all start
list="BG_Check_for_pim.sh restart_app.sh vcm ord vsd streamApp PIMCAM"
#list="chk_mem.sh"

for service in $list; do
if [ ! -z "$service" ]; then
        while :
        do
		#logger -s -p local0.notice -t $tag [CHK] killall $service
		sudo killall -s KILL $service
	        pgrep "$service" >/dev/null; status=$?
	        if [ "$status" -eq 0 ]; then
                	#pid=$(ps -C $service |grep $service |awk '{print $1}')
                	#echo $service" pid:":${pid}
                	logger -s -p local0.notice -t $tag [CHK] wait for $service kill...
                	#sudo kill -9 $pid
               		#sudo killall -s KILL $service
			sleep 1
		else
			break
        	fi
	done
fi
done

exit $status
