#!/bin/bash
# migrate_srt_enable.sh
# .VCM.srt_enable 키가 없는 ord_vcm_conf.json에 명시값을 추가한다.
# 기본 추가값: true (기존 vcm 디폴트 TRUE 동작 유지).
#
# 사용:
#   sudo ./migrate_srt_enable.sh           # 기본: srt_enable=true 추가
#   sudo ./migrate_srt_enable.sh false     # SRT 명시적으로 비활성
#
# 동작:
#   - 키가 이미 있으면 변경 없음
#   - 백업은 conf.json.bak.<epoch> 로 저장
#   - jq 결과를 임시 파일에 쓰고 mv -f 로 atomic 적용

set -u

VALUE="${1:-true}"
if [ "$VALUE" != "true" ] && [ "$VALUE" != "false" ]; then
    echo "Usage: $0 [true|false]" >&2
    exit 2
fi

PATHS=(
    "/root/shared_v/ord_vcm_conf.json"
    "/home/root/ord_vcm_conf.json"
)

rc=0
for p in "${PATHS[@]}"; do
    [ -f "$p" ] || continue
    if jq -e '.VCM.srt_enable' "$p" >/dev/null 2>&1; then
        echo "SKIP $p (already has srt_enable)"
        continue
    fi
    bak="${p}.bak.$(date +%s)"
    if ! cp -p "$p" "$bak"; then
        echo "ERR $p (backup failed)" >&2
        rc=1
        continue
    fi
    tmp=$(mktemp "${p}.tmp.XXXXXX")
    if jq --argjson v "$VALUE" '.VCM.srt_enable = $v' "$p" > "$tmp" 2>/dev/null; then
        if mv -f "$tmp" "$p"; then
            echo "OK $p srt_enable=$VALUE (backup: $bak)"
        else
            echo "ERR $p (mv failed)" >&2
            rm -f "$tmp"
            rc=1
        fi
    else
        echo "ERR $p (jq failed)" >&2
        rm -f "$tmp"
        rc=1
    fi
done

exit $rc
