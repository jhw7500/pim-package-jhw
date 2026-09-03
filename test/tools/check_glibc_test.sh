#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/check-glibc.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# readelf 를 스텁으로 갈아끼워 GLIBC 버전을 원하는 대로 흉내낸다.
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/readelf" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        -V) echo "  0x0020: Name: GLIBC_${FIXTURE_GLIBC:-2.17}  Flags: none" ;;
        --dyn-syms) echo "  1: 0000 0 FUNC GLOBAL DEFAULT UND stat@GLIBC_${FIXTURE_GLIBC:-2.17} (2)" ;;
    esac
done
exit 0
STUB
chmod +x "$TMP_ROOT/bin/readelf"
touch "$TMP_ROOT/fake-binary"

run() {  # $1=FIXTURE_GLIBC  나머지=env 선언
    local glibc=$1; shift
    set +e
    env PATH="$TMP_ROOT/bin:$PATH" FIXTURE_GLIBC="$glibc" "$@" \
        bash "$ROOT/tools/check_glibc.sh" "$TMP_ROOT/fake-binary" >"$TMP_ROOT/out" 2>&1
    RUN_RC=$?
    set -e
}

# 1) 타깃 이하 버전은 통과한다
run 2.17 PIM_GLIBC_GATE=strict
[ "$RUN_RC" -eq 0 ] || fail "GLIBC_2.17 은 통과해야 한다 (rc=$RUN_RC)"
grep -q "GLIBC check OK" "$TMP_ROOT/out" || fail "성공 메시지가 없다: $(cat "$TMP_ROOT/out")"

# 2) 경계값(=타깃)도 통과한다
run 2.31 PIM_GLIBC_GATE=strict
[ "$RUN_RC" -eq 0 ] || fail "GLIBC_2.31 은 경계값이라 통과해야 한다 (rc=$RUN_RC)"

# 3) 타깃 초과는 기본(strict)에서 실패한다 — 이 게이트의 존재 이유
run 2.33
[ "$RUN_RC" -eq 2 ] || fail "GLIBC_2.33 은 기본값에서 rc=2 여야 한다 (rc=$RUN_RC)"
grep -q "requires GLIBC_2.33" "$TMP_ROOT/out" || fail "위반 내역이 보고되지 않았다"
grep -q "stat@GLIBC_2.33" "$TMP_ROOT/out" || fail "원인 심볼이 보고되지 않았다"

# 4) warn 모드는 보고하되 통과시킨다
run 2.33 PIM_GLIBC_GATE=warn
[ "$RUN_RC" -eq 0 ] || fail "warn 모드는 통과해야 한다 (rc=$RUN_RC)"
grep -q "requires GLIBC_2.33" "$TMP_ROOT/out" || fail "warn 모드도 위반은 보고해야 한다"

# 5) off 는 검사를 건너뛴다 (두 환경변수 모두)
run 2.33 PIM_GLIBC_GATE=off
[ "$RUN_RC" -eq 0 ] || fail "gate=off 는 통과해야 한다 (rc=$RUN_RC)"
run 2.33 PIM_VERIFY_BINARIES=off
[ "$RUN_RC" -eq 0 ] || fail "PIM_VERIFY_BINARIES=off 도 off 로 취급해야 한다 (rc=$RUN_RC)"

# 6) 천장을 올리면 통과한다
run 2.33 PIM_MAX_GLIBC=2.35
[ "$RUN_RC" -eq 0 ] || fail "PIM_MAX_GLIBC=2.35 면 통과해야 한다 (rc=$RUN_RC)"

# 7) 잘못된 게이트 값은 거부한다
run 2.17 PIM_GLIBC_GATE=bogus
[ "$RUN_RC" -eq 2 ] || fail "잘못된 게이트 값은 rc=2 여야 한다 (rc=$RUN_RC)"

# 8) 존재하지 않는 파일은 조용히 건너뛴다
set +e
env PATH="$TMP_ROOT/bin:$PATH" bash "$ROOT/tools/check_glibc.sh" "$TMP_ROOT/nope" >"$TMP_ROOT/out" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "없는 파일은 통과해야 한다 (rc=$rc)"
grep -q "no binaries to check" "$TMP_ROOT/out" || fail "0건은 'OK' 가 아니라 '볼 것이 없었다' 로 보고해야 한다: $(cat "$TMP_ROOT/out")"
grep -q "GLIBC check OK" "$TMP_ROOT/out" && fail "0건인데 OK 로 보고했다 — 공허한 통과"

# 9) 인자가 아예 없어도 OK 로 보고하지 않는다
set +e
env PATH="$TMP_ROOT/bin:$PATH" bash "$ROOT/tools/check_glibc.sh" >"$TMP_ROOT/out" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "인자 없음은 통과해야 한다 (rc=$rc)"
grep -q "no binaries to check" "$TMP_ROOT/out" || fail "인자 없음도 0건으로 보고해야 한다"

# 10) 잘못된 천장 값은 통과시키지 않고 닫힌다 (fail-open 방지)
for bad in foo 2.. .2 "2.3x" "2 31"; do
    run 2.33 PIM_MAX_GLIBC="$bad"
    [ "$RUN_RC" -eq 2 ] || fail "PIM_MAX_GLIBC='$bad' 는 rc=2 여야 한다 (rc=$RUN_RC) — 오타로 게이트가 열리면 안 된다"
    grep -q "must be a dotted numeric version" "$TMP_ROOT/out" || fail "'$bad' 거부 사유가 보고되지 않았다"
done

# 11) 빈 값은 오류가 아니라 기본 천장(2.31)으로 폴백한다 — 안전한 쪽으로 닫힌다
run 2.33 PIM_MAX_GLIBC=
[ "$RUN_RC" -eq 2 ] || fail "빈 천장은 기본 2.31 로 폴백해 2.33 을 막아야 한다 (rc=$RUN_RC)"
grep -q "target provides 2.31" "$TMP_ROOT/out" || fail "빈 천장이 기본값 2.31 로 폴백하지 않았다: $(cat "$TMP_ROOT/out")"

# 12) 정상 형식은 그대로 동작한다
run 2.33 PIM_MAX_GLIBC=2.40
[ "$RUN_RC" -eq 0 ] || fail "PIM_MAX_GLIBC=2.40 은 통과해야 한다 (rc=$RUN_RC)"

# 13) readelf 가 없으면 strict 는 닫히고 warn/off 는 넘어간다
mkdir -p "$TMP_ROOT/nore"
for c in bash grep sed sort head tr cut cat env dirname printf; do
    src=$(command -v "$c" 2>/dev/null) && ln -sf "$src" "$TMP_ROOT/nore/$c"
done
run_nore() {  # $1=gate
    set +e
    env -i PATH="$TMP_ROOT/nore" HOME="$TMP_ROOT" PIM_GLIBC_GATE="$1" \
        bash "$ROOT/tools/check_glibc.sh" "$TMP_ROOT/fake-binary" >"$TMP_ROOT/out" 2>&1
    RUN_RC=$?
    set -e
}
run_nore strict
[ "$RUN_RC" -eq 2 ] || fail "readelf 없음 + strict 는 rc=2 여야 한다 (rc=$RUN_RC): $(cat "$TMP_ROOT/out")"
grep -q "readelf not found" "$TMP_ROOT/out" || fail "readelf 부재 사유가 보고되지 않았다"
run_nore warn
[ "$RUN_RC" -eq 0 ] || fail "readelf 없음 + warn 은 rc=0 이어야 한다 (rc=$RUN_RC)"
run_nore off
[ "$RUN_RC" -eq 0 ] || fail "readelf 없음 + off 는 rc=0 이어야 한다 (rc=$RUN_RC)"

echo "PASS: check_glibc.sh 13 케이스"
