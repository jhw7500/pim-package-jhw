#!/bin/bash

tag=$(basename "$0")
logger -p local0.notice "[RST][$tag:$LINENO] module reset start"
#killall -s KILL restart_app.sh
#/opt/pim/bin/kill_test.sh
#systemctl stop cam-operate
#pkill chk_cam_operate.sh

if [ -f /tmp/init_cam_flag ]; then
    logger -p local0.notice "[RST][$tag:$LINENO] exit because already module reset..."
    exit 0
fi


/opt/pim/bin/kill_test.sh
touch /tmp/init_cam_flag

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
sleep 2
modprobe imx8-media-dev
sleep 2
#PIMCAM -m 0 -c 3 &
FILE_JSON=$(ls -ptr /root/shared_v/${JSON_PREFIX}*${JSON_SUFFIX} | grep -v '/$' | grep "${JSON_SUFFIX}$" | tail -1 | tr -d '\r\n')
cam_ch0=$(jq '.VHL_CAM.i2c2.ch0.enable' "$FILE_JSON")
cam_ch1=$(jq '.VHL_CAM.i2c2.ch1.enable' "$FILE_JSON")
cam_ch2=$(jq '.VHL_CAM.i2c1.ch2.enable' "$FILE_JSON")
cam_ch3=$(jq '.VHL_CAM.i2c1.ch3.enable' "$FILE_JSON")
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
    rst_time=25
else
    rst_time=15
fi

logger -p local0.notice "[RST][$tag:$LINENO] module reset end"
rm /tmp/init_cam_flag
/opt/pim/bin/start_cam.sh $rst_time

#/opt/pim/bin/restart_app.sh &
#systemctl start cam-operate
#/opt/pim/bin/restart_app.sh &
#/opt/pim/bin/kill_test.sh
#/opt/pim/bin/kill_pid.sh
