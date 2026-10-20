#!/bin/bash
# chk_cam_operate.sh 의 재기동 직후 파일 검사 보류(file_check_startup_hold, #190) 검증
# 사용법: bash test/cam_link/file_check_startup_hold_test.sh
#
# 배경: 파일 검사는 vcm 의 분 경계 마커 기준으로 판정해, prepare 중인 갓 뜬 gstApp 이 아직 만들 수 없던
# 조각을 누락으로 보고 gstapp_restart → module_reload → reboot fallback 사다리를 탔다(.4 시작 +26초 판정).
# 세션 파일(첫 조각 신호)이 없고 앱이 init_cooldown_sec 보다 어릴 때만 보류하고, 보류가 그보다 길게
# 이어지면 판정해 진짜 누락 검출은 유지한다.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
t_extract_func "$PIM_BIN/chk_cam_operate.sh" file_check_startup_hold "$WORK/hold.sh" || exit 1
t_extract_func "$PIM_LIB/cam_recovery_actions.sh" cam_process_start_time "$WORK/start.sh" || exit 1

# fake_proc <pid> <나이초> — uptime 1000초 기준, 나이만큼 늦게 시작한 프로세스의 stat 을 만든다
fake_proc() {
    mkdir -p "$WORK/proc/$1"
    printf '%s (app) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 %s 20 21\n' "$1" "$(( (1000 - $2) * 100 ))" > "$WORK/proc/$1/stat"
}

# run_h <설명> <세션 파일 내용[@NOW-몇 초에 썼나]> <앱 이름> <pgrep 이 낼 pid 들> <HOLD_SINCE 오프셋(NOW-값, 0=없음)> <기대 rc> <기대 since(0|held)> [로그에 있어야 할 문자열]
# 시각은 NOW 로 고정한다(date +%s 스텁). 두 번 재면 초 경계에서 로그의 held 값이 1 어긋난다.
NOW=1800000000
run_h() {
    local out rc since log
    out=$(
        KEY=RST; tag=chk_cam_operate.sh; init_cooldown_sec=40; CLK_TCK=100
        PIM_CAMERA_PROCESS_ROOT="$WORK/proc"; PIM_CAMERA_RUNTIME_JSON="$WORK/runtime.json"
        SESSION_FILE_="$WORK/session"; printf '%s' "${2%@*}" > "$SESSION_FILE_"
        case "$2" in *@*) touch -d "@$((NOW - ${2##*@}))" "$SESSION_FILE_";; esac
        APP="$3"; PIDS="$4"
        date() { if [ "$1" = +%s ]; then echo "$NOW"; else command date "$@"; fi; }
        _cam_runtime_app_into() { printf -v "$1" '%s' "$APP"; }
        pgrep() { [ "$1" = -x ] && [ "$2" = "$APP" ] && [ -n "$PIDS" ] && printf '%s\n' $PIDS; }
        logger() { printf '%s\n' "$*" >> "$WORK/log"; }
        : > "$WORK/log"
        source "$WORK/start.sh"; source "$WORK/hold.sh"
        now=$NOW
        if [ "$5" = 0 ]; then FILE_CHECK_HOLD_SINCE=0; else FILE_CHECK_HOLD_SINCE=$((now - $5)); fi
        file_check_startup_hold "20261020 10:35:00"; rc=$?
        [ "$FILE_CHECK_HOLD_SINCE" -gt 0 ] && s=held || s=0
        printf '%s %s\n' "$rc" "$s"
    )
    rc=${out% *}; since=${out#* }
    t_eq "$1 (rc)" "$rc" "$6"
    t_eq "$1 (보류 시작 시각)" "$since" "$7"
    if [ -n "${8:-}" ]; then
        log=$(cat "$WORK/log")
        case "$log" in *"$8"*) t_ok "$1 (로그: $8)";; *) t_bad "$1 (로그에 '$8' 없음: [$log])";; esac
    fi
}

mkdir -p "$WORK/proc"; printf '1000.50 2000.00\n' > "$WORK/proc/uptime"
fake_proc 101 10      # 갓 뜬 앱
fake_proc 202 500     # 오래 산 앱

echo "=== 재기동 직후 파일 검사 보류 ==="
# 앱 101 은 NOW-10 에 떴다. 세션 파일을 그 뒤(NOW-5)에 썼으면 이 앱이 첫 조각을 연 것이다.
run_h "앱이 뜬 뒤 쓴 세션 값(이미 녹화 중) → 판정"        "20261020_1035@5"  gstApp "101" 0  1 0
run_h "앱이 뜬 뒤 쓴 세션 값 → 이전 보류 해제"            "20261020_1035@5"  gstApp "101" 30 1 0
# 이전 인스턴스가 분 경계에 쓴 값이 남아 있다(재기동 정리가 그 분 파일을 지웠다) → 신호로 보지 않는다
run_h "앱보다 먼저 쓴 세션 값(이전 인스턴스) → 보류"       "20261020_1035@60" gstApp "101" 0  0 held "skip file check: gstApp pid=101 age=10s < 40s"
run_h "세션 값 있음 + 앱 500초 → 판정"                   "20261020_1035@60" gstApp "202" 0  1 0
run_h "세션 파일 없음 + 앱 10초 → 보류"                  ""              gstApp "101" 0  0 held "skip file check: gstApp pid=101 age=10s < 40s"
run_h "세션 파일 없음 + 앱 500초 → 판정"                 ""              gstApp "202" 0  1 0
run_h "세션 파일 없음 + 앱 없음 → 판정(지금처럼)"         ""              gstApp ""    0  1 0
run_h "stat 못 읽는 pid → 앱 없음과 같게 판정"            ""              gstApp "999" 0  1 0
run_h "보류 30초째 → 계속 보류"                          ""              gstApp "101" 30 0 held "held 30s"
run_h "보류 50초째(상한 40 넘음) → 판정하고 해제"          ""              gstApp "101" 50 1 0
run_h "앱 여럿이면 가장 어린 것 기준 → 보류"              ""              gstApp "202 101" 0 0 held "pid=101 age=10s"
run_h "런타임 앱 이름(PIMCAM)을 쓴다 → 보류"              ""              PIMCAM "101" 0  0 held "skip file check: PIMCAM pid=101"

echo "=== 호출부 ==="
# 보류 분기는 마커와 세션 파일을 비우고, 그 밖은 지금 판정 블록으로 간다(elif 가 원래 조건을 그대로 쓴다).
call=$(grep -n -A4 '&& file_check_startup_hold "\$startTime"; then' "$PIM_BIN/chk_cam_operate.sh")
case "$call" in *'cat /dev/null > $FILE_'*'cat /dev/null > "$SESSION_FILE_"'*'elif [ "$diffEpoch" -ge "$file_check_delay" ]; then'*)
    t_ok "보류 분기가 마커·세션 파일을 비우고 elif 로 기존 판정에 이어진다";;
*) t_bad "호출부 형태가 다르다: [$call]";;
esac
bash -n "$PIM_BIN/chk_cam_operate.sh" && t_ok "chk_cam_operate.sh 문법" || t_bad "chk_cam_operate.sh 문법"

t_summary "파일 검사 보류"
