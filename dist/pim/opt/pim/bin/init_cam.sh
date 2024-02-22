#!/bin/bash

tag=$(basename "$0")
logger -p local0.notice "[RST][$tag:$LINENO] module reset.."
#killall -s KILL restart_app.sh
#/opt/pim/bin/kill_test.sh
#systemctl stop cam-operate
#pkill chk_cam_operate.sh
/opt/pim/bin/kill_test.sh 1

#sleep 3
rmmod imx8-media-dev
#sleep 3
rmmod max9296
#rmmod imx8-media-dev
#rmmod max9296

sleep 2
modprobe max9296
sleep 2
modprobe imx8-media-dev
sleep 2
#PIMCAM -m 0 -c 3 &
/opt/pim/bin/start_cam.sh
#systemctl start cam-operate
#/opt/pim/bin/restart_app.sh &
#/opt/pim/bin/kill_test.sh
#/opt/pim/bin/kill_pid.sh
