#!/bin/bash

tag=$(basename "$0")
logger -p local0.notice "[RST][$tag:$LINENO] cam enable start"
logger -p local0.notice "[RST][$tag:$LINENO] modprobe imx8-media-dev, max9296"
modprobe max9296
sleep 1
modprobe imx8-media-dev
sleep 1
#PIMCAM -m 0 -c 3 &
rst_time=20

logger -p local0.notice "[RST][$tag:$LINENO] cam enabled"
rm /tmp/init_cam_flag
/opt/pim/bin/start_cam.sh $rst_time

#/opt/pim/bin/restart_app.sh &
#systemctl start cam-operate
#/opt/pim/bin/restart_app.sh &
#/opt/pim/bin/kill_test.sh
#/opt/pim/bin/kill_pid.sh
