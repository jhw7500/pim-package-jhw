#!/bin/bash

tag=$(basename "$0")
logger -s -p local0.emerg "[RST][$tag:$LINENO] cam disable start"
#killall -s KILL restart_app.sh
#/opt/pim/bin/kill_test.sh
#systemctl stop cam-operate
#pkill chk_cam_operate.sh
touch /tmp/init_cam_flag
#dmesg -n 3
/opt/pim/bin/kill_test.sh

sleep 0.5
logger -p local0.notice "[RST][$tag:$LINENO] rmmod imx8-media-dev, max9296"
rmmod imx8-media-dev
sleep 0.5
rmmod max9296
#rmmod imx8-media-dev
#rmmod max9296

logger -p local0.notice "[RST][$tag:$LINENO] cam disabled"
sleep 0.5
#logger -p local0.notice "[RST][$tag:$LINENO] modprobe imx8-media-dev, max9296"
modprobe max9296
sleep 0.5
modprobe imx8-media-dev
logger -p local0.emerg "[RST][$tag:$LINENO] modprobe imx8-media-dev, max9296"
sleep 0.5
echo "ready to turn on camera"
#sleep 1
