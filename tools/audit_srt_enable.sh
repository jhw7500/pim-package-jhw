#!/bin/bash
# audit_srt_enable.sh
# vcm 디폴트 변경(TRUE → FALSE) 대응. 운영 단말의 ord_vcm_conf.json에서
# .VCM.srt_enable 키 누락 여부를 식별한다.
#
# 사용:
#   sudo ./audit_srt_enable.sh
#   결과:
#     OK            : 키 명시 (value 표시)
#     AFFECTED      : 키 누락 → 디폴트 FALSE로 전환됨 (SRT 비활성). 마이그레이션 필요.
#     NOT_FOUND     : conf 파일 자체가 없음
#
# 패치 vcm 배포 전 fleet 전체에 실행하여 영향 단말 식별 후
# migrate_srt_enable.sh 로 명시값 추가.

set -u

PATHS=(
    "/root/shared_v/ord_vcm_conf.json"
    "/home/root/ord_vcm_conf.json"
)

found=0
for p in "${PATHS[@]}"; do
    if [ -f "$p" ]; then
        found=1
        v=$(jq -e '.VCM.srt_enable' "$p" 2>/dev/null)
        rc=$?
        if [ $rc -eq 0 ]; then
            echo "OK $p srt_enable=$v"
        else
            echo "AFFECTED $p (key missing → after patch: FALSE)"
        fi
    fi
done

if [ $found -eq 0 ]; then
    echo "NOT_FOUND (no ord_vcm_conf.json in known paths)"
    exit 2
fi
