#!/usr/bin/env bash
# cam_monitor_wait (issue #168 follow-up): the daemon loop's end-of-iteration wait is one
# foreground sleep whose pid, with the daemon's, it publishes in the monitor-wait file.  A
# submit that wrote pending ends that sleep (_cr_wake_monitor_wait) so the loop claims at
# once; otherwise the wait runs the full limit, and it never wakes on a pending this
# iteration already saw and left.  An external stop that signals the daemon ends the sleep
# too, so the TERM trap runs at once.  There is no trap and no background job in the wait:
# the board's bash 5.0.17 loses a child whose `wait` a trapped signal cut short and hangs on
# the next wait for it (closed PR #181).  So the whole test keeps a long-lived child, the
# way the daemon keeps vcm (that child also ends a hung run), and so does every process
# below that waits with a TERM trap.  The wake ends only a sleep whose parent is the
# published daemon, never through a fake proc root, and runs no jq.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-monitor-wait.XXXXXX")
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_CAMERA_RUN_DIR="$WORK/run" PIM_CAMERA_STATE_DIR="$WORK/state" PIM_CAMERA_BOOT_ID_FILE="$WORK/boot-id"
export PIM_CAMERA_PROC_ROOT=/proc
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
WAIT_LIB=${MONITOR_WAIT_LIB:-$PIM_LIB/cam_operate_control.sh}
RECOVERY_LIB=${MONITOR_WAIT_RECOVERY_LIB:-$PIM_LIB/cam_recovery.sh}
LIVENESS_LIB=${MONITOR_WAIT_LIVENESS_LIB:-$PIM_LIB/cam_liveness.sh}
export WAIT_LIB RECOVERY_LIB
# shellcheck source=/dev/null
source "$RECOVERY_LIB"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery_actions.sh"
# shellcheck source=/dev/null
source "$WAIT_LIB"
# shellcheck source=/dev/null
source "$LIVENESS_LIB"

# The long-lived child (vcm's role), which also fails a run that hangs.
bash -c 'sleep 240 & s=$!; trap "kill \$s 2>/dev/null; exit 0" TERM; wait "$s" && { echo "FAIL: monitor wait test hung" >&2; kill -KILL "$1"; }' watchdog "$$" &
watchdog=$!
trap 'kill "$watchdog" 2>/dev/null || :; rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
runs() { if [ -e "$WORK/jq.log" ]; then wc -l < "$WORK/jq.log"; else echo 0; fi; }
pending="$WORK/pending.json"
wake_file=$(_cr_monitor_wait_file)
now_ms() { local t=${EPOCHREALTIME/./}; echo $(( t / 1000 )); }
# one cam_monitor_wait call: rc to wait_rc, duration to elapsed_ms.
timed_wait() {
    local start
    start=$(now_ms)
    wait_rc=0; cam_monitor_wait "$@" || wait_rc=$?
    elapsed_ms=$(( $(now_ms) - start ))
}
cleared() { [ ! -s "$wake_file" ] || fail "$1: the wait left '$(cat "$wake_file")' in the monitor-wait file"; }

# 1. nothing pending: the full limit, rc 1.  During the wait the file names the sleep and this
# shell as its parent; afterwards it is empty.
rm -f "$pending"
( sleep 0.5; { read -r p d < "$wake_file" && read -r st < "/proc/$p/stat"; } 2>/dev/null; printf '%s|%s|%s\n' "${p:-}" "${d:-}" "${st:-}" > "$WORK/seen" ) &
reader=$!
timed_wait 2 "$pending" 0 "$wake_file"
wait "$reader"
[ "$wait_rc" -eq 1 ] || fail "an idle wait returned $wait_rc, not 1"
[ "$elapsed_ms" -ge 1900 ] || fail "an idle wait ended after ${elapsed_ms}ms, not the 2s limit"
IFS='|' read -r seen_pid seen_parent seen_stat < "$WORK/seen"
[ "$seen_parent" = "$$" ] || fail "the wait published parent '$seen_parent', not $$"
[[ $seen_stat == "$seen_pid (sleep) "[A-Za-z]" $$ "* ]] || fail "the published pid is not this shell's sleep: '$seen_stat'"
cleared 'idle wait'

# 2. a submit (pending, then the wake) during the wait ends it at once, rc 0, and the ended
# sleep leaves no "Terminated" line on the daemon's stderr (journald).
rm -f "$pending"
( sleep 0.6; : > "$pending"; _cr_wake_monitor_wait ) &
helper=$!
{ timed_wait 2 "$pending" 0 "$wake_file"; } 2> "$WORK/wait.err"
wait "$helper"
[ "$wait_rc" -eq 0 ] || fail "a woken wait returned $wait_rc, not 0"
[ ! -s "$WORK/wait.err" ] || fail "the woken wait wrote to stderr: $(head -c 200 "$WORK/wait.err")"
[ "$elapsed_ms" -ge 500 ] && [ "$elapsed_ms" -le 1200 ] || fail "a wake at 0.6s ended the wait after ${elapsed_ms}ms"
cleared 'woken wait'

# 3. a pending written without the wake is not polled for: the full limit, rc 1.
rm -f "$pending"
( sleep 0.6; : > "$pending" ) &
helper=$!
timed_wait 2 "$pending" 0 "$wake_file"
wait "$helper"
[ "$wait_rc" -eq 1 ] || fail "an unwoken wait returned $wait_rc, not 1"
[ "$elapsed_ms" -ge 1900 ] || fail "an unwoken wait ended after ${elapsed_ms}ms"

# 4. a pending that appeared after the poll (not stale): no wait at all.
: > "$pending"
timed_wait 2 "$pending" 0 "$wake_file"
[ "$wait_rc" -eq 0 ] || fail "a new pending returned $wait_rc, not 0"
[ "$elapsed_ms" -lt 200 ] || fail "a new pending still waited ${elapsed_ms}ms"

# 5. a pending this iteration saw and left (stale): the full limit, so the loop does not spin.
timed_wait 2 "$pending" 1 "$wake_file"
[ "$wait_rc" -eq 1 ] || fail "a stale pending returned $wait_rc, not 1"
[ "$elapsed_ms" -ge 1900 ] || fail "a stale pending woke the wait after ${elapsed_ms}ms - the loop would spin"

# 6. a submit between the first check and the published pid had no sleep to end: the wait sees
# that pending right after publishing.  In a separate shell, printf (which publishes the pid)
# stands in for that submit.
rm -f "$pending"
bash -c '
    source "$WAIT_LIB"
    pending=$1
    printf() { : > "$pending"; builtin printf "$@"; }
    s=${EPOCHREALTIME/./}; rc=0
    cam_monitor_wait 2 "$1" 0 "$2" || rc=$?
    e=${EPOCHREALTIME/./}
    echo "$rc $(( (e - s) / 1000 ))" > "$3"
' early "$pending" "$wake_file" "$WORK/early"
read -r wait_rc elapsed_ms < "$WORK/early"
[ "$wait_rc" -eq 0 ] || fail "a pending written before the publish returned $wait_rc, not 0"
[ "$elapsed_ms" -lt 300 ] || fail "a pending written before the publish still waited ${elapsed_ms}ms"
cleared 'pending before the publish'

# 7. a sleep ended with nothing pending: rc 1, so the loop counts the iteration.
rm -f "$pending"
( sleep 0.5; read -r p _ < "$wake_file"; kill -TERM "$p" ) &
helper=$!
timed_wait 2 "$pending" 0 "$wake_file"
wait "$helper"
[ "$wait_rc" -eq 1 ] || fail "a sleep ended without pending returned $wait_rc, not 1"
[ "$elapsed_ms" -lt 1200 ] || fail "a sleep ended at 0.5s still waited ${elapsed_ms}ms"

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
# one seen and claimed (so the present file is new) or not seen at all does not wait.  With
# nothing pending it publishes its sleep in the file it is given, so a submit ends it - and
# the daemon gives it its monitor-wait file.
iteration_case() {
    local want_rc=$1 slow=$2; shift 2
    local start
    : > "$pending"
    start=$(now_ms)
    wait_rc=0; cam_monitor_iteration_wait "$pending" "$@" "$wake_file" || wait_rc=$?
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
rm -f "$pending"
( sleep 0.6; : > "$pending"; _cr_wake_monitor_wait ) &
helper=$!
start=$(now_ms)
wait_rc=0; cam_monitor_iteration_wait "$pending" 0 1 "" "$wake_file" || wait_rc=$?
elapsed_ms=$(( $(now_ms) - start ))
wait "$helper"
[ "$wait_rc" -eq 0 ] || fail "a submit did not wake the loop's call (rc $wait_rc)"
[ "$elapsed_ms" -le 1200 ] || fail "a submit at 0.6s ended the loop's call after ${elapsed_ms}ms"
DAEMON="$ROOT/dist/pim/opt/pim/bin/chk_cam_operate.sh"
# shellcheck disable=SC2016
grep -qxF 'monitor_wait_path=$(_cr_monitor_wait_file)' "$DAEMON" || fail 'the daemon does not set its monitor-wait path'
# shellcheck disable=SC2016
grep -qF '"${PIM_CAMERA_MONITOR_WORK_TYPE:-}" "$monitor_wait_path"; then' "$DAEMON" \
    || fail 'the daemon does not pass its monitor-wait path to the wait'

# 10. _cr_wake_monitor_wait ends only the published daemon's sleep, with no jq.
guard_case() {
    local what=$1 want=$2 target=$3 content=$4 root=$5 rc=0; shift 5
    printf '%s' "$content" > "$wake_file"
    : > "$WORK/jq.log"
    PIM_CAMERA_PROC_ROOT=$root _cr_wake_monitor_wait "$@" || rc=$?
    [ "$rc" -eq 0 ] || fail "$what: _cr_wake_monitor_wait returned $rc"
    [ "$(runs)" -eq 0 ] || fail "$what: _cr_wake_monitor_wait ran jq $(runs) times"
    if [ "$want" = sent ]; then
        rc=0; wait "$target" || rc=$?
        [ "$rc" -eq 143 ] || fail "$what: the sleep was not ended by a TERM (rc $rc)"
    else
        sleep 0.2
        kill -0 "$target" 2>/dev/null || fail "$what: the process was ended"
        kill "$target" 2>/dev/null || :
        wait "$target" 2>/dev/null || :
    fi
}
# a target sleep, returned once it runs as sleep (until its exec it is a copy of this shell, which
# the guard rightly refuses) - so each case below tests the guard it names.
spawn_sleep() {
    local st
    sleep 5 & s=$!
    for _ in $(seq 1 100); do
        { read -r st < "/proc/$s/stat"; } 2>/dev/null && [[ $st == "$s (sleep) "* ]] && return 0
        sleep 0.02
    done
    fail "the target sleep $s never ran as sleep"
}
spawn_sleep
guard_case 'the published sleep' sent "$s" "$s $$"$'\n' /proc
spawn_sleep
guard_case 'the expected parent' sent "$s" "$s $$"$'\n' /proc "$$"
spawn_sleep
guard_case 'another expected parent' none "$s" "$s $$"$'\n' /proc 1
spawn_sleep
guard_case 'a parent other than the published one' none "$s" "$s 1"$'\n' /proc
bash -c 'sleep 5; :' & s=$!
guard_case 'a process that is not a sleep' none "$s" "$s $$"$'\n' /proc
spawn_sleep
mkdir -p "$WORK/proc/$s"; cp "/proc/$s/stat" "$WORK/proc/$s/stat"
guard_case 'a fake proc root' none "$s" "$s $$"$'\n' "$WORK/proc"
spawn_sleep
guard_case 'an empty file' none "$s" '' /proc
spawn_sleep
guard_case 'a malformed file' none "$s" "x$s $$"$'\n' /proc
rm -f "$wake_file"
: > "$WORK/jq.log"
_cr_wake_monitor_wait || fail 'a missing monitor-wait file made the wake fail'

# A process that waits like the daemon: sources the libraries, keeps a long-lived child (vcm),
# optionally sets a TERM trap that spends 0.4s in a command substitution (like the ordered stop)
# or one that holds the recovery lock for 1s and touches $1.won (like the daemon's own ordered
# stop, longer than the 0.5s yield so the systemd side really waits on the lock), then one wait on the real pending path.  It writes "rc elapsed_ms" to $1 and touches $1.ready
# before waiting.
start_waiter() {
    bash -c '
        source "$RECOVERY_LIB"; source "$PIM_LIB/cam_recovery_actions.sh"; source "$WAIT_LIB"
        sleep 300 & long=$!
        if [ "$2" = trap ]; then
            trap "out=\$(sleep 0.4; echo ok); [ \"\$out\" = ok ] && : > \"$1.trap\"; kill \$long; exit 143" TERM
        elif [ "$2" = locktrap ]; then
            hold() { : > "$1.won"; sleep 1; }
            trap "_cr_lock_call hold \"$1\"; kill \$long; exit 143" TERM
        fi
        : > "$1.ready"
        s=${EPOCHREALTIME/./}; rc=0
        cam_monitor_wait 2 "$(_cr_pending_file)" 0 "$(_cr_monitor_wait_file)" || rc=$?
        e=${EPOCHREALTIME/./}
        echo "$rc $(( (e - s) / 1000 ))" > "$1"
        kill "$long"
    ' waiter "$1" "${2:-}" &
    waiter=$!
    for _ in $(seq 1 100); do [ -e "$1.ready" ] && break; sleep 0.05; done
    [ -e "$1.ready" ] || fail 'the waiting process did not start'
    sleep 0.3
}
owner_for() {
    printf '{"boot_id":"boot-1","invocation_id":"inv-1","pid":%s,"proc_start_time":"%s","token":"tok-1","created_at":1700000000,"lifecycle":"ACTIVE"}' "$1" "$2"
}

# 11. end to end: cam_request_submit writes pending and ends the daemon's sleep, with the
# submit's two jq (owner guard fold, the request) and no more.
rm -f "$(_cr_pending_file)"
start_waiter "$WORK/e2e"
printf '%s\n' "$(owner_for "$waiter" "$(_cr_proc_start "$waiter")")" > "$(_cr_owner_file)"
_CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
: > "$WORK/jq.log"
( PIM_CAMERA_OWNER_INVOCATION='' cam_request_submit gstapp_restart operator 'wake check' >/dev/null ) \
    || fail 'the end-to-end submit was refused'
[ "$(runs)" -eq 2 ] || fail "the end-to-end submit ran jq $(runs) times, not 2"
wait "$waiter" || :
read -r e2e_rc e2e_ms < "$WORK/e2e"
[ "$e2e_rc" -eq 0 ] || fail "the submit's wake left the daemon's wait with $e2e_rc, not 0"
[ "$e2e_ms" -lt 1200 ] || fail "the submit's wake ended the daemon's wait after ${e2e_ms}ms"
rm -f "$(_cr_pending_file)" "$(_cr_owner_file)"

# 12. an external stop (_cl_signal_daemon_locked, both the systemd and the direct path) ends
# the sleep with the TERM, so the daemon's trap runs at once instead of after the sleep.
for handoff in 1 0; do
    rm -f "$WORK/stop" "$WORK/stop.trap"
    start_waiter "$WORK/stop" trap
    waiter_start=$(_cr_proc_start "$waiter")
    printf '{}\n' > "$(_cr_owner_file)"
    start=$(now_ms)
    (
        # the stop guards are stubbed; _cl_signal_daemon_locked calls them.
        # shellcheck disable=SC2317
        _cl_stopping_guard() { return 0; }
        # shellcheck disable=SC2317
        _cl_owner_matches_context() { return 0; }
        # shellcheck disable=SC2317
        _cl_current_boot_owner_process_state() { echo live; }
        PIM_CAMERA_OWNER_PID=$waiter PIM_CAMERA_OWNER_PROC_START_TIME=$waiter_start PIM_CAMERA_KILL=kill \
            _cl_signal_daemon_locked "$handoff"
    ) || fail "the external stop (handoff $handoff) could not signal the daemon"
    rc=0; wait "$waiter" || rc=$?
    term_ms=$(( $(now_ms) - start ))
    [ -e "$WORK/stop.trap" ] || fail "handoff $handoff: the TERM trap did not run to its end (rc $rc)"
    [ "$rc" -eq 143 ] || fail "handoff $handoff: the trap did not end the waiting process (rc $rc)"
    [ "$term_ms" -lt 1200 ] || fail "handoff $handoff: the trap finished ${term_ms}ms after the stop - the sleep was not ended"
done
rm -f "$(_cr_owner_file)"

# 13. a TERM to the daemon alone (ExecStop's first kill) is held until the sleep ends - at most
# the limit, as with the old sleep 2 - and the trap then runs to its end.
rm -f "$WORK/alone" "$WORK/alone.trap"
start_waiter "$WORK/alone" trap
start=$(now_ms)
kill -TERM "$waiter"
rc=0; wait "$waiter" || rc=$?
term_ms=$(( $(now_ms) - start ))
[ -e "$WORK/alone.trap" ] || fail "the TERM trap did not run to its end after the sleep (rc $rc)"
[ "$rc" -eq 143 ] || fail "the trap did not end the waiting process (rc $rc)"
[ "$term_ms" -lt 3000 ] || fail "the TERM trap finished ${term_ms}ms after the signal"

# 14. a sleep that cannot start is not hidden: the wait falls back to a plain sleep, whose error
# reaches the daemon's stderr (journald), rc 1.
rm -f "$pending"
{ PATH="$WORK/no-such-dir" timed_wait 2 "$pending" 0 "$wake_file"; } 2> "$WORK/nosleep.err"
[ "$wait_rc" -eq 1 ] || fail "a sleep that could not start returned $wait_rc, not 1"
grep -q sleep "$WORK/nosleep.err" || fail "a sleep that could not start left no error: $(head -c 200 "$WORK/nosleep.err")"

# 15. ExecStop[1] (cam_liveness_ordered_stop_systemd) ends the published sleep of $MAINPID - the
# daemon ExecStop[0] has just sent TERM - before it takes the recovery lock, and yields, so the
# daemon's trap takes the lock first and runs the stop itself; the lock wait then gives back the
# yield (74s, not 75s).  Without MAINPID, or for another pid, nothing is woken and it is as before.
race_case() {
    local what=$1 mainpid=$2 want=$3 got
    rm -f "$WORK/race" "$WORK/race.won" "$WORK/race.ready" "$WORK/order"
    start_waiter "$WORK/race" locktrap
    [ "$mainpid" != daemon ] || mainpid=$waiter
    kill -TERM "$waiter"
    (
        # the stop itself is stubbed: it records who held the lock first.
        # shellcheck disable=SC2317
        _cl_ordered_stop_systemd_locked() {
            if [ -e "$WORK/race.won" ]; then echo daemon; else echo systemd; fi > "$WORK/order"
        }
        MAINPID=$mainpid cam_liveness_ordered_stop_systemd
    ) || fail "$what: the systemd stop failed"
    wait "$waiter" || :
    got=$(cat "$WORK/order")
    [ "$got" = "$want" ] || fail "$what: the $got took the lock first, not the $want"
}
race_case 'the stopped daemon' daemon daemon
race_case 'no MAINPID' '' systemd
race_case 'another MAINPID' "$$" systemd
# the lock wait and the yield before it: woken, 74s after about 0.5s; otherwise 75s at once.  The
# waiter is left to end its own wait (it then ends its long-lived child too).
budget_case() {
    local what=$1 mainpid=$2 want=$3 lo=$4 hi=$5 got ms
    rm -f "$WORK/budget" "$WORK/budget.ready" "$WORK/lockwait"
    start_waiter "$WORK/budget"
    [ "$mainpid" != daemon ] || mainpid=$waiter
    (
        began=$(now_ms)
        # shellcheck disable=SC2317
        _cr_lock_call_wait() { echo "$1 $(( $(now_ms) - began ))" > "$WORK/lockwait"; }
        MAINPID=$mainpid cam_liveness_ordered_stop_systemd
    )
    read -r got ms < "$WORK/lockwait"
    [ "$got" = "$want" ] || fail "$what: the lock wait was ${got}s, not ${want}s"
    if [ "$ms" -lt "$lo" ] || [ "$ms" -gt "$hi" ]; then
        fail "$what: the lock wait began ${ms}ms after the stop, not ${lo}-${hi}ms"
    fi
    wait "$waiter" || :
}
budget_case 'a woken sleep' daemon 74 400 1000
budget_case 'nothing woken' '' 75 0 300
budget_case 'another MAINPID' "$$" 75 0 300

echo "monitor wait: PASS"
