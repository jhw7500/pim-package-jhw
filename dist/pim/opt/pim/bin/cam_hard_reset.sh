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
    # 무시됐음을 출력에서 알 수 없다 (이슈 #61 요구 6). 제거하지 않는 이유는 이 플래그를
    # 아직 보내는 호출자가 있어서다 — pim-check 의 feat/camera-hard-reset 이 지금도
    # `cam_hard_reset.sh -s -S` 를 단정한다. 그쪽이 요청 인터페이스로 넘어오면 제거할 수 있다.
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
