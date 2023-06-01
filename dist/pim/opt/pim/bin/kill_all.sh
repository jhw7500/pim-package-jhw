#!/bin/bash

tag=$(basename "$0")
list="BG_Check_for_pim.sh restart_app.sh vcm streamApp PIMCAM"
#list="chk_mem.sh"
limitcnt=20
KEY=RST

logger -p local0.notice [CHK][$tag:$LINENO] kill_all start
touch /tmp/kill_flag
for service in $list; do
if [ ! -z "$service" ]; then
    logger -p local0.notice [CHK][$tag:$LINENO] $service
	cnt=0
        while :
        do
		    sudo killall -s KILL $service
	        #pgrep "$service" >/dev/null; status=$?
	        #if [ "$status" -eq 0 ]; then
            pid=$(ps -ef |grep $service |grep -v grep |awk '{print $2}')
            if [ -n "$pid" ]; then
			if [ "$cnt" -ge "$limitcnt" ]; then
				logger -p local0.notice [$KEY][$tag:$LINENO] $limitcnt sec over! 
                #logger -p local0.emerg "[$KEY][$tag:$LINENO] reboot.."
                defunct=$(ps -ef |grep defunct | grep -v grep)
                logger -p local0.notice [$KEY][$tag:$LINENO] $defunct
                umount /mnt/sd_cam
                if [ -z "$defunct" ]; then
                    logger -p local0.emerg "[$KEY][$tag:$LINENO] normal reboot.."
                    sleep 1
                    reboot
                else
                    logger -p local0.emerg "[$KEY][$tag:$LINENO] force reboot because zombie"
				    sleep 1
                    reboot -f
                fi
                break
			else
                		#pid=$(ps -C $service |grep $service |awk '{print $1}')
                		#echo $service" pid:":${pid}
                		logger -s -p local0.notice [$KEY][$tag:$LINENO] $cnt wait for $service kill...
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
logger -p local0.notice [CHK][$tag:$LINENO] kill_all end

exit $status
