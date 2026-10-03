#!/usr/bin/env bash
# Deprecated compatibility boundary. -s/-S remain accepted but no longer control services.
set -u

# --no-wait skips the wait: cam-recoveryctl prints the request UUID instead of the
# CAM_RECOVERY_RESULT line and exits 0 as soon as the request is submitted,
# without reporting how the action ended.  There is no queue - the pending slot
# holds one request - so calling it again while that request is pending or active
# submits nothing: 75 BUSY when the owner lifecycle is ACTIVE, DEGRADED or
# RECOVERING, and 69 on any other lifecycle, such as APPLYING_CONFIG during an
# apply-config transaction.  For a repeated non-blocking workflow that refusal is
# the normal answer for the length of the action, not a failure.  The default
# is deliberately unchanged; issue #109 records the board measurement that rules
# out lowering it.
no_wait=0
while [ $# -gt 0 ]; do
    # -s/-S 는 받되 아무것도 하지 않는다. 조용히 버리면 호출자가 자기 서비스 제어 의도가
    # 무시됐음을 출력에서 알 수 없다 (이슈 #61 요구 6). 받아 두는 이유는 pim-check 가
    # 레거시이고 현재 버전에 맞게 개편될 예정이라, 그 전까지 호출 형태를 깨지 않기 위해서다.
    # 배포된 호출자가 있다는 뜻은 아니다 — pim-check main 의 cam_hard_reset 호출은 0 건이고,
    # `-s -S` 단정은 원격에도 PR 에도 없는 로컬 브랜치 feat/camera-hard-reset(2026-09-01)
    # 뿐이다. 제거 시점은 요구 6 과 legacy_wrapper_test.sh 의 고정이 따로 정한다.
    case "$1" in
        -q|--quiet) shift;;
        -s|--stop-service|-S|--start-service)
            echo "NOTE: $1 is accepted but ignored; this wrapper no longer controls cam-operate" >&2
            shift;;
        --no-wait) no_wait=1; shift;;
        -h|--help) echo 'usage: cam_hard_reset.sh [-q] [-s] [-S] [--no-wait]'; exit 0;;
        *) echo "unknown option: $1" >&2; exit 64;;
    esac
done
echo 'DEPRECATED: cam_hard_reset.sh forwards one recovery request' >&2
if [ "$no_wait" -eq 1 ]; then
    exec "${PIM_CAMERA_RECOVERYCTL:-/opt/pim/bin/cam-recoveryctl}" request camera_hard_reset --source legacy-cam-hard-reset --reason legacy-wrapper
fi
exec "${PIM_CAMERA_RECOVERYCTL:-/opt/pim/bin/cam-recoveryctl}" request camera_hard_reset --source legacy-cam-hard-reset --reason legacy-wrapper --wait 300
