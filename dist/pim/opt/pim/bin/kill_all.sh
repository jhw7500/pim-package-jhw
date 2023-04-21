#!/bin/bash

tag=$(basename "$0")
logger -p local0.notice [CHK][$tag:$LINENO] kill_all start
list="BG_Check_for_pim.sh restart_app.sh vcm ord vsd streamApp PIMCAM"
#list="chk_mem.sh"
limitcnt=20
key=CHK
for service in $list; do
if [ ! -z "$service" ]; then
	cnt=0
        while :
        do
		sudo killall -s KILL $service
	        pgrep "$service" >/dev/null; status=$?
	        if [ "$status" -eq 0 ]; then
			if [ "$cnt" -ge "$limitcnt" ]; then
				logger -p local0.notice [$key][$tag:$LINENO] $limitcnt sec over! 
                logger -p local0.emerg "[$key][$tag:$LINENO] reboot.."
				reboot
                break
			else
                		#pid=$(ps -C $service |grep $service |awk '{print $1}')
                		#echo $service" pid:":${pid}
                		logger -s -p local0.notice [$key][$tag:$LINENO] $cnt wait for $service kill...
                		#sudo kill -9 $pid
               			#sudo killall -s KILL $service
				sleep 1
				((cnt++))
			fi
		else
			break
        	fi
	done
fi
done


exit $status
