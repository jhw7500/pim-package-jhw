#!/bin/bash
# 카메라 링크 판정·복구 로직 테스트 전체 실행
# 사용법: bash test/cam_link/run_all.sh [-v]
#   -v : 각 테스트의 상세 출력까지 표시
#
# 하드웨어 없이 동작한다. 실패가 하나라도 있으면 종료코드 1.
cd "$(dirname "$0")" || exit 1

VERBOSE=0
[ "$1" = "-v" ] && VERBOSE=1

TESTS=(
    ctrl3_classify_test.sh
    streak_test.sh
    escalation_test.sh
    config_default_test.sh
    initcam_modprobe_test.sh
    flag_e2e_test.sh
)

fail=0
for t in "${TESTS[@]}"; do
    if [ "$VERBOSE" -eq 1 ]; then
        echo "═══ $t ═══"
        bash "$t" && r=0 || r=1
        echo
    else
        out=$(bash "$t" 2>&1) && r=0 || r=1
        [ "$r" -ne 0 ] && { echo "$out"; echo; }
    fi
    if [ "$r" -eq 0 ]; then
        printf "PASS  %s\n" "$t"
    else
        printf "FAIL  %s\n" "$t"
        fail=1
    fi
done

echo
if [ "$fail" -eq 0 ]; then
    echo "전체 통과 (${#TESTS[@]}개)"
else
    echo "실패 있음"
fi
exit $fail
