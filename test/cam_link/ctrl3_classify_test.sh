#!/bin/bash
# chk_cam_connect.sh 의 CTRL3(0x13) 판정 검증
# 사용법: bash test/cam_link/ctrl3_classify_test.sh
#
# 관측값 근거: 1호기 로그(2026-07-23 17:28~18:22) 82건.
#   0xda 35 / 0xea 26 / 0xde 10 / 0xfe 7 / 0x36 3 / 0x12 1
# MAX9296 CTRL3(0x13): bit5:4=LINK_MODE, bit3=LOCKED, bit2=ERROR(ERRB),
#                      bit1=CMU_LOCKED, bit7/6/0=예약
source "$(dirname "$0")/lib.sh"

DEFS=$(mktemp)
trap 'rm -f "$DEFS"' EXIT
t_extract_head "$PIM_BIN/chk_cam_connect.sh" '^cam_ch_en=\$1' "$DEFS" || exit 1
# shellcheck disable=SC1090
source "$DEFS"

# $1=원시값 $2=기대 LINK_MODE $3=기대 verdict $4=기대 리셋여부(Y/N) $5=설명
check() {
    classify_ctrl3 "$1" "$2"
    local reset="N"
    ctrl3_needs_reset "$ctrl3_verdict" && reset="Y"
    t_eq "$5" "$ctrl3_verdict/$reset" "$3/$4"
}

echo "=== 양 채널 활성 (기대 LINK_MODE = Splitter) ==="
check 0xfa "$LM_BOTH_EXPECT" ok        N "0xfa 정상"
check 0xda "$LM_BOTH_EXPECT" err_even  Y "0xda Link A 단독 → 짝수 채널 소실"
check 0xea "$LM_BOTH_EXPECT" err_odd   Y "0xea Link B 단독 → 홀수 채널 소실"
check 0xde "$LM_BOTH_EXPECT" err_even  Y "0xde 단독+ERRB (구 코드는 양쪽고장 오분류)"
check 0xfe "$LM_BOTH_EXPECT" errb_only N "0xfe 링크정상+ERRB만 → 리셋 금지"
check 0x36 "$LM_BOTH_EXPECT" err_both  Y "0x36 LOCKED=0 실제 다운"
check 0x12 "$LM_BOTH_EXPECT" err_both  Y "0x12 LOCKED=0 실제 다운"
check 0x16 "$LM_BOTH_EXPECT" err_both  Y "0x16 구 CAM01_ERR 상수값"
check 0x0a "$LM_BOTH_EXPECT" unknown   N "0x0a Dual 모드 = 유효값이나 미정의 → 무플래그"

echo
echo "=== i2c 읽기 실패는 unknown 과 구분해 에러로 올린다 ==="
check ""                    "$LM_BOTH_EXPECT" read_fail Y "빈 출력"
check "Error: Read failed"  "$LM_BOTH_EXPECT" read_fail Y "i2c 에러 문자열"

echo
echo "=== 단일 채널 활성 — 구 CH*_EN_OK 상수와 동일 판정 ==="
check 0xea "$CH_EVEN_LINK" ok N "ch0 단독: 구 CH0_EN_OK=0xea"
check 0xda "$CH_ODD_LINK"  ok N "ch1 단독: 구 CH1_EN_OK=0xda"

echo
echo "=== 예약비트(7/6/0) 는 판정에 영향이 없어야 ==="
check 0x3a "$LM_BOTH_EXPECT" ok N "0xfa 에서 예약 bit7/6 만 0"
check 0xfb "$LM_BOTH_EXPECT" ok N "0xfa 에서 예약 bit0 만 1"

t_summary "CTRL3 판정"
