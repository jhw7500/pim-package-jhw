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

runtime_uses_sd=1
if command -v jq >/dev/null 2>&1 && jq -e '
    type == "object" and
    (.VHL_CAM | type == "object") and
    (.ORD | type == "object") and
    (.VCM | type == "object") and
    (.VHL_CAM.tmp_path | type == "string")
' "$PIM_CAMERA_RUNTIME_JSON" >/dev/null 2>&1; then
    tmp_path=$(jq -r '.VHL_CAM.tmp_path' "$PIM_CAMERA_RUNTIME_JSON")
    if [[ "$tmp_path" != "$DIR" ]]; then
        runtime_uses_sd=0
    fi
fi

if [[ "$runtime_uses_sd" == "1" ]]; then
    daemon_name=cam-operate
    status=$(systemctl is-active "$daemon_name" 2>/dev/null)
    # tmp_path가 SD 경로(=DIR)이고 cam-operate가 active면 SD를 잡고 있을 가능성이 크다.
    # umount 전에 graceful stop으로 file handle을 닫고 EIO를 피한다.
    # 런타임 설정이 없거나 잘못된 경우에도 active writer는 보수적으로 먼저 정지한다.
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
