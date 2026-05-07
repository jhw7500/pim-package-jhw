#!/bin/bash

tag=$(basename "$0")
KEY=RST

BG_FLAG_FILE="/tmp/bg_chk_flag.bin"
RESTART_GRACE_SEC=12
RESTART_GRACE_MAX_BYPASS=2

get_cam_disconnect_flag() {
    local v
    v=$(cat "$BG_FLAG_FILE" 2>/dev/null | tr -d '\n')
    if [[ ! "$v" =~ ^[0-9]+$ ]]; then
        echo 0
        return 0
    fi
    echo $((v & 0xf))
}

has_video_node() {
    local node_idx
    for node_idx in 3 4; do
        if [ -e "/dev/video$node_idx" ]; then
            return 0
        fi
    done
    return 1
}

is_subdev_ctrl_ready() {
    local tried=0
    local csi0_node="/dev/v4l-subdev${csi0_subdev}"
    local csi1_node="/dev/v4l-subdev${csi1_subdev}"

    if ! command -v v4l2-ctl >/dev/null 2>&1; then
        logger -p local0.warning "[$KEY][$tag:$LINENO] v4l2-ctl not found; skip subdev ctrl gate"
        return 0
    fi

    if [[ "$cam_ch0" == *"$ENABLE_VAL"* ]]; then
        tried=1
        v4l2-ctl -d "$csi0_node" --get-ctrl=ae_on_ch0 >/dev/null 2>&1 && return 0
    fi
    if [[ "$cam_ch1" == *"$ENABLE_VAL"* ]]; then
        tried=1
        v4l2-ctl -d "$csi0_node" --get-ctrl=ae_on_ch1 >/dev/null 2>&1 && return 0
    fi
    if [[ "$cam_ch2" == *"$ENABLE_VAL"* ]]; then
        tried=1
        v4l2-ctl -d "$csi1_node" --get-ctrl=ae_on_ch2 >/dev/null 2>&1 && return 0
    fi
    if [[ "$cam_ch3" == *"$ENABLE_VAL"* ]]; then
        tried=1
        v4l2-ctl -d "$csi1_node" --get-ctrl=ae_on_ch3 >/dev/null 2>&1 && return 0
    fi

    if [ "$tried" -eq 0 ]; then
        return 0
    fi

    return 1
}

logger -p local0.info "[$KEY][$tag:$LINENO] restart_app.sh start"

list="vcm ord"
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
    app cap_en cam_ch0 cam_ch1 cam_ch2 cam_ch3 csi0_subdev csi1_subdev < <(
    jq -r '[
        (.VHL_CAM.app // "gstApp"),
        (.VHL_CAM.capture.enable // false),
        (.VHL_CAM.i2c2.ch0.enable // false),
        (.VHL_CAM.i2c2.ch1.enable // false),
        (.VHL_CAM.i2c1.ch2.enable // false),
        (.VHL_CAM.i2c1.ch3.enable // false),
        (.VHL_CAM.v4l_map.csi0_subdev // .VHL_CAM.v4l_map.csi0_video // .VHL_CAM.device_map.csi0_subdev // .VHL_CAM.device_map.csi0_video // 2),
        (.VHL_CAM.v4l_map.csi1_subdev // .VHL_CAM.v4l_map.csi1_video // .VHL_CAM.device_map.csi1_subdev // .VHL_CAM.device_map.csi1_video // 3)
    ] | @tsv' "$FILE_JSON"
)
unset IFS

csi0_subdev=${csi0_subdev:-2}
csi1_subdev=${csi1_subdev:-3}

if [ "$app" != "streamApp" ] && [ "$app" != "gstApp" ]; then
    logger -p local0.err "[$KEY][$tag:$LINENO] app : $app"
    logger -p local0.err "[$KEY][$tag:$LINENO] please update json"
    app="gstApp"
    #exit 0
fi

if [ "$cap_en" = "true" ]; then
    app="gstApp"
fi

if [[ "$cam_ch0" != *"$ENABLE_VAL"* ]] && [[ "$cam_ch1" != *"$ENABLE_VAL"* ]] && [[ "$cam_ch2" != *"$ENABLE_VAL"* ]] && [[ "$cam_ch3" != *"$ENABLE_VAL"* ]]; then
    cam_disable=1
fi

fail_cnt=0
restart_grace_until=0
restart_grace_uses=0
while [ 1 ]; do
if [ -f /tmp/init_cam_flag ] || [ -f /tmp/restart_flag ]; then
if [ -f /tmp/restart_flag ]; then
    restart_grace_until=$(( $(date +%s) + RESTART_GRACE_SEC ))
    restart_grace_uses=0
fi
sleep 3
    continue
    fi

for service in $list; do
if [ ! -z "$service" ]; then
pid=$(ps -ef |grep "$service" |grep -v grep |awk '{print $2}')
if [ ! -n "$pid" ]; then
    logger -p local0.info "[$KEY][$tag:$LINENO] $service start"
$service &
fi
fi
sleep 1
done

if [ "$cam_disable" -eq 1 ]; then
sleep 3
    continue
fi

    cam_disconnect_flag=$(get_cam_disconnect_flag)
        if (( cam_disconnect_flag != 0 )); then
        dc_chs=""
        (( cam_disconnect_flag & 1 )) && dc_chs="${dc_chs}ch0 "
        (( cam_disconnect_flag & 2 )) && dc_chs="${dc_chs}ch1 "
        (( cam_disconnect_flag & 4 )) && dc_chs="${dc_chs}ch2 "
        (( cam_disconnect_flag & 8 )) && dc_chs="${dc_chs}ch3 "
        logger -p local0.info "[$KEY][$tag:$LINENO] skip $app restart because cam disconnect(${dc_chs% })"
        sleep 10
        continue
fi

pid=$(ps -ef |grep "$app" |grep -v grep |awk '{print $2}')
if [ -z "$pid" ]; then
        can_start=0
        if has_video_node; then
            if is_subdev_ctrl_ready; then
                can_start=1
            else
                now_ts=$(date +%s)
                if [ "$now_ts" -le "$restart_grace_until" ]; then
                    if [ "$restart_grace_uses" -lt "$RESTART_GRACE_MAX_BYPASS" ]; then
                        restart_grace_uses=$((restart_grace_uses + 1))
                        logger -p local0.notice "[$KEY][$tag:$LINENO] bypass subdev ctrl gate during restart grace ($restart_grace_uses/$RESTART_GRACE_MAX_BYPASS)"
                        can_start=1
                    fi
                fi
            fi
        fi

        if [ "$can_start" -eq 0 ]; then
            logger -p local0.err "[$KEY][$tag:$LINENO] skip $app start: No responding camera hardware found."
            sleep 10
            continue
        fi

        ((fail_cnt++))
        if [ "$fail_cnt" -gt 5 ]; then
        logger -p local0.err "[$KEY][$tag:$LINENO] $app consecutive fail limit ($fail_cnt). Requesting hardware reset..."
    sleep 30
    fail_cnt=0
        continue
        fi

        logger -p local0.info "[$KEY][$tag:$LINENO] $app killed (fail_cnt:$fail_cnt)"
        killall -s KILL PIMCAM 2>/dev/null
        logger -p local0.info "[$KEY][$tag:$LINENO] start_cam.sh"
        /opt/pim/bin/start_cam.sh
    else
        fail_cnt=0
    fi

        sleep 3
done
logger -p local0.notice "[$KEY][$tag:$LINENO] restart_app.sh end"

exit 0
