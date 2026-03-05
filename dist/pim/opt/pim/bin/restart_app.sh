#!/bin/bash

tag=$(basename "$0")
KEY=RST

BG_FLAG_FILE="/tmp/bg_chk_flag.bin"

get_cam_disconnect_flag() {
    local v
    v=$(cat "$BG_FLAG_FILE" 2>/dev/null | tr -d '\n')
    if [[ ! "$v" =~ ^[0-9]+$ ]]; then
        echo 0
        return 0
    fi
    echo $((v & 0xf))
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

fail_cnt=0
while [ 1 ]; do
if [ -f /tmp/init_cam_flag ] || [ -f /tmp/restart_flag ]; then
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
        logger -p local0.notice "[$KEY][$tag:$LINENO] skip $app restart because cam disconnect(${dc_chs% })"
        sleep 10
        continue
fi

pid=$(ps -ef |grep "$app" |grep -v grep |awk '{print $2}')
if [ -z "$pid" ]; then
# [추가] start_cam.sh 실행 전 하드웨어 존재 여부 직접 재확인
# BG_Check가 재시작 중이더라도 직접 노드를 체크하여 무한 루프 방지
        can_start=0
        for node_idx in 3 4; do # csi0_video, csi1_video 기본값
            if [ -e "/dev/video$node_idx" ]; then
                # 노드가 있다면 v4l2-ctl로 응답 확인 (선택 사항이나 권장)
                if v4l2-ctl -d "/dev/video$node_idx" --get-ctrl=ae_on >/dev/null 2>&1; then
                    can_start=1
                    break
                fi
            fi
        done

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
