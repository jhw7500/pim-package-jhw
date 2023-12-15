#!/bin/bash

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
tag=$(basename "$0")
KEY=RST
logger -p local0.notice [$KEY][$tag:$LINENO] kill_test.sh start
#list="BG_Check_for_pim.sh vcm streamApp PIMCAM"
list="BG_Check_for_pim.sh vcm streamApp PIMCAM"

touch /tmp/kill_flag

:<<'END'
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
END

limitcnt=5
rebootcnt=10
for service in $list; do
    if [ ! -z "$service" ]; then
    logger -p local0.notice [CHK][$tag:$LINENO] $service
    cnt=0
        while :
        do
            sudo killall $service
            pid=$(ps -ef |grep $service |grep -v grep |awk '{print $2}')
            if [ -n "$pid" ]; then
                if [ "$cnt" -ge "$limitcnt" ]; then
                    logger -p local0.notice [$KEY][$tag:$LINENO] $limitcnt sec over!
                    #logger -p local0.emerg "[$KEY][$tag:$LINENO] reboot.."
                    defunct=$(ps -ef |grep defunct | grep -v grep)
                    logger -p local0.notice [$KEY][$tag:$LINENO] $defunct
                    umount /mnt/sd_cam
                    if [ -z "$defunct" ]; then
                        #logger -p local0.emerg "[$KEY][$tag:$LINENO] normal reboot.."
                        #sleep 1
                        #reboot
                        logger -p local0.emerg "[$KEY][$tag:$LINENO] killall -s KILL $service"
                        sudo killall -s KILL $service
                    else
                        logger -p local0.emerg "[$KEY][$tag:$LINENO] killall -s KILL $service because zombie"
                        #sleep 1
                        #reboot -f
                        sudo killall -s KILL $service
                    fi

                    if [ "$cnt" -ge "$rebootcnt" ]; then
                        logger -p local0.emerg "[$KEY][$tag:$LINENO] reboot because doesn't kill"
                        sleep 1
                        reboot
                    fi
                    #((cnt++))
                    #break
                else
                    #pid=$(ps -C $service |grep $service |awk '{print $1}')
                    #echo $service" pid:":${pid}
                    logger -s -p local0.notice [$KEY][$tag:$LINENO] $cnt wait for $service kill...
                    #sudo kill -9 $pid
                    #sudo killall -s KILL $service
                    #sleep 1
                    #((cnt++))
                fi

                sleep 1
                ((cnt++))
            else
                break
            fi
        done
    fi
done

logger -p local0.notice [$KEY][$tag:$LINENO] kill_test.sh end
#/opt/pim/bin/vcm &
exit 0

