#!/usr/bin/env bash
# External calls are compatibility requests; executor calls perform the internal launch.
set -u

PIM_LIB="${PIM_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)}"
PIM_BIN="${PIM_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "$PIM_LIB/cam_recovery_actions.sh"

if [ "${PIM_CAMERA_EXECUTOR:-}" != 1 ]; then
    [ $# -le 1 ] || { echo 'usage: start_cam.sh [delay]' >&2; exit 64; }
    echo 'DEPRECATED: start_cam.sh forwards one recovery request' >&2
    exec "${PIM_CAMERA_RECOVERYCTL:-/opt/pim/bin/cam-recoveryctl}" request gstapp_restart --source legacy-start-cam --reason legacy-wrapper --wait 120
fi

[ $# -le 1 ] || { echo 'usage: start_cam.sh [delay]' >&2; exit 64; }
cam_executor_assert_context || exit $?
cam_validate_runtime "$PIM_CAMERA_RUNTIME_JSON" || exit 64
app=$(cam_runtime_app "$PIM_CAMERA_RUNTIME_JSON") || exit 64
delay=${1:-$(jq -r '.VHL_CAM.app_delay // 4' "$PIM_CAMERA_RUNTIME_JSON")}
[[ $delay =~ ^[0-9]+$ ]] || exit 64

cam_side_effect_guard "$PIM_CAMERA_RUNTIME_JSON" || exit $?
cam_process_present "$PIM_CAMERA_RUNTIME_JSON" app; app_rc=$?
[ "$app_rc" -eq 0 ] || [ "$app_rc" -eq 1 ] || exit "$app_rc"
cam_side_effect_guard "$PIM_CAMERA_RUNTIME_JSON" || exit $?
cam_process_present "$PIM_CAMERA_RUNTIME_JSON" bg; bg_rc=$?
[ "$bg_rc" -eq 0 ] || [ "$bg_rc" -eq 1 ] || exit "$bg_rc"

if [ "$app_rc" -eq 1 ]; then
    ( _cr_test_owner_rollover launch_app && cam_side_effect_guard "$PIM_CAMERA_RUNTIME_JSON" && exec "$app" -d "$delay" -m 4 ) &
fi
if [ "$bg_rc" -eq 1 ]; then
    ( _cr_test_owner_rollover launch_bg && cam_side_effect_guard "$PIM_CAMERA_RUNTIME_JSON" && exec "${PIM_CAMERA_BG_CHECKER:-$PIM_BIN/BG_Check_for_pim.sh}" "$delay" >/dev/null 2>&1 ) &
fi
