#!/usr/bin/env bash
# cam_monitor_wait (issue #168 follow-up): the daemon loop's end-of-iteration wait
# returns as soon as a new pending request appears, waits the full limit when there
# is nothing new, and never wakes on a pending this iteration already saw and left.
# A TERM during the wait runs the daemon's trap to the end, within one slice: a trap
# that spends longer than a slice in a command substitution must still finish (a
# builtin read -t wait aborted such a trap at its timeout alarm).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-monitor-wait.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_CAMERA_RUN_DIR="$WORK/run" PIM_CAMERA_STATE_DIR="$WORK/state" PIM_CAMERA_BOOT_ID_FILE="$WORK/boot-id"
mkdir -p "$PIM_CAMERA_RUN_DIR"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery_actions.sh"
# shellcheck source=/dev/null
source "${MONITOR_WAIT_LIB:-$PIM_LIB/cam_operate_control.sh}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pending="$WORK/pending.json"
# elapsed milliseconds of one cam_monitor_wait call; its rc goes to wait_rc.
timed_wait() {
    local start end
    start=${EPOCHREALTIME/./}
    wait_rc=0; cam_monitor_wait "$@" || wait_rc=$?
    end=${EPOCHREALTIME/./}
    elapsed_ms=$(( (end - start) / 1000 ))
}

# 1. nothing pending: the full limit, rc 1.
rm -f "$pending"
timed_wait 2 "$pending" 0
[ "$wait_rc" -eq 1 ] || fail "an idle wait returned $wait_rc, not 1"
[ "$elapsed_ms" -ge 1900 ] || fail "an idle wait ended after ${elapsed_ms}ms, not the 2s limit"

# 2. a pending written during the wait ends it within a slice, rc 0.
rm -f "$pending"
( sleep 0.6; : > "$pending" ) &
timed_wait 2 "$pending" 0
wait
[ "$wait_rc" -eq 0 ] || fail "a pending written during the wait returned $wait_rc, not 0"
[ "$elapsed_ms" -ge 500 ] && [ "$elapsed_ms" -le 1200 ] || fail "a pending written at 0.6s ended the wait after ${elapsed_ms}ms"

# 3. a pending that appeared after the poll (not stale): no wait at all.
: > "$pending"
timed_wait 2 "$pending" 0
[ "$wait_rc" -eq 0 ] || fail "a new pending returned $wait_rc, not 0"
[ "$elapsed_ms" -lt 200 ] || fail "a new pending still waited ${elapsed_ms}ms"

# 4. a pending this iteration saw and left (stale): the full limit, so the loop does not spin.
timed_wait 2 "$pending" 1
[ "$wait_rc" -eq 1 ] || fail "a stale pending returned $wait_rc, not 1"
[ "$elapsed_ms" -ge 1900 ] || fail "a stale pending woke the wait after ${elapsed_ms}ms - the loop would spin"

# 5. which pending is stale: seen at the poll and not claimed.
stale_case() {
    local want=$1 got=0; shift
    cam_monitor_pending_stale "$@" || got=1
    [ "$got" -eq "$want" ] || fail "cam_monitor_pending_stale $* returned $got, not $want"
}
stale_case 1 0 0 gstapp_restart
stale_case 1 0 1 ""
stale_case 0 1 0 repair
stale_case 0 1 0 ""
stale_case 0 1 1 ""
stale_case 1 1 0 gstapp_restart
stale_case 1 1 0 apply_config

# 6. the loop's call: a pending seen at the poll and left by a repair waits the full limit;
# one seen and claimed (so the present file is new) or not seen at all does not wait.
iteration_case() {
    local want_rc=$1 slow=$2; shift 2
    local start end
    : > "$pending"
    start=${EPOCHREALTIME/./}
    wait_rc=0; cam_monitor_iteration_wait "$pending" "$@" || wait_rc=$?
    end=${EPOCHREALTIME/./}
    elapsed_ms=$(( (end - start) / 1000 ))
    [ "$wait_rc" -eq "$want_rc" ] || fail "cam_monitor_iteration_wait $* returned $wait_rc, not $want_rc"
    if [ "$slow" = 1 ]; then
        [ "$elapsed_ms" -ge 1900 ] || fail "cam_monitor_iteration_wait $* ended after ${elapsed_ms}ms, not the full limit"
    else
        [ "$elapsed_ms" -lt 200 ] || fail "cam_monitor_iteration_wait $* waited ${elapsed_ms}ms"
    fi
}
iteration_case 1 1 1 0 repair
iteration_case 0 0 1 0 gstapp_restart
iteration_case 0 0 0 1 ""

# 7. a TERM during the wait runs the trap to its end, within about a slice.  The trap
# spends 0.4s in a command substitution, like the daemon's ordered stop does.
rm -f "$pending" "$WORK/trap-done"
bash -c '
    source "$1/cam_recovery.sh"; source "$1/cam_recovery_actions.sh"; source "$2"
    trap "out=\$(sleep 0.4; echo ok); [ \"\$out\" = ok ] && : > \"$4\"; exit 143" TERM
    : > "$4.ready"
    cam_monitor_wait 2 "$3" 0
    exit 0
' monitor-wait "$PIM_LIB" "${MONITOR_WAIT_LIB:-$PIM_LIB/cam_operate_control.sh}" "$pending" "$WORK/trap-done" &
child=$!
for _ in $(seq 1 50); do [ -e "$WORK/trap-done.ready" ] && break; sleep 0.05; done
[ -e "$WORK/trap-done.ready" ] || fail 'the waiting process did not start'
sleep 0.3
start=${EPOCHREALTIME/./}
kill -TERM "$child"
rc=0; wait "$child" || rc=$?
end=${EPOCHREALTIME/./}
term_ms=$(( (end - start) / 1000 ))
[ -e "$WORK/trap-done" ] || fail "the TERM trap did not run to its end (rc $rc) - the wait cut it short"
[ "$rc" -eq 143 ] || fail "the trap did not end the waiting process (rc $rc)"
[ "$term_ms" -lt 1500 ] || fail "the TERM trap finished ${term_ms}ms after the signal"

echo "monitor wait: PASS"
