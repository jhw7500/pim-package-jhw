#!/bin/bash

tag=$(basename "$0")
logger -p local0.notice [RST][$tag:$LINENO] module reset..
#killall -s KILL restart_app.sh
#/opt/pim/bin/kill_test.sh
#systemctl restart cam-operate
/opt/pim/bin/kill_all.sh

sleep 3
rmmod imx8-media-dev
sleep 3
rmmod max9296
#rmmod imx8-media-dev
#rmmod max9296

sleep 3
modprobe max9296
sleep 3
modprobe imx8-media-dev
sleep 5
#PIMCAM -j /root/shared_v/edgeconf_pim.json &
/opt/pim/bin/restart_app.sh PIMCAM &
#/opt/pim/bin/kill_pid.sh
/opt/pim/bin/ord &
/opt/pim/bin/vsd &
