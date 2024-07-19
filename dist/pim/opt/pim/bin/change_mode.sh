#!/bin/bash
tag=$(basename "$0")

if [ "$1" == "jig" ]; then
    logger -s -p local0.notice "[RST][$tag:$LINENO] mode change : $1"
    systemctl disable cam-operate
    /opt/pim/bin/add_line.sh "/opt/pim/bin/button_cam_reset.sh &" "/etc/rc.local"
    #/opt/pim/bin/change_line.sh "/opt/pim/bin/button_cam_reset.sh &" "/opt/pim/bin/button_cam_reset.sh" /etc/rc.local
    #/opt/pim/bin/change_line.sh "15 *   * * *   root    /opt/pim/bin/log_manage.sh /var/log/cantops 100 10" "/opt/pim/bin/log_manage.sh /var/log/cantops" /etc/crontab
elif [ "$1" == "normal" ]; then
    logger -s -p local0.notice "[RST][$tag:$LINENO] mode change : $1"
    systemctl enable cam-operate
    /opt/pim/bin/remove_line.sh "button_cam_reset.sh" "/etc/rc.local"
else
    logger -s -p local0.err "[RST][$tag:$LINENO] invalid mode : $1"
fi

