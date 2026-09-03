#!/usr/bin/env bash
#
# 타깃 rootfs 가 제공하는 것보다 새로운 GLIBC 심볼 버전을 요구하는 바이너리를 막는다.
#
# 타깃은 Ubuntu 20.04 (glibc 2.31) 인데 Yocto SDK 는 glibc 2.33 으로 빌드한다. SDK 로 만든
# 바이너리는 stat@GLIBC_2.33 을 참조해 타깃의 로더 단계에서 죽는다
# ("version `GLIBC_2.33' not found"). 빌드 로그 경고는 놓치기 쉬워 기본값은 실패다.
#
# Usage: check_glibc.sh <binary> [binary...]
# Env:
#   PIM_MAX_GLIBC   타깃이 제공하는 최대 GLIBC 버전 (기본 2.31)
#   PIM_GLIBC_GATE  strict(기본) | warn | off
#   PIM_VERIFY_BINARIES=off 도 off 로 취급한다

set -u

MAX=${PIM_MAX_GLIBC:-2.31}
GATE=${PIM_GLIBC_GATE:-strict}
[ "${PIM_VERIFY_BINARIES:-}" = "off" ] && GATE=off

case "$GATE" in
    off)
        echo "GLIBC check disabled (gate=off)"
        exit 0
        ;;
    warn|strict) ;;
    *)
        echo "ERROR: PIM_GLIBC_GATE must be off, warn, or strict (got: $GATE)" >&2
        exit 2
        ;;
esac

if ! command -v readelf >/dev/null 2>&1; then
    echo "WARNING: readelf not found; skipping GLIBC check" >&2
    exit 0
fi

# $1 이 $2 보다 새 버전이면 0 을 돌려준다.
newer_than() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" != "$2" ]
}

failed=0
checked=0
for path in "$@"; do
    [ -f "$path" ] || continue
    checked=$((checked + 1))
    for v in $(readelf -V "$path" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sed 's/^GLIBC_//' | sort -uV); do
        newer_than "$v" "$MAX" || continue
        syms=$(readelf -sW --dyn-syms "$path" 2>/dev/null \
            | grep -oE "[A-Za-z_][A-Za-z0-9_]*@+GLIBC_${v}" | sed 's/@@/@/' | sort -u)
        n=$(printf '%s' "$syms" | grep -c .)
        shown=$(printf '%s' "$syms" | head -8 | tr '\n' ' ')
        [ "$n" -gt 8 ] && shown="${shown}... (${n} symbols total)"
        echo "  ${path} requires GLIBC_${v} (target provides ${MAX}): ${shown}" >&2
        failed=1
    done
done

if [ "$failed" -ne 0 ]; then
    echo "ERROR: binaries require a newer GLIBC than the target rootfs (${MAX})." >&2
    echo "       This is what building with the Yocto SDK on an x86_64 host produces." >&2
    echo "       Use ./docker/build.sh <module> instead." >&2
    if [ "$GATE" = "strict" ]; then
        exit 2
    fi
    echo "WARNING: continuing anyway (PIM_GLIBC_GATE=warn)" >&2
    exit 0
fi

if [ "$checked" -eq 0 ]; then
    # 통과가 아니라 "볼 것이 없었다". OK 로 적으면 경로 지정 실수가 성공으로 읽힌다.
    echo "GLIBC check: no binaries to check (none of the given paths exist)"
    exit 0
fi

echo "GLIBC check OK: ${checked} binary(ies) within GLIBC_${MAX}"
exit 0
