#!/bin/bash
# shellcheck disable=SC2034  # 아래에서 세우는 이름은 대상 스크립트에서 잘라낸 함수가 읽는다
# file_check_reboot 가 꺼져 있을 때의 사다리 대기와 DEGRADED 주기 재시도 검증 (#192)
# 사용법: bash test/cam_link/ladder_hold_retry_test.sh
#
# 배경: 재부팅으로 넘어가지 않는 설정에서 (1) 사다리가 한계를 넘으면 횟수를 0 으로 되돌리고 곧바로 다시
# 세어, 증상이 남아 있으면 재시작·재적재·하드 리셋이 쉬지 않고 되풀이됐다. (2) 데몬이 낸 복구가 실패하면
# owner 가 DEGRADED 가 되고 그 뒤 데몬의 요청이 모두 거부되어, 운영자가 조치할 때까지 녹화가 멈춘 채
# 남았다(.6 2026-11-24 실측). 끊김 주기 복구와 같은 간격만큼 쉬고 다시 시도하게 했다.
#
# 여기서는 함수 단위로 본다: 간격 계산(앞자리 0 포함), 대기의 시작·끝, DEGRADED 재시도의 조건(대상과
# 마지막 요청)과 주기, DEGRADED 에서의 제출 허용. 사다리 블록이 쉬는 동안 세지 않는지는 test/cam_link/monitor_ladder_test.sh 가, 최종 경로
# 정체 사다리는 test/camera_health/final_stall_watch_test.sh 가 본다.
#
# LADDER_HOLD_DAEMON=<경로> 로 다른 감시 스크립트 사본을, LADDER_HOLD_CONTROL=<경로> 로 다른 실행기
# 라이브러리 사본을 시험할 수 있다. 변경 전 스크립트에는 이 함수들이 없어 추출에서 실패한다.
# DEGRADED 가 실패한 복구 요청에서 왔는지는 실행기 쪽 cam_degraded_by_failed_recovery 가 판정한다(상태·이력
# 파일을 읽는 곳을 라이브러리로 모았다). 여기서는 감시 스크립트의 함수와 그 함수를 함께 읽어 들여 본다.
source "$(dirname "$0")/lib.sh"

CHK=${LADDER_HOLD_DAEMON:-$PIM_BIN/chk_cam_operate.sh}
CTL=${LADDER_HOLD_CONTROL:-$PIM_LIB/cam_operate_control.sh}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FUNCS="_final_watch_uptime_into ladder_retry_interval_into ladder_hold_start ladder_on_hold maybe_retry_degraded cam_submit_internal_action"
for fn in $FUNCS; do
    t_extract_func "$CHK" "$fn" "$WORK/$fn.sh" || exit 1
done
t_extract_func "$CTL" cam_degraded_by_failed_recovery "$WORK/cam_degraded_by_failed_recovery.sh" || exit 1
# 한 줄짜리 경로 함수는 원문 줄을 그대로 가져온다.
grep '^_cr_service_file() ' "$PIM_LIB/cam_recovery.sh" > "$WORK/_cr_service_file.sh"
[ "$(wc -l < "$WORK/_cr_service_file.sh")" -eq 1 ] || { echo "함수 추출 실패: _cr_service_file" >&2; exit 1; }

# 잘라낸 함수를 읽어 들이고 가짜 시계·로그를 준비한다. 서브셸 안에서 부른다.
prep() {
    KEY=RST; tag=t_ladder_hold
    export PIM_CAMERA_PROCESS_ROOT="$WORK/proc"
    PIM_CAMERA_RUN_DIR="$WORK/run"; PIM_CAMERA_STATE_DIR="$WORK/state"
    mkdir -p "$PIM_CAMERA_PROCESS_ROOT" "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR"
    : > "$WORK/log"; : > "$WORK/req"
    logger() { printf '%s\n' "$*" >> "$WORK/log"; }
    # 데몬이 최상위에서 세우는 값(아래 "초기값" 절에서 원문과 같은지 따로 본다)
    LADDER_RETRY_MIN_SEC=60; ladder_hold_until=0; ladder_hold_log_up=0; degraded_since=0
    DISCONNECT_INIT_CAM_INTERVAL_SEC_DEFAULT=180
    ENABLE_VAL=true; file_chk_reboot=false
    local f
    for f in $FUNCS cam_degraded_by_failed_recovery _cr_service_file; do
        # shellcheck disable=SC1090  # 대상 스크립트에서 잘라낸 함수다
        source "$WORK/$f.sh"
    done
}
up() { echo "$1.00 0.00" > "$PIM_CAMERA_PROCESS_ROOT/uptime"; }
held() { if ladder_on_hold "${1:-file check failure}"; then echo held; else echo free; fi; }

echo "=== 초기값 ==="
t_eq "하한 60초" "$(grep -c '^LADDER_RETRY_MIN_SEC=60$' "$CHK")" 1
t_eq "대기 없음으로 시작" "$(grep -c '^ladder_hold_until=0$' "$CHK")" 1
t_eq "DEGRADED 관측 시각 없음으로 시작" "$(grep -c '^degraded_since=0$' "$CHK")" 1

echo "=== 간격 ==="
iv() { ( prep; [ "$1" = unset ] || DISCONNECT_INIT_CAM_INTERVAL_SEC=$1; ladder_retry_interval_into v; echo "$v" ); }
t_eq "끊김 주기와 같은 값을 쓴다(180)" "$(iv 180)" 180
t_eq "설정이 300 이면 300" "$(iv 300)" 300
t_eq "하한보다 작으면 60" "$(iv 10)" 60
t_eq "0 이면 60" "$(iv 0)" 60
t_eq "숫자가 아니면 기본 180" "$(iv abc)" 180
t_eq "빈 값이면 기본 180" "$(iv '')" 180
t_eq "변수가 없으면 기본 180" "$(iv unset)" 180
# 설정이 문자열 "0180" 이면 산술식이 8진수로 읽는다. 10진으로 고쳐 쓴다.
t_eq "앞자리 0 은 10진으로 읽는다(0180)" "$(iv 0180)" 180
t_eq "앞자리 0 은 10진으로 읽는다(090)" "$(iv 090)" 90
t_eq "8진수로 읽으면 56 이 될 값(0070)은 70" "$(iv 0070)" 70
t_eq "앞자리 0 이 있어도 하한은 지킨다(08)" "$(iv 08)" 60
# 고치기 전에는 대기 시작의 산술식이 오류를 내 그것을 감싼 본문 루프가 통째로 버려졌다(데몬이 rc 0 으로 끝남).
t_eq "앞자리 0 설정에서도 본문 루프가 이어진다" "$( prep; DISCONNECT_INIT_CAM_INTERVAL_SEC=0180; up 1000; n=0; while [ "$n" -lt 2 ]; do n=$((n + 1)); ladder_hold_start; done 2>/dev/null; echo "loops=$n until=$ladder_hold_until" )" \
    "loops=2 until=1180"

echo "=== 대기의 시작과 끝 ==="
t_eq "시작 전에는 쉬지 않는다" "$( prep; up 1000; held )" free
t_eq "시작하면 간격만큼 쉰다" "$( prep; DISCONNECT_INIT_CAM_INTERVAL_SEC=180; up 1000; ladder_hold_start; up 1001; a=$(held); up 1179; b=$(held); echo "$a $b until=$ladder_hold_until" )" \
    "held held until=1180"
# held 는 명령 치환으로 부르면 서브셸이라 대기 해제(ladder_hold_until=0)가 남지 않는다. 직접 부른다.
t_eq "간격이 지나면 풀리고 값도 지운다" "$( prep; DISCONNECT_INIT_CAM_INTERVAL_SEC=180; up 1000; ladder_hold_start; up 1180; ladder_on_hold x && r=held || r=free; echo "$r until=$ladder_hold_until" )" \
    "free until=0"
t_eq "풀린 뒤에는 계속 쉬지 않는다" "$( prep; up 1000; ladder_hold_start; up 1180; ladder_on_hold x; up 1181; ladder_on_hold x && echo held || echo free )" free
t_eq "쉬는 중에 설정이 켜지면 곧바로 푼다" "$( prep; up 1000; ladder_hold_start; up 1001; file_chk_reboot=true; ladder_on_hold x && r=held || r=free; echo "$r until=$ladder_hold_until" )" \
    "free until=0"
t_eq "시작 로그" "$( prep; DISCONNECT_INIT_CAM_INTERVAL_SEC=180; up 1000; ladder_hold_start; grep -c 'ladder paused for 180s because file_check_reboot is not true' "$WORK/log" )" 1
t_eq "쉬는 동안의 로그는 30초에 한 번" "$( prep; up 1000; ladder_hold_start; for t in 1010 1020 1029 1030 1040 1059 1060; do up $t; ladder_on_hold 'file check failure'; done; grep -c 'ladder paused, ' "$WORK/log" )" 2
t_eq "로그에 남은 시간과 사유" "$( prep; up 1000; ladder_hold_start; up 1030; ladder_on_hold 'file check failure'; grep -c 'ladder paused, 150s left: no request for file check failure' "$WORK/log" )" 1
t_eq "가동 시간을 못 읽으면 대기를 시작하지 않는다" "$( prep; rm -f "$PIM_CAMERA_PROCESS_ROOT/uptime"; ladder_hold_start; echo "rc=$? until=$ladder_hold_until" )" "rc=0 until=0"
t_eq "가동 시간을 못 읽으면 쉬지 않는 것으로 본다" "$( prep; up 1000; ladder_hold_start; rm -f "$PIM_CAMERA_PROCESS_ROOT/uptime"; held )" free

echo "=== DEGRADED 주기 재시도 ==="
# deg <lifecycle> <AUTO_REBOOT|unset> <degraded_target|null|nofile> <마지막 요청 "type/status"|none> <가동 시각…>
# 출력: 제출을 시도한 시각을 이어 붙이고, 이어서 제출 인자(중복 제거). SUBMIT_RC 가 0 이 아니면 제출이 거절된다.
deg() {
    (
        prep
        local lc=$1 ar=$2 target=$3 last=$4 t n out=""
        shift 4
        PIM_CAMERA_MONITOR_LIFECYCLE=$lc
        [ "$ar" = unset ] || PIM_CAMERA_AUTO_REBOOT=$ar
        rm -rf "$PIM_CAMERA_STATE_DIR"; mkdir -p "$PIM_CAMERA_STATE_DIR/recovery/history"
        [ "$target" = nofile ] || printf '{"dirty":true,"degraded_reason":"file check failure","degraded_target":%s}\n' \
            "$([ "$target" = null ] && echo null || echo "\"$target\"")" > "$PIM_CAMERA_STATE_DIR/service-state.json"
        # 예전 요청 하나(성공한 재적재)와 마지막 요청. 마지막 것은 수정 시각으로 고른다. 이름순으로는 예전
        # 것이 앞에 오게 지어, 이름순으로 고르는 구현이면 시험이 깨진다.
        printf '{"request":{"type":"module_reload","status":"SUCCEEDED"}}\n' > "$PIM_CAMERA_STATE_DIR/recovery/history/a-old.json"
        touch -d '2 hours ago' "$PIM_CAMERA_STATE_DIR/recovery/history/a-old.json"
        [ "$last" = none ] || printf '{"request":{"type":"%s","status":"%s"}}\n' "${last%%/*}" "${last##*/}" \
            > "$PIM_CAMERA_STATE_DIR/recovery/history/z-last.json"
        [ "$last" != none ] || rm -f "$PIM_CAMERA_STATE_DIR/recovery/history/a-old.json"
        cam_submit_internal_action() { printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >> "$WORK/req"; return "${SUBMIT_RC:-0}"; }
        for t in "$@"; do
            up "$t"
            n=$(wc -l < "$WORK/req")
            maybe_retry_degraded
            [ "$(wc -l < "$WORK/req")" -eq "$n" ] || out="${out:+$out,}$t"
        done
        echo "${out:--} $(sort -u "$WORK/req" | tr '\n' ' ' | sed 's/ $//')"
    )
}
F=camera_hard_reset/FAILED
t_eq "처음 본 뒤 간격이 지나야 낸다" "$(deg DEGRADED 0 camera_health $F 1000 1001 1179 1180)" \
    "1180 camera_hard_reset|degraded periodic recovery|1"
# 접수되면 시계를 지우고, 다음에 DEGRADED 를 본 때(실패 직후)부터 다시 잰다.
t_eq "접수 뒤에는 다시 본 때부터 간격을 잰다" "$(deg DEGRADED 0 camera_health $F 1000 1180 1181 1360 1361 | cut -d' ' -f1)" "1180,1361"
t_eq "접수되지 않으면 한 간격 뒤에 다시 낸다" "$(SUBMIT_RC=75; export SUBMIT_RC; deg DEGRADED 0 camera_health $F 1000 1180 1181 1359 1360 | cut -d' ' -f1)" "1180,1360"
t_eq "모듈 재적재 실패 뒤에도 낸다" "$(deg DEGRADED 0 camera_health module_reload/FAILED 1000 1180 | cut -d' ' -f1)" 1180
t_eq "gstapp_restart 실패로 멈춘 경우도 낸다" "$(deg DEGRADED 0 gstapp gstapp_restart/FAILED 1000 1180 | cut -d' ' -f1)" 1180
# gstapp_restart 는 액션이 끝난 뒤의 검증에서 실패하면 대상이 camera_health 로 적힌다(_coc_verify_all 실패).
t_eq "gstapp_restart 뒤 검증 실패로 멈춘 경우도 낸다" "$(deg DEGRADED 0 camera_health gstapp_restart/FAILED 1000 1180 | cut -d' ' -f1)" 1180
t_eq "기본 설정(재부팅 켜짐)에서는 내지 않는다" "$(deg DEGRADED 1 camera_health $F 1000 1180 1400)" "- "
t_eq "값이 없으면 켜짐으로 본다" "$(deg DEGRADED unset camera_health $F 1000 1180 1400)" "- "
t_eq "ACTIVE 에서는 내지 않는다" "$(deg ACTIVE 0 camera_health $F 1000 1180 1400)" "- "
t_eq "RECOVERING 에서는 내지 않는다" "$(deg RECOVERING 0 camera_health $F 1000 1180 1400)" "- "
for tg in config policy ord vcm state process null nofile; do
    t_eq "복구 실패가 아닌 DEGRADED(대상 $tg)는 건드리지 않는다" "$(deg DEGRADED 0 "$tg" $F 1000 1180 1400)" "- "
done
# 운영자의 apply-config 가 하드웨어·검증 단계에서 실패해도 degraded_target 은 camera_health 나 gstapp 이다.
# 그 경우와 정지 요청은 마지막 요청의 종류로 가른다.
t_eq "apply-config 실패는 건드리지 않는다(camera_health)" "$(deg DEGRADED 0 camera_health apply_config/FAILED 1000 1180 1400)" "- "
t_eq "apply-config 실패는 건드리지 않는다(gstapp)" "$(deg DEGRADED 0 gstapp apply_config/FAILED 1000 1180 1400)" "- "
t_eq "정지 요청 뒤에는 건드리지 않는다" "$(deg DEGRADED 0 gstapp gstapp_stop/SUCCEEDED 1000 1180 1400)" "- "
t_eq "마지막 요청이 성공이면 건드리지 않는다" "$(deg DEGRADED 0 camera_health camera_hard_reset/SUCCEEDED 1000 1180 1400)" "- "
t_eq "정지 요청이 실패한 경우도 건드리지 않는다" "$(deg DEGRADED 0 gstapp gstapp_stop/FAILED 1000 1180 1400)" "- "
t_eq "재부팅 요청이 실패한 경우는 건드리지 않는다" "$(deg DEGRADED 0 camera_health reboot_fallback/FAILED 1000 1180 1400)" "- "
t_eq "대상과 요청 종류가 어긋나면 건드리지 않는다" "$(deg DEGRADED 0 gstapp camera_hard_reset/FAILED 1000 1180 1400)" "- "
t_eq "대상과 요청 종류가 어긋나면 건드리지 않는다(재적재)" "$(deg DEGRADED 0 gstapp module_reload/FAILED 1000 1180 1400)" "- "
t_eq "이력이 없으면 건드리지 않는다" "$(deg DEGRADED 0 camera_health none 1000 1180 1400)" "- "
t_eq "건드리지 않은 사실과 근거를 남긴다" "$( deg DEGRADED 0 camera_health apply_config/FAILED 1000 1180 >/dev/null; grep -c 'DEGRADED retry skipped: not a failed recovery request (camera_health apply_config/FAILED)' "$WORK/log" )" 1
t_eq "낼 때는 근거가 된 대상과 요청을 남긴다" "$( deg DEGRADED 0 camera_health $F 1000 1180 >/dev/null; grep -c 'DEGRADED for 180s with file_check_reboot off after a failed recovery (camera_health camera_hard_reset/FAILED): request camera_hard_reset' "$WORK/log" )" 1
t_eq "이력을 읽지 못하면 내지 않고 unknown 으로 남긴다" "$(
    prep
    mkdir -p "$PIM_CAMERA_STATE_DIR/recovery/history"
    printf '{"degraded_target":"camera_health"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
    printf 'not json' > "$PIM_CAMERA_STATE_DIR/recovery/history/last.json"
    cam_submit_internal_action() { echo x >> "$WORK/req"; }
    PIM_CAMERA_AUTO_REBOOT=0; PIM_CAMERA_MONITOR_LIFECYCLE=DEGRADED
    up 1000; maybe_retry_degraded; up 1180; maybe_retry_degraded
    echo "$(wc -l < "$WORK/req") $(grep -c 'DEGRADED retry skipped: not a failed recovery request (unknown)' "$WORK/log")"
)" "0 1"
t_eq "가장 최근 항목을 읽지 못하면 내지 않는다" "$(
    prep
    mkdir -p "$PIM_CAMERA_STATE_DIR/recovery/history"
    printf '{"degraded_target":"camera_health"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
    printf '{"request":{"type":"camera_hard_reset","status":"FAILED"}}\n' > "$PIM_CAMERA_STATE_DIR/recovery/history/a-old.json"
    touch -d '2 hours ago' "$PIM_CAMERA_STATE_DIR/recovery/history/a-old.json"
    mkdir "$PIM_CAMERA_STATE_DIR/recovery/history/z-dir"
    cam_submit_internal_action() { echo x >> "$WORK/req"; }
    PIM_CAMERA_AUTO_REBOOT=0; PIM_CAMERA_MONITOR_LIFECYCLE=DEGRADED
    up 1000; maybe_retry_degraded; up 1180; maybe_retry_degraded
    echo "$(wc -l < "$WORK/req") $(grep -c 'DEGRADED retry skipped: not a failed recovery request (unknown)' "$WORK/log")"
)" "0 1"
t_eq "설정 간격을 따른다(300)" "$( DISCONNECT_INIT_CAM_INTERVAL_SEC=300; export DISCONNECT_INIT_CAM_INTERVAL_SEC; deg DEGRADED 0 camera_health $F 1000 1180 1299 1300 | cut -d' ' -f1 )" 1300
# DEGRADED 를 벗어났다가 다시 들어오면 처음부터 다시 잰다.
t_eq "벗어나면 관측 시각을 지운다" "$(
    prep
    mkdir -p "$PIM_CAMERA_STATE_DIR/recovery/history"
    printf '{"degraded_target":"camera_health"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
    printf '{"request":{"type":"camera_hard_reset","status":"FAILED"}}\n' > "$PIM_CAMERA_STATE_DIR/recovery/history/last.json"
    cam_submit_internal_action() { echo "$T" >> "$WORK/req"; }
    PIM_CAMERA_AUTO_REBOOT=0
    for step in DEGRADED:1000 ACTIVE:1100 DEGRADED:1150 DEGRADED:1329 DEGRADED:1330; do
        PIM_CAMERA_MONITOR_LIFECYCLE=${step%%:*}; T=${step##*:}; up "$T"; maybe_retry_degraded
    done
    tr '\n' ' ' < "$WORK/req"
)" "1330 "
t_eq "가동 시간을 못 읽으면 내지 않는다" "$(
    prep
    mkdir -p "$PIM_CAMERA_STATE_DIR/recovery/history"
    printf '{"degraded_target":"camera_health"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
    printf '{"request":{"type":"camera_hard_reset","status":"FAILED"}}\n' > "$PIM_CAMERA_STATE_DIR/recovery/history/last.json"
    cam_submit_internal_action() { echo x >> "$WORK/req"; }
    PIM_CAMERA_AUTO_REBOOT=0; PIM_CAMERA_MONITOR_LIFECYCLE=DEGRADED
    up 1000; maybe_retry_degraded; rm -f "$PIM_CAMERA_PROCESS_ROOT/uptime"; maybe_retry_degraded; maybe_retry_degraded
    wc -l < "$WORK/req"
)" 0

echo "=== DEGRADED 에서의 제출 ==="
# sub <owner lifecycle> <셋째 인자|none> : rc 와 cam_request_submit 이 받은 인자
sub() {
    (
        prep
        printf '{"lifecycle":"%s"}\n' "$1" > "$PIM_CAMERA_RUN_DIR/owner.json"
        cam_request_submit() { printf '%s|%s|%s' "$1" "$2" "$3" >> "$WORK/req"; return 0; }
        if [ "$2" = none ]; then cam_submit_internal_action camera_hard_reset "why"; else cam_submit_internal_action camera_hard_reset "why" "$2"; fi
        echo "rc=$? [$(cat "$WORK/req")]"
    )
}
t_eq "DEGRADED 는 평소처럼 거부" "$(sub DEGRADED none)" "rc=69 []"
t_eq "DEGRADED 라도 주기 재시도는 받는다" "$(sub DEGRADED 1)" "rc=0 [camera_hard_reset|monitor|why]"
t_eq "허용 표시가 0 이면 거부" "$(sub DEGRADED 0)" "rc=69 []"
t_eq "RECOVERING 은 허용 표시가 있어도 거부" "$(sub RECOVERING 1)" "rc=69 []"
t_eq "STOPPING 은 허용 표시가 있어도 거부" "$(sub STOPPING 1)" "rc=69 []"
t_eq "ACTIVE 는 그대로 받는다" "$(sub ACTIVE 1)" "rc=0 [camera_hard_reset|monitor|why]"

echo "=== 본문 루프의 배선 ==="
# 주기 재시도는 루프에서 한 번, init/restart 플래그 확인 뒤·끊김 주기 복구 앞에서 부른다.
t_eq "주기 재시도 호출은 한 곳" "$(grep -c -E '^[[:space:]]+maybe_retry_degraded \|\| :$' "$CHK")" 1
ln_flag=$(grep -n -F 'if [ -f /tmp/init_cam_flag ] || [ -f /tmp/restart_flag ]; then' "$CHK" | head -1 | cut -d: -f1)
ln_call=$(grep -n -E '^[[:space:]]+maybe_retry_degraded \|\| :$' "$CHK" | cut -d: -f1)
ln_disc=$(grep -n -F 'if maybe_init_cam_on_disconnect; then' "$CHK" | cut -d: -f1)
if [ -n "$ln_flag" ] && [ -n "$ln_call" ] && [ -n "$ln_disc" ] && [ "$ln_flag" -lt "$ln_call" ] && [ "$ln_call" -lt "$ln_disc" ]; then
    t_ok "플래그 확인($ln_flag) < 주기 재시도($ln_call) < 끊김 주기 복구($ln_disc)"
else
    t_bad "호출 위치가 어긋남: flag=$ln_flag call=$ln_call disc=$ln_disc"
fi
for why in "file check failure" "gstapp start marker missing" "driver load failure" "final path stall"; do
    t_eq "쉬는지 묻는 곳: $why" "$(grep -c -F "ladder_on_hold \"$why\"" "$CHK")" 1
done
t_eq "대기를 시작하는 곳은 넷(사다리 넷의 초기화 자리)" "$(grep -c -E '^[[:space:]]+ladder_hold_start$' "$CHK")" 4
t_eq "실행기가 lifecycle 을 내놓는다" "$(grep -c -F 'PIM_CAMERA_MONITOR_LIFECYCLE=$lifecycle' "$PIM_LIB/cam_operate_control.sh")" 1
# 상태·이력 파일은 실행기 라이브러리만 읽는다(test/camera_health/runtime_consumer_path_test.py 의 경계).
t_eq "원인 판정은 실행기 함수에 맡긴다" "$(grep -c -E '^[[:space:]]+if ! cam_degraded_by_failed_recovery; then$' "$CHK")" 1
t_eq "감시 스크립트는 복구 이력을 직접 읽지 않는다" "$(grep -c 'recovery/history' "$CHK")" 0

t_summary "사다리 대기·DEGRADED 재시도"
