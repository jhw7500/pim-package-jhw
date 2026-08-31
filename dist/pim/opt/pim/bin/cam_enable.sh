#!/bin/bash
source /opt/pim/lib/cam_start_policy.sh

tag=$(basename "$0")
logger -s -p local0.notice "[RST][$tag:$LINENO] cam enable"
#logger -p local0.notice "[RST][$tag:$LINENO] modprobe imx8-media-dev, max9296"
dmesg -n 4
#modprobe max9296
#sleep 1
#modprobe imx8-media-dev
#sleep 1
#PIMCAM -m 0 -c 3 &

app_delay=$CAM_APP_PLAY_DELAY_SEC_DEFAULT
settle_time=20

#logger -p local0.notice "[RST][$tag:$LINENO] cam enabled"
rm /tmp/init_cam_flag
/opt/pim/bin/start_cam.sh $app_delay
sleep 1
pkill -f BG_Check
sleep $settle_time
#echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
#/opt/pim/bin/restart_app.sh &
#systemctl start cam-operate
#/opt/pim/bin/restart_app.sh &
#/opt/pim/bin/kill_test.sh
#/opt/pim/bin/kill_pid.sh
