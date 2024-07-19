#!/bin/bash

tag=$(basename "$0")
logger -p local0.emerg "[RST][$tag:$LINENO] cam disable start"
#killall -s KILL restart_app.sh
#/opt/pim/bin/kill_test.sh
#systemctl stop cam-operate
#pkill chk_cam_operate.sh
touch /tmp/init_cam_flag
#dmesg -n 3
/opt/pim/bin/kill_test.sh

#sleep 3
logger -p local0.notice "[RST][$tag:$LINENO] rmmod imx8-media-dev, max9296"
rmmod imx8-media-dev
#sleep 3
rmmod max9296
#rmmod imx8-media-dev
#rmmod max9296

logger -p local0.notice "[RST][$tag:$LINENO] cam disabled"
#sleep 1
#logger -p local0.notice "[RST][$tag:$LINENO] modprobe imx8-media-dev, max9296"
modprobe max9296
#sleep 1
modprobe imx8-media-dev
logger -p local0.emerg "[RST][$tag:$LINENO] modprobe imx8-media-dev, max9296"
sleep 1
echo "ready to turn on camera"
#sleep 1
