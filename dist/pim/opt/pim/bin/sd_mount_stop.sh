#!/bin/bash
TAG=$(basename "$0")
KEY="MNT"
PIM_CAMERA_RUNTIME_JSON="${PIM_CAMERA_RUNTIME_JSON:-/run/pim-camera/config/pim_runtime.json}"

if [[ "${PIM_CAMERA_TEST_MODE:-0}" == "1" ]]; then
    DIR="${PIM_SD_MOUNT_DIR:?PIM_SD_MOUNT_DIR is required in test mode}"
    DEVICE="${PIM_SD_DEVICE:?PIM_SD_DEVICE is required in test mode}"
    MNT_FLAG="${PIM_SD_MOUNT_FLAG:?PIM_SD_MOUNT_FLAG is required in test mode}"
else
    DIR="/mnt/sd_cam"
    DEVICE="/dev/mmcblk1p1"
    MNT_FLAG="/dev/shm/sd_mount_flag"
fi

if runtime_json=$(<"$PIM_CAMERA_RUNTIME_JSON") && command -v jq >/dev/null 2>&1; then
    tmp_path=$(jq -er '
        if type == "object" and
           (.VHL_CAM | type) == "object" and
           (.ORD | type) == "object" and
           (.VCM | type) == "object" and
           (.VHL_CAM.tmp_path | type) == "string"
        then .VHL_CAM.tmp_path else error("invalid camera runtime") end
    ' <<<"$runtime_json" 2>/dev/null) || tmp_path="CONFIG_INVALID"
    logger -p local0.debug "[$KEY][$TAG:$LINENO] current runtime tmp_path=$tmp_path (writer ownership ignored)"
fi

daemon_name=cam-operate
status=$(systemctl is-active "$daemon_name" 2>/dev/null)
# The live daemon may retain an older SD-backed destination after an operator
# edits the runtime.  Unit state, not mutable config, owns this stop boundary.
if [[ "$status" == "active" ]]; then
    logger -p local0.notice "[$KEY][$TAG:$LINENO] systemctl stop cam-operate"
    systemctl stop "$daemon_name"
    stop_rc=$?
    if [[ "$stop_rc" -ne 0 ]]; then
        logger -p local0.err "[$KEY][$TAG:$LINENO] cam-operate stop failed: $stop_rc"
        exit "$stop_rc"
    fi
    sleep 1
fi

logger -p local0.notice "[$KEY][$TAG:$LINENO] umount $DEVICE"
umount "$DEVICE"
sleep 1
for i in {1..3}; do
    mnt_dev=$(df | grep -F -- "$DEVICE" | awk '{print $1}')
    if [[ -z "$mnt_dev" ]]; then
        logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE unmount success!"
        rm -f -- "$MNT_FLAG"
        exit 0
    else
        logger -p local0.err "[$KEY][$TAG:$LINENO] umount -f $DEVICE"
        umount -f "$DEVICE"
    fi
    sleep 3
done

mnt_dev=$(df | grep -F -- "$DEVICE" | awk '{print $1}')
if [[ -z "$mnt_dev" ]]; then
    logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE unmount success!"
    rm -f -- "$MNT_FLAG"
    exit 0
else
    logger -p local0.emerg "[$KEY][$TAG:$LINENO] $DEVICE cannot unmounted"
    exit 1
fi
