#!/bin/bash

tag=$(basename "$0")
KEY=RST

logger -p local0.notice "[$KEY][$tag:$LINENO] restart_app.sh start"

list="ord vcm vsd"
pid=0
service=0
cam_disable=0
#app=streamApp
#app=gstApp
sleep 1
ENABLE_VAL="true"
DISABLE_VAL="false"
JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
#read app cap_en < <(jq -r '[.VHL_CAM.app, .VHL_CAM.capture.enable] | @tsv' $FILE_JSON)
IFS=$'\t' read -r \
    app cap_en cam_ch0 cam_ch1 cam_ch2 cam_ch3 < <(
    jq -r '[
        (.VHL_CAM.app // "streamApp"),
        (.VHL_CAM.capture.enable // false),
        (.VHL_CAM.i2c2.ch0.enable // false),
        (.VHL_CAM.i2c2.ch1.enable // false),
        (.VHL_CAM.i2c1.ch2.enable // false),
        (.VHL_CAM.i2c1.ch3.enable // false)
    ] | @tsv' "$FILE_JSON"
)
unset IFS

if [ "$app" != "streamApp" ] && [ "$app" != "gstApp" ]; then
    logger -p local0.err "[$KEY][$tag:$LINENO] app : $app"
    logger -p local0.err "[$KEY][$tag:$LINENO] please update json"
    app="streamApp"
    #exit 0
fi

if [ "$cap_en" = "true" ]; then
    app="gstApp"
fi

if [[ "$cam_ch0" != *"$ENABLE_VAL"* ]] && [[ "$cam_ch1" != *"$ENABLE_VAL"* ]] && [[ "$cam_ch0" != *"$ENABLE_VAL"* ]] && [[ "$cam_ch1" != *"$ENABLE_VAL"* ]]; then
    cam_disable=1
fi

while [ 1 ]; do
    if [ -f /tmp/init_cam_flag ] || [ -f /tmp/restart_flag ]; then
        sleep 3
        continue
    fi

    for service in $list; do
        if [ ! -z "$service" ]; then
            #pgrep $service >/dev/null; status=$?
            #sleep 1
            pid=$(ps -ef |grep "$service" |grep -v grep |awk '{print $2}')
            if [ ! -n "$pid" ]; then
                #echo "no" >/dev/null
                #sleep 0.5
                logger -p local0.notice "[$KEY][$tag:$LINENO] $service start"
                $service &
            fi
        fi
    done

    if [ "$cam_disable" -eq 1 ]; then
        sleep 3
        continue
    fi

    pid=$(ps -ef |grep "$app" |grep -v grep |awk '{print $2}')
    if [ -z "$pid" ]; then
        logger -p local0.notice "[$KEY][$tag:$LINENO] $app killed"
        killall -s KILL PIMCAM
        #killall -s KILL BG_Check_for_pim.sh
        logger -p local0.notice "[$KEY][$tag:$LINENO] start_cam.sh"
        /opt/pim/bin/start_cam.sh
    fi

	sleep 3
done
logger -p local0.notice "[$KEY][$tag:$LINENO] restart_app.sh end"

exit 0

