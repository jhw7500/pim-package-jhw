#!/bin/bash

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
tag=$(basename "$0")
KEY=RST

logger -p local0.notice "[$KEY][$tag:$LINENO] kill_test.sh start"

if [ -f /tmp/restart_flag ]; then
    logger -p local0.notice "[RST][$tag:$LINENO] exit because already kill app..."
    exit 0
fi

touch /tmp/restart_flag
#touch /tmp/kill_flag
pid=0
cnt=0
service=0
limitcnt=5
rebootcnt=30
defunct=0

#FILE_CHECK="/tmp/file_check"
#echo "ING" > $FILE_CHECK

#list="BG_Check_for_pim.sh vcm streamApp PIMCAM"
#list="BG_Check_for_pim.sh vcm gstApp"
list="BG_Check_for_pim.sh vcm"

JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
#list+=" gstApp streamApp PIMCAM"
#:<<'END'
app=$(jq -r '.VHL_CAM.app' "$FILE_JSON")
cap_en=$(jq -r '.VHL_CAM.capture.enable' "$FILE_JSON")
if [ "$cap_en" == "true" ]; then
    list+=" gstApp"
elif [ "$app" == "streamApp" ]; then
    list+=" streamApp PIMCAM"
elif [ "$app" == "gstApp" ]; then
    list+=" gstApp"
else
    logger -p local0.err "[$KEY][$tag:$LINENO] app : $app"
    logger -p local0.err "[$KEY][$tag:$LINENO] please update json"
    list+=" streamApp PIMCAM gstApp"
    #exit 0
fi
#END

logger -p local0.notice "[$KEY][$tag:$LINENO] service : $list"
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
            if [ -n "$pid" ]; then
                if [ "$cnt" -ge "$rebootcnt" ]; then
                    logger -p local0.emerg "[$KEY][$tag:$LINENO] reboot because doesn't kill"
                    sleep 1
                    #creboot
                    reboot
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
tmp_path=$(jq -r '.VHL_CAM.tmp_path' "$FILE_JSON")
mnt_path="/mnt/sd_cam"
if [ "$tmp_path" == "$mnt_path" ]; then
    file_date=$(date "+%Y%m%d_%H%M00")
    logger -p local0.notice "[$KEY][$tag:$LINENO] rm $mnt_path/${vhl_name}_${file_date}*"
    rm $mnt_path/${vhl_name}_${file_date}*
else
    logger -p local0.notice "[$KEY][$tag:$LINENO] rm $tmp_path/${vhl_name}*"
    rm $tmp_path/${vhl_name}*
fi

logger -p local0.notice "[$KEY][$tag:$LINENO] touch /tmp/kill_flag, rm /tmp/restart_flag"
touch /tmp/kill_flag
rm /tmp/restart_flag

logger -p local0.notice "[$KEY][$tag:$LINENO] kill_test.sh end"
#/opt/pim/bin/vcm &
exit 0

