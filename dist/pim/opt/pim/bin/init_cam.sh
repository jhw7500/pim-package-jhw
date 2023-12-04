#!/bin/bash

tag=$(basename "$0")
logger -p local0.notice [RST][$tag:$LINENO] module reset..
#killall -s KILL restart_app.sh
#/opt/pim/bin/kill_test.sh
#systemctl restart cam-operate
/opt/pim/bin/kill_all.sh

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
PIMCAM -d 20 -m 3 &
/opt/pim/bin/restart_app.sh &
#/opt/pim/bin/kill_test.sh
#/opt/pim/bin/kill_pid.sh
