#!/bin/bash
# chk_cam_operate.sh 의 cam_submit_internal_action 거부·실패 로그 검증 (#193)
# 사용법: bash test/cam_link/submit_internal_action_log_test.sh
#
# 배경: lifecycle 이 ACTIVE 가 아니면 69 로 거부하는데 호출부 16곳 중 15곳이 반환값을 보지 않아
# 사다리 요청이 로그 없이 사라졌다. 거부와 제출 실패를 이 함수 안에서 한 번 남긴다.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
t_extract_func "$PIM_BIN/chk_cam_operate.sh" cam_submit_internal_action "$WORK/submit.sh" || exit 1

# run_s <설명> <owner lifecycle> <cam_request_submit 이 낼 rc> <기대 rc> <로그에 있어야 할 문자열(없으면 로그 비어야 함)>
run_s() {
    local out rc log
    out=$(
        KEY=RST; tag=chk_cam_operate.sh
        PIM_CAMERA_RUN_DIR="$WORK/run"; mkdir -p "$PIM_CAMERA_RUN_DIR"
        printf '{"lifecycle":"%s"}\n' "$2" > "$PIM_CAMERA_RUN_DIR/owner.json"
        SUBMIT_RC=$3
        cam_request_submit() { return "$SUBMIT_RC"; }
        logger() { printf '%s\n' "$*" >> "$WORK/log"; }
        : > "$WORK/log"
        source "$WORK/submit.sh"
        cam_submit_internal_action module_reload "test reason"; echo $?
    )
    rc=${out##*$'\n'}
    t_eq "$1 (rc)" "$rc" "$4"
    log=$(cat "$WORK/log")
    if [ -n "${5:-}" ]; then
        case "$log" in *"$5"*) t_ok "$1 (로그: $5)";; *) t_bad "$1 (로그에 '$5' 없음: [$log])";; esac
    else
        [ -z "$log" ] && t_ok "$1 (로그 없음)" || t_bad "$1 (로그가 있으면 안 됨: [$log])"
    fi
}

echo "=== cam_submit_internal_action 거부·실패 로그 ==="
run_s "DEGRADED 거부"        DEGRADED 0  69 "module_reload refused: lifecycle=DEGRADED"
run_s "제출 실패 75"         ACTIVE   75 75 "module_reload submit failed rc=75"
run_s "ACTIVE 성공"          ACTIVE   0  0  ""

t_summary "cam_submit_internal_action 로그"
