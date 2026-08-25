#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/binary-verification-mode.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/python3" <<'STUB'
#!/usr/bin/env bash
echo "fixture verifier output"
exit "${VERIFY_FIXTURE_RC:-0}"
STUB
chmod +x "$TMP_ROOT/bin/python3"

run_mode() {
    local mode=$1 rc=$2 out=$3
    set +e
    PATH="$TMP_ROOT/bin:$PATH" VERIFY_FIXTURE_RC="$rc" \
        PIM_VERIFY_BINARIES="$mode" \
        bash "$ROOT/tools/run_binary_verification.sh" >"$out" 2>&1
    RUN_RC=$?
    set -e
}

run_mode off 73 "$TMP_ROOT/off.log"
[ "$RUN_RC" -eq 0 ] || fail "off 모드가 verifier 실패를 실행 결과로 전달함"
grep -q "disabled" "$TMP_ROOT/off.log" || fail "off 모드 생략 사실이 출력되지 않음"

run_mode warn 73 "$TMP_ROOT/warn.log"
[ "$RUN_RC" -eq 0 ] || fail "warn 모드가 빌드를 차단함"
grep -q "WARNING" "$TMP_ROOT/warn.log" || fail "warn 모드가 실패 경고를 남기지 않음"
grep -q "rc=73" "$TMP_ROOT/warn.log" || fail "warn 모드가 실제 verifier 종료 코드를 보존하지 않음"

run_mode strict 73 "$TMP_ROOT/strict.log"
[ "$RUN_RC" -eq 73 ] || fail "strict 모드가 verifier 종료 코드 73을 보존하지 않음"

run_mode invalid 0 "$TMP_ROOT/invalid.log"
[ "$RUN_RC" -eq 2 ] || fail "알 수 없는 모드가 설정 오류로 거부되지 않음"

unset PIM_VERIFY_BINARIES
set +e
PATH="$TMP_ROOT/bin:$PATH" VERIFY_FIXTURE_RC=73 \
    bash "$ROOT/tools/run_binary_verification.sh" >"$TMP_ROOT/default.log" 2>&1
default_rc=$?
set -e
[ "$default_rc" -eq 0 ] || fail "기본 모드가 warn이 아님"

echo "PASS: binary verification off/warn/strict modes"
