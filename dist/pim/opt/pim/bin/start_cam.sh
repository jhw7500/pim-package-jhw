#!/bin/bash
tag=$(basename "$0")
key=RST
iomode=0
opt=0
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
    logger -p local0.notice "[$key][$tag:$LINENO] $1 -d $2 -m $3 &"
    $1 -d $2 -m $3 &
    #cgexec -g memory:myappgroup $1 -d $2 -m $3 &
    if ! CheckApp "BG_Check_for_pim.sh"; then
        logger -p local0.emerg "[$key][$tag:$LINENO] BG_Check_for_pim.sh start"
         /opt/pim/bin/BG_Check_for_pim.sh $2 & 2>/dev/null
    fi

    if ! CheckApp "restart_app.sh"; then
        logger -p local0.emerg "[$key][$tag:$LINENO] restart_app start"
        /opt/pim/bin/restart_app.sh &
    fi
}

if [[ -n "$1" ]]; then
    opt=$1
fi

JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} |grep -v '/$' | tail -1 |tr -d '\r\n')
logger -p local0.notice "[$key][$tag:$LINENO] json_file : $FILE_JSON"
app=$(jq -r '.VHL_CAM.app' "$FILE_JSON")
GST_LOG_FILE="/var/log/cantops/gst/$app_$(date +'%Y%m%d_%H%M%S').log"

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

logger -p local0.notice "[$key][$tag:$LINENO] start app:$app opt:$opt"
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

if [[ "$opt" == 1 ]]; then
    #logger -p local0.notice "[$key][$tag:$LINENO] $app -d 5 -m $iomode &"
    StartCam $app 5 $iomode
    exit 0
fi

ENABLE_VAL=true
cam_ch0=$(jq '.VHL_CAM.i2c2.ch0.enable' "$FILE_JSON")
cam_ch1=$(jq '.VHL_CAM.i2c2.ch1.enable' "$FILE_JSON")
cam_ch2=$(jq '.VHL_CAM.i2c1.ch2.enable' "$FILE_JSON")
cam_ch3=$(jq '.VHL_CAM.i2c1.ch3.enable' "$FILE_JSON")

if [[ "$cam_ch0" == *"$ENABLE_VAL"* ]] || [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
    #logger -p local0.notice "[$key][$tag:$LINENO] csi1 enable"
    csi1_en=1
fi

if [[ "$cam_ch2" == *"$ENABLE_VAL"* ]] || [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
    #logger -p local0.notice "[$key][$tag:$LINENO] csi2 enable"
    csi2_en=1
fi

if [[ "$csi1_en" -eq 1 ]] && [[ "$csi2_en" -eq 1 ]]; then
    StartCam $app 25 $iomode
elif [[ "$csi1_en" -eq 1 ]] || [[ "$csi2_en" -eq 1 ]]; then
    StartCam $app 15 $iomode
else
    logger -p local0.crit "[$key][$tag:$LINENO] no channels are enabled"
fi

exit 0
