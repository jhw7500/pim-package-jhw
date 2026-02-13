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
    logger -p local0.info "[$key][$tag:$LINENO] set kill_flag"
    touch /tmp/kill_flag
    delay=$2
    start_cmd="$1 -d $delay -m $3 &"

    if ! CheckApp "$1"; then
        # Recovery ownership: do not run init_cam.sh here.
        # Let chk_cam_operate.sh handle retry/init/reboot decisions.
        if [ -f /tmp/gst_err ]; then
            logger -p local0.err "[$key][$tag:$LINENO] request init_cam because gst_err"
            touch /tmp/recover_req_init_cam
            rm -f /tmp/gst_err
        fi

        date +%s > /tmp/pim_cam_start_ts 2>/dev/null
        printf "%s" "$delay" > /tmp/pim_cam_start_delay 2>/dev/null

        logger -p local0.emerg "[$key][$tag:$LINENO] cam app cmd : $start_cmd"
        rm /tmp/start_video_time
        eval "$start_cmd"
    else
        logger -p local0.notice "[$key][$tag:$LINENO] alreay start $1"
    fi

    #cgexec -g memory:myappgroup $1 -d $2 -m $3 &
    if ! CheckApp "BG_Check_for_pim.sh"; then
        logger -p local0.info "[$key][$tag:$LINENO] BG_Check_for_pim.sh start"
         /opt/pim/bin/BG_Check_for_pim.sh $2 & 2>/dev/null
    else
        logger -p local0.info "[$key][$tag:$LINENO] alreay start BG_Check_for_pim.sh"
    fi

    if ! CheckApp "restart_app.sh"; then
        logger -p local0.info "[$key][$tag:$LINENO] restart_app start"
        /opt/pim/bin/restart_app.sh &
    else
        logger -p local0.info "[$key][$tag:$LINENO] alreay start restart_app.sh"
    fi
    #/opt/pim/bin/cpulimit-all.sh --limit=320 --max-depth=5 -e $1 --watch-interval=1m &
}

if [[ -n "$1" ]]; then
    delay=$1
fi

JSON_PREFIX=edgeconf_
JOSN_SUFFIX=.json
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
logger -p local0.info "[$key][$tag:$LINENO] json_file : $FILE_JSON"
GST_LOG_FILE="/var/log/cantops/gst/$app_$(date +'%Y%m%d_%H%M%S').log"

#read app cap_en tmp_path < <(jq -r '[.VHL_CAM.app, .VHL_CAM.capture.enable, .VHL_CAM.tmp_path] | @tsv' $FILE_JSON)

IFS=$'\t' read -r \
    app cap_en tmp_path < <(
    jq -r '[
        (.VHL_CAM.app // "streamApp"),
        (.VHL_CAM.capture.enable // false),
        (.VHL_CAM.tmp_path // "/dev/shm")
    ] | @tsv' "$FILE_JSON"
)
unset IFS

if [ "$app" = "streamApp" ]; then
    app="PIMCAM"
fi

if [ "$cap_en" = "true" ]; then
    app="gstApp"
fi

if [ "$app" != "PIMCAM" ] && [ "$app" != "gstApp" ]; then
    logger -p local0.crit "[$key][$tag:$LINENO] app : $app"
    logger -p local0.crit "[$key][$tag:$LINENO] please update json"
    #app="PIMCAM"
    exit 0
fi

GST_LOG_FILE="/var/log/cantops/gst/$app_$(date +'%Y%m%d_%H%M%S').log"
export GST_DEBUG_NO_COLOR=1
export GST_DEBUG=2,v4l2src:2
#export GST_DEBUG=2,*:5
export GST_DEBUG_FILE="$GST_LOG_FILE"
export GST_DEBUG_DUMP_DOT_DIR=/var/log/cantops/dot/
#export GST_TRACERS="latency"
#export GST_DEBUG="GST_TRACER:7"
#export GST_DEBUG_FILE=/tmp/gst-latency.log

logger -p local0.info "[$key][$tag:$LINENO] start app:$app delay:$delay file_path:$tmp_path"
if CheckApp "$app"; then
    logger -p local0.err "[$key][$tag:$LINENO] $app already existed"
    exit 0
fi

#if CheckApp "init_cam.sh"; then
#    logger -p local0.err "[$key][$tag:$LINENO] init_cam.sh already existed"
#    exit 0
#fi

if CheckApp "kill_test.sh"; then
    logger -p local0.err "[$key][$tag:$LINENO] kill_test.sh already existed"
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

#if [ -f /tmp/sd_mount_flag ]; then
#    logger -p local0.err "[$key][$tag:$LINENO] not excute $app because sd card cannot mount!"
#    exit 0
#fi

#logger -p local0.notice "[$key][$tag:$LINENO] $app -d $delay -m $iomode &"
StartCam $app $delay $iomode $cap_en
exit 0
