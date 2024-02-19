#!/bin/bash

tag=$(basename "$0")
KEY=RST

#list="BG_Check_for_pim.sh restart_app.sh vcm ord vsd"
list="ord vcm vsd"
pid=0
service=0
#app=streamApp
#app=gstApp
sleep 1

JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
app=$(jq -r '.VHL_CAM.app' "$FILE_JSON")
if [ "$app" != "streamApp" ] && [ "$app" != "gstApp" ]; then
    logger -p local0.err "[$KEY][$tag:$LINENO] app : $app"
    logger -p local0.err "[$KEY][$tag:$LINENO] please update json"
    app="streamApp"
    #exit 0
fi


while [ 1 ]; do
    #sleep 2
    pid=$(ps -ef |grep "$app" |grep -v grep |awk '{print $2}')
    if [ -z "$pid" ]; then
        logger -p local0.notice "[$KEY][$tag:$LINENO] $app killed"
        killall -s KILL PIMCAM
        #killall -s KILL BG_Check_for_pim.sh
        logger -p local0.emerg "[$KEY][$tag:$LINENO] start_cam.sh 1"
        /opt/pim/bin/start_cam.sh 1
    fi

    for service in $list; do
        if [ ! -z "$service" ]; then
            #pgrep $service >/dev/null; status=$?
            #sleep 1
            pid=$(ps -ef |grep "$service" |grep -v grep |awk '{print $2}')
            if [ ! -n "$pid" ]; then
                #echo "no" >/dev/null
                #sleep 0.5
                logger -p local0.emerg "[$KEY][$tag:$LINENO] $service start"
                $service &
            fi
        fi
    done

	sleep 3
done

exit 0

