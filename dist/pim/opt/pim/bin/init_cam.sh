#!/bin/bash

killall -s KILL restart_app.sh
/opt/pim/bin/kill_test.sh
/opt/pim/bin/kill_pid.sh

sleep 2
modprobe -r imx8-media-dev
sleep 2
modprobe -r max9296
#rmmod imx8-media-dev
#rmmod max9296

sleep 1
modprobe max9296
sleep 1
modprobe imx8-media-dev
sleep 5
#PIMCAM -j /root/shared_v/edgeconf_pim.json &
#/opt/pim/bin/vsd &
#/opt/pim/bin/ord &
#/opt/pim/bin/vcm &
/opt/pim/bin/restart_app.sh PIMCAM &
