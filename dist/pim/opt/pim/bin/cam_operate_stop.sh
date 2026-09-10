#!/usr/bin/env bash
set -u

PIM_LIB="${PIM_LIB:-/opt/pim/lib}"
PIM_BIN="${PIM_BIN:-/opt/pim/bin}"
export PIM_LIB PIM_BIN

# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery_actions.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_operate_control.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_liveness.sh"

cam_operate_systemd_stop() {
    local attempts=${PIM_CAMERA_SYSTEMD_STOP_ATTEMPTS:-30} attempt=1 rc
    [[ $attempts =~ ^[1-9][0-9]*$ ]] || attempts=30
    while [ "$attempt" -le "$attempts" ]; do
        cam_liveness_ordered_stop --external
        rc=$?
        [ "$rc" -eq 75 ] || return "$rc"
        [ "$attempt" -lt "$attempts" ] || return 75
        sleep 1
        attempt=$((attempt + 1))
    done
    return 75
}

if [ "${1:-}" = --systemd ]; then
    cam_operate_systemd_stop
else
    cam_liveness_ordered_stop --external
fi
