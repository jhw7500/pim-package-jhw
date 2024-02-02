#!/bin/bash
tag=$(basename "$0")
key=RST
iomode=3
opt=0
#app=PIMCAM
#app=gstApp
pid=$(ps -ef |grep vcm |grep -v grep |awk '{print $2}')
if [ ! -n "$pid" ]; then
    logger -p local0.notice "[$key][$tag:$LINENO] kill vcm because srt sync"
    pkill vcm
fi

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
    logger -p local0.crit "[$key][$tag:$LINENO] app : $app"
    exit 0
fi

export GST_DEBUG_NO_COLOR=1
export GST_DEBUG=2,v4l2src:1
export GST_DEBUG_FILE="$GST_LOG_FILE"
export GST_DEBUG_DUMP_DOT_DIR=/var/log/cantops/dot/

logger -p local0.notice "[$key][$tag:$LINENO] start app:$app opt:$opt"
pid=$(ps -ef |grep BG_Check_for_pim.sh |grep -v grep |awk '{print $2}')
if [[ "$opt" == 1 ]]; then
    #logger -p local0.notice "[$key][$tag:$LINENO] $app -d 5 -m $iomode &"
    $app -d 5 -m $iomode &
    if [ ! -n "$pid" ]; then
        logger -p local0.emerg "[$KEY][$tag:$LINENO] BG_Check_for_pim.sh start"
         /opt/pim/bin/BG_Check_for_pim.sh 5 & 2>/dev/null
    fi
    exit 0
fi

ENABLE_VAL=true
cam_ch0=$(jq '.VHL_CAM.cam_ch0' "$FILE_JSON")
cam_ch1=$(jq '.VHL_CAM.cam_ch1' "$FILE_JSON")
cam_ch2=$(jq '.VHL_CAM.cam_ch2' "$FILE_JSON")
cam_ch3=$(jq '.VHL_CAM.cam_ch3' "$FILE_JSON")

if [[ "$cam_ch0" == *"$ENABLE_VAL"* ]] || [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
    #logger -p local0.notice "[$key][$tag:$LINENO] csi1 enable"
    csi1_en=1
fi

if [[ "$cam_ch2" == *"$ENABLE_VAL"* ]] || [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
    #logger -p local0.notice "[$key][$tag:$LINENO] csi2 enable"
    csi2_en=1
fi

if [[ "$csi1_en" -eq 1 ]] && [[ "$csi2_en" -eq 1 ]]; then
    logger -p local0.notice "[$key][$tag:$LINENO] $app -d 25 -m $iomode &"
    $app -d 25 -m $iomode &
    #PIMCAM -d 15 -m $iomode -c 3 &
    if [ ! -n "$pid" ]; then
        logger -p local0.emerg "[$key][$tag:$LINENO] BG_Check_for_pim.sh start"
        /opt/pim/bin/BG_Check_for_pim.sh 25 & 2>/dev/null
    fi
elif [[ "$csi1_en" -eq 1 ]] || [[ "$csi2_en" -eq 1 ]]; then
    logger -p local0.notice "[$key][$tag:$LINENO] $app -d 25 -m $iomode &"
    $app -d 15 -m $iomode &
    if [ ! -n "$pid" ]; then
        logger -p local0.emerg "[$key][$tag:$LINENO] BG_Check_for_pim.sh start"
        /opt/pim/bin/BG_Check_for_pim.sh 15 & 2>/dev/null
    fi
else
    logger -p local0.crit "[$key][$tag:$LINENO] no channels are enabled"
fi

exit 0
