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
# 호출자가 이미 같은 문서에서 읽어 넘겨준 값이 있으면 jq 를 다시 띄우지 않는다.
# 외부에서 직접 실행하는 경로에서는 비어 있으므로 그때만 조회한다.
#
# 이 우선순위는 앱 이름의 출처를 '검증된 런타임 문서' 에서 '호출자가 넘긴 env' 로
# 넓힌다. 트리뷰널 A-R1-011 / B-R1-006 이 지적한 축이며, 다음 두 경계 안에서
# 의도적으로 받아들인 것이다:
#   1. 아래 allowlist 가 값을 {gstApp, PIMCAM} 두 정규 바이너리로 한정한다 —
#      임의 실행은 불가능하고 범위 밖 값은 rc 64 로 닫힌다.
#   2. 여기까지 오려면 PIM_CAMERA_EXECUTOR=1 과 위의 cam_executor_assert_context
#      통과가 필요하다. 즉 이미 owner 컨텍스트를 쥔 호출자만 선택할 수 있다.
# 교차검증(cam_runtime_app 재호출)은 캐시가 없는 새 프로세스라 보드에서 jq 한 번
# (실측 약 0.4초)을 그대로 되살리므로 넣지 않는다. 유일한 in-tree 설정자
# (cam_recovery_actions.sh 의 cam_start_gstapp)는 같은 런타임 문서에서 읽는다.
app=${PIM_CAMERA_APP:-}
[ -n "$app" ] || app=$(cam_runtime_app "$PIM_CAMERA_RUNTIME_JSON") || exit 64
case "$app" in gstApp|PIMCAM) ;; *) exit 64;; esac
delay=${1:-$(jq -r '.VHL_CAM.app_delay // 4' "$PIM_CAMERA_RUNTIME_JSON")}
[[ $delay =~ ^[0-9]+$ ]] || exit 64

cam_side_effect_guard "$PIM_CAMERA_RUNTIME_JSON" || exit $?
# cam_process_present 의 app 분기는 cam_runtime_app 을 다시 호출한다. 위에서 이미
# 구한 $app 을 그대로 써서 jq 2회를 아낀다. 판정 자체는 pgrep -x 로 동일하다.
pgrep -x "$app" >/dev/null 2>&1; app_rc=$?
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
