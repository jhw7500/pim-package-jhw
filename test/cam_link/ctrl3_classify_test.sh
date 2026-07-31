#!/bin/bash
# chk_cam_connect.sh 의 CTRL3(0x13) 판정 검증
# 사용법: bash test/cam_link/ctrl3_classify_test.sh
#
# 관측값 근거:
#  - 1호기 로그(2026-07-23 17:28~18:22) 82건: 0xda 35 / 0xea 26 / 0xde 10 / 0xfe 7 / 0x36 3 / 0x12 1
#  - 벤치 실측(2026-07-30, cam-operate 정지): 0xfa(정상) / 0x32(한쪽 제거) / 0x22(리셋 직후)
#
# MAX9296 CTRL3(0x13): bit5:4=LINK_MODE, bit3=LOCKED, bit2=ERROR(ERRB),
#                      bit1=CMU_LOCKED, bit7/6/0=예약
#
# 핵심 원칙: CTRL3 의 LOCKED 는 링크별이 아니라 집계 비트 하나다. 벤치에서 듀얼 구성 중
# ch0 를 뽑든 ch1 을 뽑든 같은 값(0x32)이 나왔으므로, 이 레지스터로 채널을 귀속하면 안 된다.
# 따라서 듀얼 구성의 모든 이상은 err_both / mode_unexpected 로만 나와야 한다.
source "$(dirname "$0")/lib.sh"

DEFS=$(mktemp)
trap 'rm -f "$DEFS"' EXIT
t_extract_head "$PIM_BIN/chk_cam_connect.sh" '^cam_ch_en=\$1' "$DEFS" || exit 1
# shellcheck disable=SC1090
source "$DEFS"

# $1=원시값 $2=기대 LINK_MODE $3=기대 verdict $4=설명
check() {
    classify_ctrl3 "$1" "$2"
    t_eq "$4" "$ctrl3_verdict" "$3"
}

echo "=== 양 채널 활성 (기대 LINK_MODE = Splitter) ==="
check 0xfa "$LM_BOTH_EXPECT" ok              "0xfa Splitter+LOCKED → 정상"
check 0xfe "$LM_BOTH_EXPECT" errb_only       "0xfe Splitter+LOCKED+ERRB → 플래그 금지"
check 0x36 "$LM_BOTH_EXPECT" err_both        "0x36 LOCKED=0 → 링크 단위 사건"
check 0x32 "$LM_BOTH_EXPECT" err_both        "0x32 벤치: 한쪽 제거 시 관측값"
check 0x12 "$LM_BOTH_EXPECT" err_both        "0x12 LOCKED=0"
check 0x16 "$LM_BOTH_EXPECT" err_both        "0x16 구 CAM01_ERR 상수값"
check 0x22 "$LM_BOTH_EXPECT" err_both        "0x22 벤치: 리셋 직후 관측값(LOCKED=0)"

echo
echo "=== 채널 귀속 금지 — 단일링크 값은 전부 mode_unexpected 여야 한다 ==="
# 이 값들은 과거 CAM0_ERR/CAM1_ERR 로 채널을 지목하던 것이다. 실측에서 그 지목은
# 독립 증거(gstApp Fragment opened)와 0/10 일치였고, 값 자체가 스크립트의 리셋이
# 만들어낸 것이었다. 듀얼 구성에서 채널을 특정하는 판정이 되살아나면 실패한다.
check 0xda "$LM_BOTH_EXPECT" mode_unexpected "0xda 구 CAM0_ERR → 채널 귀속 안 함"
check 0xea "$LM_BOTH_EXPECT" mode_unexpected "0xea 구 CAM1_ERR → 채널 귀속 안 함"
check 0xde "$LM_BOTH_EXPECT" mode_unexpected "0xde 구 CAM01_ERR(else) → 채널 귀속 안 함"
check 0x0a "$LM_BOTH_EXPECT" mode_unexpected "0x0a Dual 모드 → 기대 모드 아님"

echo
echo "=== i2c 읽기 실패는 별도 verdict ==="
check ""                   "$LM_BOTH_EXPECT" read_fail "빈 출력"
check "Error: Read failed" "$LM_BOTH_EXPECT" read_fail "i2c 에러 문자열"

echo
echo "=== 단일 채널 활성 — 드라이버가 설정한 단일링크 모드는 정상이다 ==="
# 매핑 실측 확정(2026-07-31): ch0=Link A(0xd*), ch1=Link B(0xe*)
check 0xda "$CH_EVEN_LINK" ok "ch0 단독: Link A 와 일치"
check 0xea "$CH_ODD_LINK"  ok "ch1 단독: Link B 와 일치"
check 0xea "$CH_EVEN_LINK" mode_unexpected "ch0 단독인데 Link B → swap 후보"

echo
echo "=== 채널<->링크 매핑이 실측값과 일치하는가 (회귀 방지) ==="
# RX3 FAILLOCK 실측: ch0 제거 → 0x01(FAILLOCK_A), ch1 제거 → 0x10(FAILLOCK_B)
t_eq "ch0/ch2 = Link A" "$CH_EVEN_LINK" "$LM_LINK_A"
t_eq "ch1/ch3 = Link B" "$CH_ODD_LINK"  "$LM_LINK_B"

echo
echo "=== 예약비트(7/6/0) 는 판정에 영향이 없어야 ==="
check 0x3a "$LM_BOTH_EXPECT" ok "0xfa 에서 예약 bit7/6 만 0"
check 0xfb "$LM_BOTH_EXPECT" ok "0xfa 에서 예약 bit0 만 1"

echo
echo "=== 리셋 관련 코드가 되살아나지 않았는가 (회귀 방지) ==="
t_eq "ctrl3_needs_reset 미정의" "$(type -t ctrl3_needs_reset || echo none)" "none"
t_eq "CTRL0(0x0010) write 없음" \
     "$(grep -c 'w3@0x4[08] 0x00 0x10' "$PIM_BIN/chk_cam_connect.sh")" "0"
# 단순히 문자열이 있는지 보면 역사적 맥락 주석에도 오탐한다. verdict 를 실제로
# 대입하는 구문만 센다.
t_eq "채널 귀속 verdict 대입 없음" \
     "$(grep -cE 'ctrl3_verdict="(err_even|err_odd)"' "$PIM_BIN/chk_cam_connect.sh")" "0"

t_summary "CTRL3 판정"
