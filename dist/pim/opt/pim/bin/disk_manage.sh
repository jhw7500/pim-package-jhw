#!/bin/bash
tag=$(basename "$0")
KEY=DSK
logger -p local0.warning "[$KEY][$tag:$LINENO] disk_manage.sh is deprecated; retention is handled by chk_cam_operate.sh (session-aware). No action taken."
exit 0
