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

settle_time=20

#logger -p local0.notice "[RST][$tag:$LINENO] cam enabled"
rm /tmp/init_cam_flag
# No positional delay: start_cam.sh's compatibility path counts a positional
# argument and then forwards only the recovery request, so the value never reached
# anything.  The delay that actually takes effect is read from the runtime document
# by cam_runtime_app_delay in cam_recovery_actions.sh.
/opt/pim/bin/start_cam.sh
sleep 1
pkill -f BG_Check
sleep $settle_time
#echo 1 > /sys/devices/platform/leds/leds/gpio1_led/brightness
#/opt/pim/bin/restart_app.sh &
#systemctl start cam-operate
#/opt/pim/bin/restart_app.sh &
#/opt/pim/bin/kill_test.sh
#/opt/pim/bin/kill_pid.sh
