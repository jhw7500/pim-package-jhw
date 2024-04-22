#!/bin/bash

tag=$(basename "$0")
list="BG_Check_for_pim.sh restart_app.sh vcm ord vsd streamApp gstApp PIMCAM"
#list="chk_mem.sh"
limitcnt=20
KEY=RST
pid=0
cnt=0
defunct=0
service=0

logger -p local0.notice "[CHK][$tag:$LINENO] kill_all start"
touch /tmp/restart_flag
touch /tmp/kill_flag

for service in $list; do
    cnt=0
    if [ ! -z "$service" ]; then
        logger -p local0.notice "[$KEY][$tag:$LINENO] kill $service"
        pid=$(ps -ef |grep $service |grep -v grep |awk '{print $2}')
        #sudo pkill $service
        if [ -n "$pid" ]; then
            kill $pid
        else
            continue
        fi

        while :
        do
            #sudo killall $service
            pid=$(ps -ef |grep $service |grep -v grep |awk '{print $2}')
            echo $service
            if [ -n "$pid" ]; then
                if [ "$cnt" -ge "$rebootcnt" ]; then
                    logger -p local0.emerg "[$KEY][$tag:$LINENO] creboot because doesn't kill"
                    sleep 1
                    creboot
                elif [ "$cnt" -ge "$limitcnt" ]; then
                    logger -p local0.notice "[$KEY][$tag:$LINENO] $limitcnt sec($cnt) over!"
                    #defunct=$(ps -ef |grep defunct | grep -v grep)
                    #logger -p local0.notice [$KEY][$tag:$LINENO] $defunct
                    #umount /mnt/sd_cam
                    #defunct=$(ps -ef | grep defunct | grep -v grep | awk '{print $3}' | xargs -t -I % sh -c '{ cat /proc/%/status |grep Name; }')
                    defunct=$(ps -ef | grep $service | grep defunct | awk '{print $8}')
                    #logger -p local0.err "[$KEY][$tag:$LINENO] defunct : $defunct"
                    if [ -z "$defunct" ]; then
                        logger -p local0.notice "[$KEY][$tag:$LINENO] no defunct"
                        #sleep 1
                        #reboot
                        #logger -p local0.err "[$KEY][$tag:$LINENO] killall $service"
                        #killall -s KILL $service
                        if [ "$cnt" -ge 15 ]; then
                            logger -p local0.emerg "[$KEY][$tag:$LINENO] kill -9 $pid($service)"
                            kill -9 $pid
                        fi
                    else
                        logger -p local0.err "[$KEY][$tag:$LINENO] defunct : $defunct"
                        logger -p local0.emerg "[$KEY][$tag:$LINENO] kill -9 $pid($service)"
                        kill -9 $pid
                    fi
                fi

                sleep 1
                ((cnt++))
                #pid=$(ps -C $service |grep $service |awk '{print $1}')
                #echo $service" pid:":${pid}
                logger -s -p local0.notice "[$KEY][$tag:$LINENO] $cnt wait for killing $service..."
                #sudo kill -9 $pid
                #sudo killall -s KILL $service
                #sleep 1
                #((cnt++))
            else
                break
            fi
        done
    fi
done
vhl_name=$(jq -r '.VHL_CAM.vhl_name' "$FILE_JSON")
file_date=$(date "+%Y%m%d_%H%M00")
logger -p local0.notice "[$KEY][$tag:$LINENO] rm /mnt/sd_cam/${vhl_name}_${file_date}*"
rm /mnt/sd_cam/${vhl_name}_${file_date}*
rm /tmp/restart_flag

logger -p local0.notice "[CHK][$tag:$LINENO] kill_all end"
exit 0
