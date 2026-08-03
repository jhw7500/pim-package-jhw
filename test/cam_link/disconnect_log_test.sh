#!/bin/bash
# BG_Check_for_pim.sh 의 disconnect 로그 채널 표기 검증
# 사용법: bash test/cam_link/disconnect_log_test.sh
#
# 배경: 현장 로그가 어느 채널이 빠졌는지 알려주지 않았다.
#   [CHK][BG_Check_for_pim.sh:223] driver detected disconnect, skip chk_cam_connect
#   [CHK][BG_Check_for_pim.sh:257] cam disconnect : 4
# 뒤쪽 '4'는 채널이 아니라 streak(연속 실패 횟수)라 오해를 부른다.
# check_driver_disconnect() 는 이미 채널 비트마스크를 계산하면서 호출자에게
# 넘기지 않고 버리고 있었다.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
FN="$WORK/fns.sh"
trap 'rm -rf "$WORK"' EXIT

t_extract_func "$PIM_BIN/BG_Check_for_pim.sh" mask_to_chs             "$WORK/f1" || exit 1
t_extract_func "$PIM_BIN/BG_Check_for_pim.sh" err_cam_chs             "$WORK/f2" || exit 1
t_extract_func "$PIM_BIN/BG_Check_for_pim.sh" check_driver_disconnect "$WORK/f3" || exit 1
cat "$WORK/f1" "$WORK/f2" "$WORK/f3" > "$FN"
# shellcheck disable=SC1090
source "$FN"

echo "=== mask_to_chs — 비트마스크를 채널 목록으로 ==="
t_eq "0x0 (없음)"        "$(mask_to_chs 0)"  ""
t_eq "0x1 → ch0"         "$(mask_to_chs 1)"  "ch0"
t_eq "0x2 → ch1"         "$(mask_to_chs 2)"  "ch1"
t_eq "0x3 → ch0 ch1"     "$(mask_to_chs 3)"  "ch0 ch1"
t_eq "0x4 → ch2"         "$(mask_to_chs 4)"  "ch2"
t_eq "0x8 → ch3"         "$(mask_to_chs 8)"  "ch3"
t_eq "0xf → 전 채널"     "$(mask_to_chs 15)" "ch0 ch1 ch2 ch3"
t_eq "0x9 → ch0 ch3"     "$(mask_to_chs 9)"  "ch0 ch3"

echo
echo "=== err_cam_chs — 플래그 파일이 있는 채널 ==="
FLAG_PATH="$WORK/flags"; mkdir -p "$FLAG_PATH"
t_eq "플래그 없음" "$(err_cam_chs)" ""
: > "$FLAG_PATH/err_cam1.log"
t_eq "ch1 만"      "$(err_cam_chs)" "ch1"
: > "$FLAG_PATH/err_cam3.log"
t_eq "ch1 ch3"     "$(err_cam_chs)" "ch1 ch3"
rm -f "$FLAG_PATH"/err_cam*.log
t_eq "다시 없음"   "$(err_cam_chs)" ""

echo
echo "=== check_driver_disconnect — 채널 마스크를 전역으로 넘기는가 ==="
# $1=설명 $2=i2c2 sysfs값 $3=i2c1 sysfs값 $4=cam_ch_bit
# $5=기대 리턴(0=disconnect 있음) $6=기대 채널목록
run_d() {
    SYSFS_LINK_I2C2="$WORK/link2"; SYSFS_LINK_I2C1="$WORK/link1"
    printf '%s\n' "$2" > "$SYSFS_LINK_I2C2"
    printf '%s\n' "$3" > "$SYSFS_LINK_I2C1"
    cam_ch_bit="$4"
    rm -f "$FLAG_PATH"/err_cam*.log
    drv_disconnect_mask=-1; drv_mask_i2c2=-1; drv_mask_i2c1=-1
    check_driver_disconnect && rc=0 || rc=1
    t_eq "$1" "rc=$rc chs=[$(mask_to_chs "$drv_disconnect_mask")] flags=[$(err_cam_chs)]" \
              "rc=$5 chs=[$6] flags=[$6]"
}

run_d "정상(0/0)"                      0  0  15 1 ""
run_d "i2c2=1 → ch0"                   1  0  15 0 "ch0"
run_d "i2c2=2 → ch1"                   2  0  15 0 "ch1"
run_d "i2c2=3 → ch0 ch1"               3  0  15 0 "ch0 ch1"
run_d "i2c1=4 → ch2"                   0  4  15 0 "ch2"
run_d "양쪽(i2c2=1,i2c1=8) → ch0 ch3"  1  8  15 0 "ch0 ch3"
run_d "미확인(-1) 은 0 으로 취급"      -1 -1 15 1 ""
# cam_ch_bit 로 비활성 채널은 걸러진다 — ch0 만 사용 중인데 드라이버가 ch1 도 보고
run_d "cam_ch_bit=1 이면 ch1 보고 무시" 3  0  1  0 "ch0"

echo
echo "=== 로그 라인이 채널을 담는가 (문자열 회귀 방지) ==="
SRC="$PIM_BIN/BG_Check_for_pim.sh"
t_eq "223행류 — driver detected disconnect 에 mask_to_chs 포함" \
     "$(grep -c 'driver detected disconnect(\$(mask_to_chs' "$SRC")" 1
t_eq "257행류 — cam disconnect 에 err_chs 포함" \
     "$(grep -c 'cam disconnect : streak=\$streak (\$err_chs)' "$SRC")" 1
# streak 단독 표기로 되돌아가면 다시 채널을 알 수 없게 된다
t_eq "옛 형식(cam disconnect : \$streak 단독) 잔존 없음" \
     "$(grep -cE 'cam disconnect : \$streak"' "$SRC")" 0

echo
echo "=== disconnect 분기: RX3 동반 표기 + 폭주 억제 ==="
# 드라이버 마스크는 splitter 에서 한쪽만 빠져도 두 채널을 다 세운다. 그 자리에서
# RX3 를 읽어 채널을 갈라 주는지, 그리고 같은 상태가 이어질 때 로그를 억제하는지 본다.
SRC_BG="$PIM_BIN/BG_Check_for_pim.sh"
START=$(grep -n '^    if check_driver_disconnect; then$' "$SRC_BG" | head -1 | cut -d: -f1)
END=$(awk -v s="$START" 'NR>s && /^    fi$/{print NR; exit}' "$SRC_BG")
[ -n "$START" ] && [ -n "$END" ] || { echo "disconnect 분기 추출 실패" >&2; exit 1; }
sed -n "${START},${END}p" "$SRC_BG" > "$WORK/branch.sh"

# $1=설명 $2=반복횟수 $3=틱당 증가초 $4=rx3 문자열 $5=기대 로그 줄수
run_branch() {
    local out
    out=$(
        tag=BG_Check_for_pim.sh; cam_ch_bit=15
        DISCONNECT_LOG_REPEAT_SEC=60
        drv_log_sig=""; drv_log_ts=0
        NOW=1000
        # 함수 안의 $4 는 그 함수의 인자다. run_branch 의 것을 쓰려면 먼저 담아야 한다.
        RX3V="$4"
        check_driver_disconnect() {
            drv_disconnect_mask=3; drv_mask_i2c2=3; drv_mask_i2c1=0; return 0
        }
        read_rx3_links() { printf '%s' "$RX3V"; }
        now_ts() { echo "$NOW"; }
        logger() { echo "$*"; }
        # shellcheck disable=SC1090
        source "$WORK/f1"   # mask_to_chs
        for _ in $(seq 1 "$2"); do
            # shellcheck disable=SC1090
            source "$WORK/branch.sh"
            NOW=$((NOW + $3))
        done
    ) 2>/dev/null
    t_eq "$1 · 로그 줄수" "$(printf '%s' "$out" | grep -c 'driver detected disconnect')" "$5"
    printf '%s' "$out" | head -1 | grep -q "$4" \
        && t_ok "$1 · 로그에 rx3 포함" \
        || t_bad "$1 · 로그에 rx3 없음 → [$(printf '%s' "$out" | head -1)]"
}

# 틱 5초 x 5회 = 20초 경과 → 첫 회만 (상태 동일, 60초 미만)
run_branch "동일 상태 5틱(20초)" 5 5 "0x06/ch0_down" 1
# 틱 60초 x 3회 → 매번 재확인 간격 도달
run_branch "60초 간격 3틱"      3 60 "0x06/ch0_down" 3

# 상태가 바뀌면 간격과 무관하게 즉시 찍혀야 한다
out=$(
    tag=BG_Check_for_pim.sh; cam_ch_bit=15
    DISCONNECT_LOG_REPEAT_SEC=60
    drv_log_sig=""; drv_log_ts=0
    NOW=1000; RX3="0x06/ch0_down"
    check_driver_disconnect() { drv_disconnect_mask=3; drv_mask_i2c2=3; drv_mask_i2c1=0; return 0; }
    read_rx3_links() { printf '%s' "$RX3"; }
    now_ts() { echo "$NOW"; }
    logger() { echo "$*"; }
    # shellcheck disable=SC1090
    source "$WORK/f1"
    for i in 1 2 3; do
        [ "$i" = "3" ] && RX3="0x60/ch1_down"    # 3틱째에 반대 채널로 전환
        # shellcheck disable=SC1090
        source "$WORK/branch.sh"
        NOW=$((NOW + 5))
    done
) 2>/dev/null
t_eq "상태 변화 시 즉시 로깅(2줄)" \
     "$(printf '%s' "$out" | grep -c 'driver detected disconnect')" "2"
t_eq "변화 후 줄이 새 채널을 담는가" \
     "$(printf '%s' "$out" | grep -c 'ch1_down')" "1"

t_summary "disconnect 로그 채널 표기"
