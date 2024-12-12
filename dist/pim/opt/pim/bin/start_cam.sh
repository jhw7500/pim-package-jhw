#!/bin/bash
tag=$(basename "$0")
key=RST
#0:auto, 3:userptr, 4:dma
iomode=4
delay=5
#app=PIMCAM
#app=gstApp

CheckApp() {
local pid=$(ps -ef |grep $1 |grep -v grep |awk '{print $2}')
if [ -z "$pid" ]; then
    return 1
else
    return 0
fi
}

StartCam() {
    logger -p local0.notice "[$key][$tag:$LINENO] touch /tmp/kill_flag"
    touch /tmp/kill_flag
    delay=$2
    if [ "$4" = "true" ]; then
        #$1 -d $2 -m $3 &
        if [ "$delay" -ge 15 ]; then
            delay=15
        fi
        start_cmd="gstApp -e 0 -E 0 -N 1 -y 1 -C 0 -a 1 -f 1 -d $delay -m $3 -R 1 &"
    else
        start_cmd="$1 -d $delay -m $3 &"
    fi
    logger -p local0.notice "[$key][$tag:$LINENO] app start : $start_cmd"
    eval "$start_cmd"
    #cgexec -g memory:myappgroup $1 -d $2 -m $3 &
    if ! CheckApp "BG_Check_for_pim.sh"; then
        logger -p local0.emerg "[$key][$tag:$LINENO] BG_Check_for_pim.sh start"
         /opt/pim/bin/BG_Check_for_pim.sh $2 & 2>/dev/null
    fi

    if ! CheckApp "restart_app.sh"; then
        logger -p local0.emerg "[$key][$tag:$LINENO] restart_app start"
        /opt/pim/bin/restart_app.sh &
    fi
    #/opt/pim/bin/cpulimit-all.sh --limit=320 --max-depth=5 -e $1 --watch-interval=1m &
}

if [[ -n "$1" ]]; then
    delay=$1
fi

JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
logger -p local0.notice "[$key][$tag:$LINENO] json_file : $FILE_JSON"
app=$(jq -r '.VHL_CAM.app' "$FILE_JSON")
GST_LOG_FILE="/var/log/cantops/gst/$app_$(date +'%Y%m%d_%H%M%S').log"
cap_en=$(jq -r '.VHL_CAM.capture.enable' "$FILE_JSON")

if [ "$app" = "streamApp" ]; then
    app="PIMCAM"
    GST_LOG_FILE="/var/log/cantops/gst/streamApp_$(date +'%Y%m%d_%H%M%S').log"
elif [ "$app" = "gstApp" ]; then
    app="gstApp"
    GST_LOG_FILE="/var/log/cantops/gst/gstApp_$(date +'%Y%m%d_%H%M%S').log"
else
    logger -p local0.err "[$key][$tag:$LINENO] app : $app"
    logger -p local0.err "[$key][$tag:$LINENO] please update json"
    app="PIMCAM"
    #exit 0
fi

export GST_DEBUG_NO_COLOR=1
export GST_DEBUG=2,v4l2src:2
#export GST_DEBUG=2,*:5
export GST_DEBUG_FILE="$GST_LOG_FILE"
export GST_DEBUG_DUMP_DOT_DIR=/var/log/cantops/dot/

logger -p local0.notice "[$key][$tag:$LINENO] start app:$app delay:$delay"
if CheckApp "$app"; then
    logger -p local0.err "[$key][$tag:$LINENO] $app already existed"
    exit 0
fi

if CheckApp "vcm"; then
    logger -p local0.notice "[$key][$tag:$LINENO] kill vcm because srt sync"
    pkill vcm
fi

if CheckApp "BG_Check_for_pim.sh"; then
    logger -p local0.notice "[$key][$tag:$LINENO] killall -s KILL BG_Check_for_pim.sh"
    #pkill BG_Check_for_pim.sh
    killall BG_Check_for_pim.sh
fi

#logger -p local0.notice "[$key][$tag:$LINENO] $app -d $delay -m $iomode &"
StartCam $app $delay $iomode $cap_en
exit 0

