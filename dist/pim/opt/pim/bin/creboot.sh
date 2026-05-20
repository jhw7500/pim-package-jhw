#!/bin/bash

tag=$(basename "$0")
key=CHK
#/opt/pim/bin/kill_all.sh
#logger -s -p local0.notice "[$key][$tag:$LINENO] systemctl stop cam-operate"
#systemctl stop cam-operate
logger -s -p local0.notice "[$key][$tag:$LINENO] journald-snapshot before reboot"
/opt/pim/bin/journald-snapshot.sh || true
logger -s -p local0.notice "[$key][$tag:$LINENO] umount /mnt/sd_cam"
umount /mnt/sd_cam
sync
logger -s -p local0.notice "[$key][$tag:$LINENO] reboot -f"
sleep 1.5
reboot -f

exit $status
