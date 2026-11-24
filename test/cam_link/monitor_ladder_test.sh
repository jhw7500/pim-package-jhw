#!/bin/bash
# shellcheck disable=SC2034  # step() 이 세우는 이름은 대상 스크립트에서 잘라낸 블록이 읽는다
# chk_cam_operate.sh 본문 루프의 두 사다리(파일 검사, 시작 마커)가 실패 횟수마다 내는 요청 검증 (#192)
# 사용법: bash test/cam_link/monitor_ladder_test.sh
#
# 배경: 두 사다리는 gstapp_restart 뒤 module_reload 를 두 번 내고 재부팅으로 갔다. module_reload 의 성공
# 판정은 장치 노드와 프로세스만 보고 프레임 흐름은 보지 않으므로, 프레임이 나오지 않는 정지에서는 같은
# 동작을 되풀이할 뿐이다. 두 번째 module_reload 자리를 camera_hard_reset 으로 바꿨다. 재부팅을 요청하는
# 횟수는 그대로다. 아래는 사다리 하나만 이어지는 경우다 — 두 사다리는 retry_total 을 함께 쓴다.
#
# 두 사다리는 함수가 아니라 본문 루프 안의 if 블록이다. 블록을 원문 그대로 잘라 retry_total 을 올려 가며
# 실행하고 cam_submit_internal_action 이 받은 요청을 모은다. 최종 경로 정체 사다리는
# test/camera_health/final_stall_watch_test.sh 가 본다.
#
# MONITOR_LADDER_DAEMON=<경로> 로 다른 사본을 시험할 수 있다. 변경 전 스크립트는 하드 리셋 자리에서
# module_reload 를 내 실패한다:
#   git show origin/master:dist/pim/opt/pim/bin/chk_cam_operate.sh > /tmp/chk_old.sh
#   MONITOR_LADDER_DAEMON=/tmp/chk_old.sh bash test/cam_link/monitor_ladder_test.sh
source "$(dirname "$0")/lib.sh"

CHK=${MONITOR_LADDER_DAEMON:-$PIM_BIN/chk_cam_operate.sh}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 블록 하나를 잘라낸다. $1=블록 첫 줄(들여쓰기를 뺀 원문)  $2=출력 파일
# 첫 줄은 파일에 한 번만 나와야 하고, 같은 들여쓰기의 fi 까지가 블록이다.
extract_block() {
    local first=$1 out=$2 n
    n=$(awk -v f="$first" '{ l = $0; sub(/^[ \t]+/, "", l) } l == f { c++ } END { print c + 0 }' "$CHK")
    [ "$n" -eq 1 ] || { echo "블록 첫 줄이 ${n}번 나온다: $first ($CHK)" >&2; return 1; }
    awk -v f="$first" '
        !p { l = $0; sub(/^[ \t]+/, "", l); if (l == f) { p = 1; ind = substr($0, 1, length($0) - length(l)) } }
        p  { print }
        p && $0 == ind "fi" { exit }
    ' "$CHK" > "$out"
    if [ "$(tail -n 1 "$out" | tr -d ' \t')" != "fi" ] || ! bash -n "$out"; then
        echo "블록 추출 불완전: $first ($CHK)" >&2
        return 1
    fi
}

# 블록을 한 번 실행한다. $1=블록 파일  $2=retry_total  $3=file_chk_reboot
# 출력: "<요청>|<사유> <실행 뒤 retry_total>". 요청이 없으면 요청 자리는 "-" 다. 블록이 사다리 대기를
# 시작했으면(ladder_hold_start) 끝에 " hold" 가 붙는다.
step() {
    (
        KEY=test tag=test ENABLE_VAL=true
        retry=$2 retry_boot=0 retry_total=$2 file_chk_reboot=$3 req= hold=
        logger() { :; }
        cam_submit_internal_action() { req="${req:+$req,}$1|$2"; }
        ladder_hold_start() { hold=1; }
        # shellcheck disable=SC1090  # 대상 스크립트에서 잘라낸 블록이다
        source "$1"
        printf '%s %s%s\n' "${req:--}" "$retry_total" "${hold:+ hold}"
    )
}

# retry_total 을 1 부터 $2 까지 올려 가며 요청 이름만 이어 붙인다. $3=file_chk_reboot
walk() {
    local block=$1 upto=$2 reboot=$3 n out=()
    for ((n = 1; n <= upto; n++)); do
        out+=("$(step "$block" "$n" "$reboot" | cut -d'|' -f1 | cut -d' ' -f1)")
    done
    echo "${out[*]}"
}

echo "=== 파일 검사 사다리 ==="
extract_block 'if [ "$retry_total" -le 3 ]; then' "$WORK/file.sh" || exit 1
t_eq "횟수 1~7 의 요청" "$(walk "$WORK/file.sh" 7 true)" \
    "gstapp_restart gstapp_restart gstapp_restart module_reload camera_hard_reset reboot_fallback reboot_fallback"
t_eq "하드 리셋 요청의 사유와 횟수" "$(step "$WORK/file.sh" 5 true)" "camera_hard_reset|file check failure 5"
# PARTIAL 월반(file_check_partial_floor)이 올려 두는 하한 4 는 module_reload 단계여야 한다.
t_eq "월반 하한 4 는 module_reload" "$(step "$WORK/file.sh" 4 true)" "module_reload|file check failure 4"
t_eq "file_check_reboot 가 꺼져도 하드 리셋까지 간다" "$(walk "$WORK/file.sh" 5 false)" \
    "gstapp_restart gstapp_restart gstapp_restart module_reload camera_hard_reset"
t_eq "꺼져 있으면 그다음은 요청 없이 횟수를 0 으로 하고 쉰다" "$(step "$WORK/file.sh" 6 false)" "- 0 hold"
t_eq "켜져 있으면 쉬지 않고 재부팅을 요청한다" "$(step "$WORK/file.sh" 6 true)" "reboot_fallback|file check failure exhausted 6"

echo "=== 시작 마커 사다리 ==="
extract_block 'if [ "$retry_total" -le 2 ]; then' "$WORK/marker.sh" || exit 1
t_eq "횟수 1~6 의 요청" "$(walk "$WORK/marker.sh" 6 true)" \
    "gstapp_restart gstapp_restart module_reload camera_hard_reset reboot_fallback reboot_fallback"
t_eq "하드 리셋 요청의 사유와 횟수" "$(step "$WORK/marker.sh" 4 true)" "camera_hard_reset|gstapp start marker missing 4"
t_eq "file_check_reboot 가 꺼져도 하드 리셋까지 간다" "$(walk "$WORK/marker.sh" 4 false)" \
    "gstapp_restart gstapp_restart module_reload camera_hard_reset"
t_eq "꺼져 있으면 그다음은 요청 없이 횟수를 0 으로 하고 쉰다" "$(step "$WORK/marker.sh" 5 false)" "- 0 hold"
t_eq "켜져 있으면 쉬지 않고 재부팅을 요청한다" "$(step "$WORK/marker.sh" 5 true)" "reboot_fallback|gstapp start marker missing exhausted 5"

echo "=== 쉬는 동안 ==="
# file_check_reboot 가 꺼진 채 한계를 넘으면 사다리는 끊김 주기와 같은 간격만큼 쉰다. 사다리를 감싼 분기
# (쉬는 중 / 사다리 / 끊김)를 원문 그대로 잘라 실행한다. 대기 자체(시작·끝·간격)는
# test/cam_link/ladder_hold_retry_test.sh 가 본다.
# gate <블록 파일> <쉬는 중이면 1> <cam_disconnect_flag> [marker_disc]
gate() {
    (
        KEY=test tag=test ENABLE_VAL=true file_chk_reboot=false
        retry=0 retry_boot=0 retry_total=0 req= asked=
        cam_disconnect_flag=$3 marker_disc=${4:-0} missing_chs=() disc_note=
        DISCONNECT_INIT_CAM_STATE_FILE="$WORK/disc_state"
        HOLD=$2
        logger() { :; }
        ladder_on_hold() { asked=$1; [ "$HOLD" = 1 ]; }
        ladder_hold_start() { :; }
        file_check_partial_floor() { :; }
        read_driver_disconnect() { echo 0; }
        cam_submit_internal_action() { req="${req:+$req,}$1|$2"; }
        # shellcheck disable=SC1090  # 대상 스크립트에서 잘라낸 블록이다
        source "$1"
        printf '%s retry=%s boot=%s total=%s asked=[%s]\n' "${req:--}" "$retry" "$retry_boot" "$retry_total" "$asked"
    )
}
extract_block 'if (( cam_disconnect_flag == 0x0 )) && ladder_on_hold "file check failure"; then' "$WORK/file_gate.sh" || exit 1
t_eq "파일 검사: 쉬는 중이면 세지도 요청하지도 않는다" "$(gate "$WORK/file_gate.sh" 1 0)" \
    "- retry=0 boot=0 total=0 asked=[file check failure]"
t_eq "파일 검사: 쉬지 않으면 1 부터 센다" "$(gate "$WORK/file_gate.sh" 0 0)" \
    "gstapp_restart|file check failure retry=1 boot=0 total=1 asked=[file check failure]"
t_eq "파일 검사: 끊김 분기는 쉬는 것과 무관하다" "$(gate "$WORK/file_gate.sh" 1 5)" \
    "module_reload|disconnect file check failure retry=0 boot=0 total=0 asked=[]"
extract_block 'if [ "$marker_disc" -eq 0 ] && ladder_on_hold "gstapp start marker missing"; then' "$WORK/marker_gate.sh" || exit 1
t_eq "시작 마커: 쉬는 중이면 세지도 요청하지도 않는다" "$(gate "$WORK/marker_gate.sh" 1 0 0)" \
    "- retry=0 boot=0 total=0 asked=[gstapp start marker missing]"
t_eq "시작 마커: 쉬지 않으면 1 부터 센다" "$(gate "$WORK/marker_gate.sh" 0 0 0)" \
    "gstapp_restart|gstapp start marker missing retry=0 boot=1 total=1 asked=[gstapp start marker missing]"
t_eq "시작 마커: 끊김 분기는 쉬는 것과 무관하다" "$(gate "$WORK/marker_gate.sh" 1 5 1)" \
    "module_reload|disconnect startup failure retry=0 boot=0 total=0 asked=[]"
extract_block 'if (( cam_disconnect_flag == 0x0 )) && ladder_on_hold "driver load failure"; then' "$WORK/driver_gate.sh" || exit 1
t_eq "드라이버 미적재: 쉬는 중이면 세지도 요청하지도 않는다" "$(gate "$WORK/driver_gate.sh" 1 0)" \
    "- retry=0 boot=0 total=0 asked=[driver load failure]"
t_eq "드라이버 미적재: 쉬지 않으면 1 부터 센다" "$(gate "$WORK/driver_gate.sh" 0 0)" \
    "module_reload|driver load failure retry=0 boot=1 total=1 asked=[driver load failure]"
t_eq "드라이버 미적재: 꺼진 설정의 한계 초과도 쉰다" "$(grep -c -E '^[[:space:]]+ladder_hold_start$' "$WORK/driver_gate.sh")" 1

echo "=== 하드 리셋을 내는 곳 ==="
# 끊김 경로(케이블이 빠진 상태의 주기 복구)와 드라이버 적재 실패는 하드 리셋을 내지 않는다.
# 감시가 내는 곳은 위 두 블록, 최종 경로 정체(action 변수로 고른다), 그리고 file_check_reboot 가 꺼진 채
# DEGRADED 에 머물 때의 주기 재시도(maybe_retry_degraded)다.
t_eq "직접 제출은 세 곳" "$(grep -c 'cam_submit_internal_action camera_hard_reset ' "$CHK")" 3
t_eq "그중 하나는 DEGRADED 주기 재시도" "$(grep -c 'cam_submit_internal_action camera_hard_reset "degraded periodic recovery" 1; then$' "$CHK")" 1
t_eq "파일 검사 블록 안에 하나" "$(grep -c 'cam_submit_internal_action camera_hard_reset ' "$WORK/file.sh")" 1
t_eq "시작 마커 블록 안에 하나" "$(grep -c 'cam_submit_internal_action camera_hard_reset ' "$WORK/marker.sh")" 1
t_eq "변수로 고르는 곳은 최종 경로 정체 하나" "$(grep -c 'action=camera_hard_reset' "$CHK")" 1

t_summary "감시 사다리"
