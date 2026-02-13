#!/bin/bash

tag=$(basename "$0")
#killall -s KILL restart_app.sh
#/opt/pim/bin/kill_test.sh
#systemctl stop cam-operate
#pkill chk_cam_operate.sh

rm /tmp/gst_err
if [ -f /tmp/init_cam_flag ]; then
    logger -p local0.notice "[RST][$tag:$LINENO] exit because already module reset..."
    exit 0
fi

logger -p local0.notice "[RST][$tag:$LINENO] set init_cam_flag"
touch /tmp/init_cam_flag
/opt/pim/bin/kill_test.sh

#sleep 3
logger -p local0.notice "[RST][$tag:$LINENO] rmmod imx8-media-dev, max9296"
rmmod imx8-media-dev
#sleep 3
rmmod max9296
#rmmod imx8-media-dev
#rmmod max9296

sleep 2
logger -p local0.notice "[RST][$tag:$LINENO] modprobe imx8-media-dev, max9296"
modprobe max9296
rc1=$?
sleep 2
modprobe imx8-media-dev
rc2=$?
sleep 2

if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
    logger -p local0.emerg "[RST][$tag:$LINENO] modprobe failed (max9296:$rc1 imx8-media-dev:$rc2)"
    logger -p local0.notice "[RST][$tag:$LINENO] reset init_cam_flag"
    rm -f /tmp/init_cam_flag
    exit 1
fi
#PIMCAM -m 0 -c 3 &
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
#cam_ch0=$(jq '.VHL_CAM.i2c2.ch0.enable' "$FILE_JSON")
#cam_ch1=$(jq '.VHL_CAM.i2c2.ch1.enable' "$FILE_JSON")
#cam_ch2=$(jq '.VHL_CAM.i2c1.ch2.enable' "$FILE_JSON")
#cam_ch3=$(jq '.VHL_CAM.i2c1.ch3.enable' "$FILE_JSON")
IFS=$'\t' read -r \
    cam_ch0 cam_ch1 cam_ch2 cam_ch3 < <(
    jq -r '[
        (.VHL_CAM.i2c2.ch0.enable // false),
        (.VHL_CAM.i2c2.ch1.enable // false),
        (.VHL_CAM.i2c1.ch2.enable // false),
        (.VHL_CAM.i2c1.ch3.enable // false)
    ] | @tsv' "$FILE_JSON"
)
unset IFS

csi1_en=0
if [[ "$cam_ch0" == "true" ]] || [[ "$cam_ch1" == "true" ]]; then
    csi1_en=1
fi
csi2_en=0
if [[ "$cam_ch2" == "true" ]] || [[ "$cam_ch3" == "true" ]]; then
    csi2_en=1
fi

#echo "csi1_en:$csi1_en, csi2_en:$csi2_en"

if [[ "$csi1_en" -eq 1 ]] && [[ "$csi2_en" -eq 1 ]]; then
    rst_time=22
else
    rst_time=11
fi

logger -p local0.notice "[RST][$tag:$LINENO] reset init_cam_flag and clear recovery requests"
rm -f /tmp/init_cam_flag
rm -f /tmp/recover_req_init_cam # [추가] 중복 복구 방지를 위해 기존 요청 플래그 삭제
/opt/pim/bin/start_cam.sh $rst_time

#/opt/pim/bin/restart_app.sh &
#systemctl start cam-operate
#/opt/pim/bin/restart_app.sh &
#/opt/pim/bin/kill_test.sh
#/opt/pim/bin/kill_pid.sh
