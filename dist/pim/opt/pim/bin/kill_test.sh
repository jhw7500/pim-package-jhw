#!/bin/bash

#service=$1
#logger -s -t 'sh   ' streamApp PIMCAM vcm 
tag=$(basename "$0")
KEY=RST
logger -p local0.notice "[$KEY][$tag:$LINENO] kill_test.sh start"
pid=0
cnt=0
service=0
touch /tmp/kill_flag
limitcnt=5
rebootcnt=10
defunct=0

#list="BG_Check_for_pim.sh vcm streamApp PIMCAM"
#list="BG_Check_for_pim.sh vcm gstApp"
list="BG_Check_for_pim.sh vcm "

JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
app=$(jq -r '.VHL_CAM.app' "$FILE_JSON")
if [ "$app" == "streamApp" ]; then
    list+="streamApp PIMCAM"
elif [ "$app" == "gstApp" ]; then
    list+="gstApp"
else
    logger -p local0.crit "[$KEY][$tag:$LINENO] app : $app"
    exit 0
fi

if [[ -n "$1" ]]; then
    opt=$1
else
    opt=0
fi

if [[ "$opt" -ge 1 ]]; then
    #list="BG_Check_for_pim.sh restart_app.sh ord vcm gstApp"
    if [[ "$opt" -ge 2 ]]; then
        systemctl restart cam-operate
    fi
fi

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
    if [ ! -z "$service" ]; then
    logger -p local0.notice "[$KEY][$tag:$LINENO] killall $service"
    sudo killall $service
    cnt=0
        while :
        do
            #sudo killall $service
            pid=$(ps -ef |grep $service |grep -v grep |awk '{print $2}')
            if [ -n "$pid" ]; then
                if [ "$cnt" -ge "$limitcnt" ]; then
                    logger -p local0.notice "[$KEY][$tag:$LINENO] $limitcnt sec($cnt) over!"
                    #defunct=$(ps -ef |grep defunct | grep -v grep)
                    #logger -p local0.notice [$KEY][$tag:$LINENO] $defunct
                    #umount /mnt/sd_cam
                    #defunct=$(ps -ef | grep defunct | grep -v grep | awk '{print $3}' | xargs -t -I % sh -c '{ cat /proc/%/status |grep Name; }')
                    defunct=$(ps -ef | grep $service | grep defunct | awk '{print $8}')
                    logger -p local0.err "[$KEY][$tag:$LINENO] defunct : $defunct"
                    if [ -z "$defunct" ]; then
                        #logger -p local0.err "[$KEY][$tag:$LINENO] no defunct"
                        #sleep 1
                        #reboot
                        logger -p local0.err "[$KEY][$tag:$LINENO] killall $service"
                        killall -s KILL $service
                    else
                        logger -p local0.emerg "[$KEY][$tag:$LINENO] kill -9 $pid($service)"
                        kill -9 $pid
                    fi

                    #defunct=$(ps -ef | grep defunct | grep -v grep | awk '{print $3}' | xargs -t -I % sh -c '{ cat /proc/%/status |grep Name |awk '{print $2}'; }')
                    pid=$(ps -ef | grep defunct | grep -v grep | awk '{print $3}')
                    defunct=$(cat /proc/$pid/status |grep Name |awk '{print $2}')
                    logger -p local0.err "[$KEY][$tag:$LINENO] defunct : $defunct"
                    if [ -n "$defunct" ]; then
                        logger -p local0.emerg "[$KEY][$tag:$LINENO] kill -9 $pid($defunct)"
                        kill -9 $pid 
                        #ps -ef | grep defunct | grep -v grep | awk '{print $3}' | xargs kill -9
                    fi

                    if [ "$cnt" -ge "$rebootcnt" ]; then
                        logger -p local0.emerg "[$KEY][$tag:$LINENO] creboot because doesn't kill"
                        sleep 1
                        creboot
                    fi
                    #((cnt++))
                    #break
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

logger -p local0.notice "[$KEY][$tag:$LINENO] kill_test.sh end"
#/opt/pim/bin/vcm &
exit 0

