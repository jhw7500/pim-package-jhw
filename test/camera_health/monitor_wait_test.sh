#!/usr/bin/env bash
# cam_monitor_wait (issue #168 follow-up): the daemon loop's end-of-iteration wait is one
# background sleep and a wait; a WINCH (sent by the submit after it writes pending) ends
# it at once, it waits the full limit otherwise, and it never wakes on a pending this
# iteration already saw and left.  A TERM during the wait runs the daemon's trap to the
# end.  _cr_wake_daemon sends that WINCH only to a live owner whose answer is already in
# the memo, never to itself, never through a fake proc root, and never runs jq.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-monitor-wait.XXXXXX")
# 5c 가 trap 을 잠깐 감싸는 함수로 바꿨다가 지운다 — 여기서 부르는 것은 내장 trap 이다.
# shellcheck disable=SC2218
trap 'rm -rf "$WORK"' EXIT
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_CAMERA_RUN_DIR="$WORK/run" PIM_CAMERA_STATE_DIR="$WORK/state" PIM_CAMERA_BOOT_ID_FILE="$WORK/boot-id"
mkdir -p "$PIM_CAMERA_RUN_DIR" "$WORK/bin"
printf 'boot-1\n' > "$PIM_CAMERA_BOOT_ID_FILE"
REAL_JQ=$(command -v jq)
cat > "$WORK/bin/jq" <<SH
#!/bin/sh
printf 'jq\n' >> "$WORK/jq.log"
exec "$REAL_JQ" "\$@"
SH
chmod +x "$WORK/bin/jq"
export PATH="$WORK/bin:$PATH"
# shellcheck source=/dev/null
source "${MONITOR_WAIT_RECOVERY_LIB:-$PIM_LIB/cam_recovery.sh}"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery_actions.sh"
# shellcheck source=/dev/null
source "${MONITOR_WAIT_LIB:-$PIM_LIB/cam_operate_control.sh}"

fail() { echo "FAIL: $*" >&2; exit 1; }
runs() { if [ -e "$WORK/jq.log" ]; then wc -l < "$WORK/jq.log"; else echo 0; fi; }
pending="$WORK/pending.json"
now_ms() { local t=${EPOCHREALTIME/./}; echo $(( t / 1000 )); }
# one cam_monitor_wait call: rc to wait_rc, duration to elapsed_ms.
timed_wait() {
    local start
    start=$(now_ms)
    wait_rc=0; cam_monitor_wait "$@" || wait_rc=$?
    elapsed_ms=$(( $(now_ms) - start ))
}
clean_after() {
    [ -z "$(trap -p WINCH)" ] || fail "$1: the WINCH trap was left installed"
    [ -z "$(jobs -rp)" ] || fail "$1: a background job was left running ($(jobs -rp | tr '\n' ' '))"
}

# 1. nothing pending, no signal: the full limit, rc 1, nothing left behind.
rm -f "$pending"
timed_wait 2 "$pending" 0
[ "$wait_rc" -eq 1 ] || fail "an idle wait returned $wait_rc, not 1"
[ "$elapsed_ms" -ge 1900 ] || fail "an idle wait ended after ${elapsed_ms}ms, not the 2s limit"
clean_after 'idle wait'

# 2. the submit's order - pending, then WINCH - ends the wait at once, rc 0.
rm -f "$pending"
( sleep 0.6; : > "$pending"; kill -WINCH $$ ) &
timed_wait 2 "$pending" 0
wait
[ "$wait_rc" -eq 0 ] || fail "a pending plus WINCH returned $wait_rc, not 0"
[ "$elapsed_ms" -ge 500 ] && [ "$elapsed_ms" -le 1500 ] || fail "a WINCH at 0.6s ended the wait after ${elapsed_ms}ms"
clean_after 'woken wait'

# 3. a pending without a WINCH is not polled for: the full limit, rc 1 (the loop counts the 2s).
rm -f "$pending"
( sleep 0.6; : > "$pending" ) &
timed_wait 2 "$pending" 0
wait
[ "$wait_rc" -eq 1 ] || fail "a pending written without a signal returned $wait_rc, not 1"
[ "$elapsed_ms" -ge 1900 ] || fail "a pending without a signal ended the wait after ${elapsed_ms}ms - the wait polls"

# 4. a WINCH with no pending (someone else's) ends the sleep but reports no work, rc 1.
rm -f "$pending"
( sleep 0.5; kill -WINCH $$ ) &
timed_wait 2 "$pending" 0
wait
[ "$wait_rc" -eq 1 ] || fail "a stray WINCH returned $wait_rc, not 1"
clean_after 'stray WINCH'

# 5. a pending and WINCH sent right as the wait starts - before or after the trap - is not lost.
for _ in 1 2 3 4 5; do
    rm -f "$pending"
    ( : > "$pending"; kill -WINCH $$ ) &
    timed_wait 2 "$pending" 0
    wait
    [ "$wait_rc" -eq 0 ] || fail "a pending and WINCH sent at the start returned $wait_rc, not 0"
    [ "$elapsed_ms" -lt 500 ] || fail "a pending and WINCH sent at the start were lost (${elapsed_ms}ms)"
done
clean_after 'racing WINCH'
# 5b. a pending and WINCH sent just after the wait began (the trap must already be in place).
for _ in 1 2 3; do
    rm -f "$pending"
    ( sleep 0.02; : > "$pending"; kill -WINCH $$ ) &
    timed_wait 2 "$pending" 0
    wait
    [ "$wait_rc" -eq 0 ] || fail "a pending and WINCH sent 20ms in returned $wait_rc, not 0"
    [ "$elapsed_ms" -lt 500 ] || fail "a pending and WINCH sent 20ms in were lost (${elapsed_ms}ms) - the trap came late"
done
clean_after 'early WINCH'

# 5c. a pending that lands between the trap and the wait, with its WINCH already spent before
# the trap (the submit signalled while the wait was still being set up): the recheck after
# the trap must catch it.  A wrapper writes the pending the moment the WINCH trap is set.
rm -f "$pending"
# shellcheck disable=SC2064 # 받은 인자를 그대로 넘기는 감싸개다.
trap() { builtin trap "$@"; if [ "$1" != - ] && [ "${2:-}" = WINCH ]; then : > "$pending"; fi; }
timed_wait 2 "$pending" 0
unset -f trap
[ "$wait_rc" -eq 0 ] || fail "a pending written as the trap was set returned $wait_rc, not 0"
[ "$elapsed_ms" -lt 500 ] || fail "a pending written as the trap was set waited ${elapsed_ms}ms - no recheck after the trap"
clean_after 'pending at trap time'

# 6. a pending that appeared after the poll (not stale): no wait at all.
: > "$pending"
timed_wait 2 "$pending" 0
[ "$wait_rc" -eq 0 ] || fail "a new pending returned $wait_rc, not 0"
[ "$elapsed_ms" -lt 200 ] || fail "a new pending still waited ${elapsed_ms}ms"

# 7. a pending this iteration saw and left (stale): the full limit even with a WINCH.
( sleep 0.5; kill -WINCH $$ ) &
timed_wait 2 "$pending" 1
wait
[ "$wait_rc" -eq 1 ] || fail "a stale pending returned $wait_rc, not 1"
[ "$elapsed_ms" -ge 1900 ] || fail "a stale pending woke the wait after ${elapsed_ms}ms - the loop would spin"

# 8. which pending is stale: seen at the poll and not claimed.
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

# 9. the loop's call: a pending seen at the poll and left by a repair waits the full limit;
# one seen and claimed (so the present file is new) or not seen at all does not wait.
iteration_case() {
    local want_rc=$1 slow=$2 start; shift 2
    : > "$pending"
    start=$(now_ms)
    wait_rc=0; cam_monitor_iteration_wait "$pending" "$@" || wait_rc=$?
    elapsed_ms=$(( $(now_ms) - start ))
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

# 10. a TERM during the wait runs the trap to its end.  The trap spends 0.4s in a
# command substitution, like the daemon's ordered stop does; a builtin read -t wait
# aborted such a trap at its timeout alarm.
rm -f "$pending" "$WORK/trap-done" "$WORK/trap-done.ready"
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
start=$(now_ms)
kill -TERM "$child"
rc=0; wait "$child" || rc=$?
term_ms=$(( $(now_ms) - start ))
[ -e "$WORK/trap-done" ] || fail "the TERM trap did not run to its end (rc $rc) - the wait cut it short"
[ "$rc" -eq 143 ] || fail "the trap did not end the waiting process (rc $rc)"
[ "$term_ms" -lt 1500 ] || fail "the TERM trap finished ${term_ms}ms after the signal"

# 11. _cr_wake_daemon: a WINCH reaches a live owner whose live answer is in the memo, with
# no jq; nothing is sent without that answer, to a stale start time, to itself, or through
# a fake proc root.
target_marker="$WORK/woke"
bash -c 'trap ": > \"$1\"" WINCH; : > "$1.ready"; while :; do sleep 0.05; done' wake-target "$target_marker" &
target=$!
for _ in $(seq 1 50); do [ -e "$target_marker.ready" ] && break; sleep 0.05; done
[ -e "$target_marker.ready" ] || fail 'the wake target did not start'
owner_for() {
    printf '{"boot_id":"boot-1","invocation_id":"inv-1","pid":%s,"proc_start_time":"%s","token":"tok-1","created_at":1700000000,"lifecycle":"ACTIVE"}' "$1" "$2"
}
wake_case() {
    local what=$1 want=$2 pid=$3 start=$4 prime=$5 root=$6 owner
    rm -f "$target_marker"
    owner=$(owner_for "$pid" "$start")
    printf '%s\n' "$owner" > "$(_cr_owner_file)"
    _CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
    if [ "$prime" = 1 ]; then PIM_CAMERA_PROC_ROOT=/proc _cr_owner_snapshot_live "$owner" >/dev/null 2>&1 || :; fi
    : > "$WORK/jq.log"
    PIM_CAMERA_PROC_ROOT=$root _cr_wake_daemon || fail "$what: _cr_wake_daemon returned non-zero"
    [ "$(runs)" -eq 0 ] || fail "$what: _cr_wake_daemon ran jq $(runs) times"
    sleep 0.4
    if [ "$want" = sent ]; then
        [ -e "$target_marker" ] || fail "$what: the live owner did not get the WINCH"
    else
        [ ! -e "$target_marker" ] || fail "$what: a WINCH was sent"
    fi
}
target_start=$(PIM_CAMERA_PROC_ROOT=/proc _cr_proc_start "$target")
[ -n "$target_start" ] || fail 'could not read the wake target start time'
wake_case 'live owner, answer in the memo' sent "$target" "$target_start" 1 /proc
wake_case 'answer not in the memo' none "$target" "$target_start" 0 /proc
wake_case 'start time of another process' none "$target" "1$target_start" 1 /proc
# 가짜 proc root 에 진짜와 같은 stat 을 둬 시작 시각 대조가 통과하게 한다 — 그래도 보내지 않아야 한다.
mkdir -p "$WORK/proc/$target"; cp "/proc/$target/stat" "$WORK/proc/$target/stat"
wake_case 'a fake proc root' none "$target" "$target_start" 1 "$WORK/proc"
self_start=$(PIM_CAMERA_PROC_ROOT=/proc _cr_proc_start "$$")
trap ': > "$target_marker"' WINCH
wake_case 'the owner is this process' none "$$" "$self_start" 1 /proc
trap - WINCH

# 12. end to end: cam_request_submit writes pending and the live owner gets the WINCH, with the
# submit's two jq (owner guard fold, the request) and no more.
rm -f "$target_marker" "$pending"
printf '%s\n' "$(owner_for "$target" "$target_start")" > "$(_cr_owner_file)"
_CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
: > "$WORK/jq.log"
(
    export PIM_CAMERA_PROC_ROOT=/proc
    PIM_CAMERA_OWNER_INVOCATION='' cam_request_submit gstapp_restart operator 'wake check' >/dev/null
) || fail 'the end-to-end submit was refused'
[ -f "$(_cr_pending_file)" ] || fail 'the end-to-end submit wrote no pending'
[ "$(runs)" -le 2 ] || fail "the end-to-end submit ran jq $(runs) times, more than 2"
sleep 0.4
[ -e "$target_marker" ] || fail 'the end-to-end submit did not wake the owner'

kill "$target" 2>/dev/null || :
wait "$target" 2>/dev/null || :

echo "monitor wait: PASS"
