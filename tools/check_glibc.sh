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

# 천장 값을 먼저 검증한다. sort -V 는 "foo" 같은 비버전 문자열을 숫자 버전보다 크게
# 놓으므로, 오타 하나로 모든 비교가 통과해 게이트가 조용히 열린다(fail-open).
# 안전장치는 잘못된 입력에 닫히는 쪽으로 실패해야 한다.
if ! printf '%s' "$MAX" | grep -qE '^[0-9]+(\.[0-9]+)*$'; then
    echo "ERROR: PIM_MAX_GLIBC must be a dotted numeric version like 2.31 (got: '${MAX}')" >&2
    exit 2
fi

if ! command -v readelf >/dev/null 2>&1; then
    # 검사할 수 없다는 것은 통과가 아니다. strict 에서 그냥 넘기면, 게이트가 막으려던
    # 비호환 바이너리가 "검사 도구가 없었다"는 이유로 패키징된다.
    if [ "$GATE" = "strict" ]; then
        echo "ERROR: readelf not found — cannot verify GLIBC requirements." >&2
        echo "       Install binutils, or set PIM_GLIBC_GATE=warn|off to skip deliberately." >&2
        exit 2
    fi
    echo "WARNING: readelf not found; skipping GLIBC check (PIM_GLIBC_GATE=${GATE})" >&2
    exit 0
fi

# $1 이 $2 보다 새 버전이면 0 을 돌려준다.
newer_than() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" != "$2" ]
}

# ELF 매직으로 검사 대상을 가른다. pim_gate 산출물 트리에는 실행 권한이 붙은 셸/파이썬
# 스크립트가 섞여 있고, 그것들은 GLIBC 요구가 없으므로 검사 대상이 아니다.
elf_magic() {
    [ "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]
}

failed=0
checked=0
skipped=0
unreadable=0
for path in "$@"; do
    [ -f "$path" ] || continue

    if ! elf_magic "$path"; then
        skipped=$((skipped + 1))
        continue
    fi

    # readelf 는 잘린 ELF 에서도 rc=0 을 돌려주면서 stderr 에만 "readelf: Error" 를
    # 찍는다(실측). 종료 코드만 보면 "요구 버전이 없다" 로 오독해 그대로 통과시킨다.
    # 검사하지 못한 것은 통과가 아니므로 두 신호를 모두 본다.
    ver_out=$(readelf -V "$path" 2>&1)
    ver_rc=$?
    if [ "$ver_rc" -ne 0 ] || printf '%s' "$ver_out" | grep -q 'readelf: Error'; then
        echo "  ${path}: readelf failed — cannot verify GLIBC requirements" >&2
        printf '%s\n' "$ver_out" | grep 'readelf: Error' | head -2 | sed 's/^/    /' >&2
        unreadable=$((unreadable + 1))
        continue
    fi

    checked=$((checked + 1))
    for v in $(printf '%s\n' "$ver_out" | grep -oE 'GLIBC_[0-9.]+' | sed 's/^GLIBC_//' | sort -uV); do
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

problem=0

if [ "$failed" -ne 0 ]; then
    echo "ERROR: binaries require a newer GLIBC than the target rootfs (${MAX})." >&2
    echo "       This is what building with the Yocto SDK on an x86_64 host produces." >&2
    echo "       Use ./docker/build.sh <module> instead." >&2
    problem=1
fi

if [ "$unreadable" -ne 0 ]; then
    echo "ERROR: ${unreadable} ELF file(s) could not be inspected." >&2
    echo "       손상됐거나 LFS 포인터일 수 있다. 검사하지 못한 것은 통과가 아니다." >&2
    problem=1
fi

if [ "$problem" -ne 0 ]; then
    if [ "$GATE" = "strict" ]; then
        exit 2
    fi
    echo "WARNING: continuing anyway (PIM_GLIBC_GATE=${GATE})" >&2
    exit 0
fi

if [ "$checked" -eq 0 ]; then
    # 통과가 아니라 "볼 것이 없었다". OK 로 적으면 경로 지정 실수가 성공으로 읽힌다.
    if [ "$skipped" -ne 0 ]; then
        echo "GLIBC check: no ELF binaries to check (${skipped} non-ELF file(s) skipped)"
    else
        echo "GLIBC check: no binaries to check (none of the given paths exist)"
    fi
    exit 0
fi

summary="GLIBC check OK: ${checked} binary(ies) within GLIBC_${MAX}"
[ "$skipped" -ne 0 ] && summary="${summary} (${skipped} non-ELF skipped)"
echo "$summary"
exit 0
