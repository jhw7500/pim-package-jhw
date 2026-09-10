#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-ord-single-owner.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_RUNTIME_JSON="$WORK/pim_runtime.json"
export PIM_CAMERA_CALL_LOG="$WORK/calls"
export PIM_CAMERA_ORD_STATE_FILE="$WORK/ord-state"
export PIM_CAMERA_PROCESS_FILE="$WORK/processes"
export PIM_CAMERA_SYSTEMCTL=systemctl
export PATH="$WORK/stub:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() {
    local wanted=$1 got
    shift
    set +e
    "$@"
    got=$?
    set -e
    [ "$got" -eq "$wanted" ] || fail "wanted rc=$wanted got rc=$got: $*"
}

mkdir -p "$WORK/stub"
printf '%s\n' '{"VHL_CAM":{"app":"gstApp","capture":{"enable":false}},"ORD":{},"VCM":{}}' > "$PIM_CAMERA_RUNTIME_JSON"
: > "$PIM_CAMERA_CALL_LOG"
: > "$PIM_CAMERA_PROCESS_FILE"
printf 'inactive\n' > "$PIM_CAMERA_ORD_STATE_FILE"

cat > "$WORK/stub/systemctl" <<'SH'
#!/bin/sh
printf 'systemctl:%s\n' "$*" >> "$PIM_CAMERA_CALL_LOG"
case "$1" in
    is-active)
        state=$(cat "$PIM_CAMERA_ORD_STATE_FILE") || exit 2
        printf '%s\n' "$state"
        case "$state" in active) exit 0;; inactive) exit 3;; failed) exit 4;; *) exit 2;; esac
        ;;
    restart)
        [ "$2" = ord-operate.service ] || exit 64
        [ "${ORD_RESTART_RC:-0}" -eq 0 ] || exit "$ORD_RESTART_RC"
        printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
        ;;
    stop)
        [ "$2" = ord-operate.service ] || exit 64
        [ "${ORD_STOP_RC:-0}" -eq 0 ] || exit "$ORD_STOP_RC"
        printf 'inactive\n' > "$PIM_CAMERA_ORD_STATE_FILE"
        ;;
    *) exit 64;;
esac
SH
cat > "$WORK/stub/ord" <<'SH'
#!/bin/sh
printf 'direct:ord\n' >> "$PIM_CAMERA_CALL_LOG"
SH
cat > "$WORK/stub/vcm" <<'SH'
#!/bin/sh
printf 'direct:vcm\n' >> "$PIM_CAMERA_CALL_LOG"
SH
cat > "$WORK/stub/pgrep" <<'SH'
#!/bin/sh
target=
for arg; do target=$arg; done
printf 'pgrep:%s\n' "$target" >> "$PIM_CAMERA_CALL_LOG"
grep -Fqx "$target" "$PIM_CAMERA_PROCESS_FILE"
SH
chmod +x "$WORK/stub"/*

cam_owner_assert() { :; }
_cr_test_owner_rollover() {
    [ "${PIM_CAMERA_TEST_OWNER_ROLLOVER:-}" != "$1" ] || return 69
}
# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery_actions.sh"
cam_executor_assert_context() { :; }
cam_validate_runtime() { :; }

echo '=== generic launcher cannot execute ORD ==='
: > "$PIM_CAMERA_CALL_LOG"
set +e
cam_launch_consumer "$PIM_CAMERA_RUNTIME_JSON" ord
launch_rc=$?
wait
set -e
[ "$launch_rc" -eq 64 ] || fail "generic ORD launch returned $launch_rc instead of 64"
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || {
    cat "$PIM_CAMERA_CALL_LOG" >&2
    fail 'generic launcher executed ORD'
}

echo '=== recovery restart has one systemd owner ==='
: > "$PIM_CAMERA_CALL_LOG"
cam_restart_ord "$PIM_CAMERA_RUNTIME_JSON"
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = 'systemctl:restart ord-operate.service' ] || {
    cat "$PIM_CAMERA_CALL_LOG" >&2
    fail 'ORD restart bypassed ord-operate.service'
}

: > "$PIM_CAMERA_CALL_LOG"
ORD_RESTART_RC=23 expect_rc 23 cam_restart_ord "$PIM_CAMERA_RUNTIME_JSON"
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = 'systemctl:restart ord-operate.service' ] || fail 'ORD restart failure used another path'

: > "$PIM_CAMERA_CALL_LOG"
PIM_CAMERA_TEST_OWNER_ROLLOVER=launch_ord expect_rc 69 cam_restart_ord "$PIM_CAMERA_RUNTIME_JSON"
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || fail 'owner rollover reached systemd restart'

echo '=== readiness follows the systemd owner ==='
eval "$(declare -f cam_process_present | sed '1s/cam_process_present/cam_process_present_real/')"
cam_process_present() {
    printf 'probe:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"
    return 0
}
printf 'inactive\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
expect_rc 1 cam_verify_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1
grep -Fqx 'systemctl:is-active ord-operate.service' "$PIM_CAMERA_CALL_LOG" || fail 'readiness did not inspect ORD unit'
! grep -Fqx 'probe:ord' "$PIM_CAMERA_CALL_LOG" || fail 'readiness accepted an arbitrary ORD process'

printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
cam_verify_process_ready "$PIM_CAMERA_RUNTIME_JSON" 1
[ "$(grep -Fxc 'systemctl:is-active ord-operate.service' "$PIM_CAMERA_CALL_LOG")" -eq 1 ] || fail 'readiness did not inspect ORD unit exactly once'
! grep -Fqx 'probe:ord' "$PIM_CAMERA_CALL_LOG" || fail 'active readiness probed arbitrary ORD ownership'
eval "$(declare -f cam_process_present_real | sed '1s/cam_process_present_real/cam_process_present/')"

echo '=== recovery stop uses systemd and rejects rogue ORD ==='
: > "$PIM_CAMERA_PROCESS_FILE"
printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
cam_stop_ord "$PIM_CAMERA_RUNTIME_JSON"
expected=$'systemctl:stop ord-operate.service\npgrep:ord'
[ "$(cat "$PIM_CAMERA_CALL_LOG")" = "$expected" ] || {
    cat "$PIM_CAMERA_CALL_LOG" >&2
    fail 'ORD stop did not verify systemd-owned shutdown'
}

printf 'ord\n' > "$PIM_CAMERA_PROCESS_FILE"
printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
expect_rc 1 cam_stop_ord "$PIM_CAMERA_RUNTIME_JSON"

: > "$PIM_CAMERA_PROCESS_FILE"
printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
: > "$PIM_CAMERA_CALL_LOG"
ORD_STOP_RC=23 expect_rc 23 cam_stop_ord "$PIM_CAMERA_RUNTIME_JSON"
! grep -Fqx 'pgrep:ord' "$PIM_CAMERA_CALL_LOG" || fail 'failed systemd stop was reinterpreted by a process probe'

echo 'ord single owner: PASS'
