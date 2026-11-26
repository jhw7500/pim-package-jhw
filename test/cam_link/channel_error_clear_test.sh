#!/bin/bash
# BG_Check_for_pim.sh 가 채널 오류 표시를 점검 주기마다 그 주기의 검사 결과로 맞추는지 검증
# 사용법: bash test/cam_link/channel_error_clear_test.sh
#
# 배경: BG_Check 는 chk_cam_connect.sh 가 남긴 err_camN.log 를 보고
# /tmp/cam_state/channels/chN_error 를 true 로 세운다. 지우는 코드는 없었다. 그래서 링크가
# 끊겼다가 module_reload 로 복구된 뒤에도 재부팅 전까지 true 로 남았다
# (2026-11-26 실측: state=healthy, streak=0 인데 ch0_error·ch1_error=true).
#
# 출하 스크립트에서 함수 두 개와 루프 끝의 판정 블록을 그대로 꺼내 돌린다. 시험에 옮겨 적지
# 않으므로 출하 코드가 바뀌면 이 시험의 결과도 따라 바뀐다.
# cam_state.sh 는 STATE_DIR 을 임시 폴더로 돌려 실제 /tmp/cam_state 는 쓰지 않는다.
# BG_CHECK_SRC 로 다른 판의 BG_Check 를 지정할 수 있다(수정 전 판이 실패하는지 대조할 때).
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
BG="${BG_CHECK_SRC:-$PIM_BIN/BG_Check_for_pim.sh}"

t_extract_func "$BG" err_cam_chs                  "$WORK/f1" || exit 1
t_extract_func "$BG" update_cam_state_from_errors "$WORK/f2" || exit 1

# 루프 끝의 판정 블록: `err_chs=$(err_cam_chs)` 줄부터 그 뒤 첫 `fi` 줄까지.
awk '
    /^[[:space:]]*err_chs=\$\(err_cam_chs\)[[:space:]]*$/ { on = 1 }
    on { print }
    on && /^[[:space:]]*fi[[:space:]]*$/ { exit }
' "$BG" > "$WORK/tail.sh"
if ! grep -q 'cam_inc_streak' "$WORK/tail.sh" || ! grep -q 'cam_reset_streak' "$WORK/tail.sh"; then
    echo "판정 블록을 찾지 못했다(BG_Check 의 구조가 바뀌었는가): $BG" >&2
    exit 1
fi

export STATE_DIR="$WORK/state"
FLAG_PATH="$WORK/flags"; mkdir -p "$FLAG_PATH"
tag=test
logger() { :; }                                  # syslog 오염 방지
# shellcheck disable=SC1090
source "$PIM_LIB/cam_state.sh"
cam_state_init
# BG_Check 의 streak_get/streak_set 은 /tmp/cam_state/streak 을 직접 쓴다. 임시 폴더로 돌린다.
streak_get() {
    local v; v=$(cat "$STATE_DIR/streak" 2>/dev/null | tr -d '\n')
    [[ "$v" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
    echo "$v"
}
streak_set() { printf '%s' "$1" > "$STATE_DIR/streak" 2>/dev/null; }
# shellcheck disable=SC1090
source "$WORK/f1"
# shellcheck disable=SC1090
source "$WORK/f2"

# 점검 주기 한 번. $@ = 이번 주기에 링크 오류가 난 채널 번호들(없으면 오류 없는 주기).
cycle() {
    local c
    rm -f "$FLAG_PATH"/err_cam*.log              # 루프 머리의 CLEAR_CHK_LOG 에 해당
    for c in "$@"; do echo "t CAM$c ERR" >> "$FLAG_PATH/err_cam$c.log"; done
    update_cam_state_from_errors
    # shellcheck disable=SC1090
    source "$WORK/tail.sh"
}
flags() {
    local c out=""
    for c in 0 1 2 3; do out="$out$(cat "$STATE_DIR/channels/ch${c}_error" 2>/dev/null)"; [ "$c" -lt 3 ] && out="$out,"; done
    printf '%s' "$out"
}
snap() { printf 'flags=%s state=%s streak=%s' "$(flags)" "$(cat "$STATE_DIR/state")" "$(cat "$STATE_DIR/streak")"; }

echo "=== 처음 — 오류 없음 ==="
cycle
t_eq "오류 없는 주기"                         "$(snap)" "flags=false,false,false,false state=healthy streak=0"

echo
echo "=== ch0·ch1 링크 오류가 이어지는 동안 ==="
cycle 0 1
t_eq "1주기째 — 표시가 선다"                  "$(snap)" "flags=true,true,false,false state=healthy streak=1"
cycle 0 1
t_eq "2주기째 — degraded"                     "$(snap)" "flags=true,true,false,false state=degraded streak=2"

echo
echo "=== 복구 뒤 — 오류 없는 주기 ==="
cycle
t_eq "표시가 지워지고 healthy 로 돌아온다"    "$(snap)" "flags=false,false,false,false state=healthy streak=0"
cycle
t_eq "다음 주기에도 그대로"                   "$(snap)" "flags=false,false,false,false state=healthy streak=0"

echo
echo "=== 일부만 풀린 경우 — 채널마다 그 주기의 결과를 따른다 ==="
cycle 0 1
cycle 1
t_eq "ch1 만 계속 오류 — ch0 표시는 지워진다" "$(flags)" "false,true,false,false"
cycle
t_eq "모두 풀리면 전부 false"                 "$(flags)" "false,false,false,false"

echo
echo "=== 다른 채널에서 다시 나면 그 채널만 선다 ==="
cycle 3
t_eq "ch3 만"                                 "$(flags)" "false,false,false,true"
cycle 0 2
t_eq "ch0·ch2 로 바뀌면 ch3 은 지워진다"      "$(flags)" "true,false,true,false"
cycle
t_eq "풀리면 지운다"                          "$(flags)" "false,false,false,false"

echo
echo "=== 루프가 이 함수를 주기마다 부르는가 ==="
# 정의 줄(`...() {`)을 뺀 호출은 루프 안의 한 곳이어야 한다. 조건문 안으로 옮겨지면 표시가 다시 남는다.
t_eq "호출부 수"  "$(grep -c -E '^[[:space:]]*update_cam_state_from_errors[[:space:]]*$' "$BG")" "1"

t_summary "채널 오류 표시 맞추기"
