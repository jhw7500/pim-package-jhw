#!/usr/bin/env bash
# shellcheck disable=SC2034  # the names set below are read by the functions evaluated from the daemon script
# CheckFinalArrival (issue #247): the final-path stall watch must reach its verdict.
#
# The daemon's `timer` is not "seconds since the app started".  It goes back to 0 while the
# start marker holds a value (every fragment start) and when no marker comes for
# rec_time + file_check_delay, so it never exceeds about 70s with the default config.  A
# warmup gate written against `timer` therefore never opened and the watch only ever wrote
# WARMUP.  The maintenance block that calls the watch also runs on every 2s iteration while
# the marker holds a value, so a gate that merely opens would count several stalls in one
# marker window.
#
# The minute-boundary start marker cannot arm the watch either: vcm writes it on its own
# schedule whether or not the camera app has opened a fragment.  The watch is armed by the
# session value that only gstApp writes when it opens a fragment, which the daemon loop reads
# when it consumes the marker.
#
# This test drives the function as the daemon loop does (same timer rules, 2s steps, a fake
# clock) and checks: a stall with fragments still starting is reported and walks the ladder,
# one verdict per warmup interval, no verdict before the current app instance has opened a
# fragment (even while vcm markers keep coming), a new app instance warms up again, a wall
# clock step does not count as a stall, a refused request is not counted, and steady arrivals
# never request anything.
#
# FINAL_STALL_DAEMON=<path> runs the same scenarios against another copy of the daemon
# script.  The pre-fix function fails scenario 1 already (it never leaves WARMUP); with
# FINAL_STALL_SKIP_STEADY=1 scenario 1 is left out and it fails scenario 2 with no request
# at all:
#   git show origin/master:dist/pim/opt/pim/bin/chk_cam_operate.sh > /tmp/chk_old.sh
#   FINAL_STALL_SKIP_STEADY=1 FINAL_STALL_DAEMON=/tmp/chk_old.sh bash <this test>
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DAEMON=${FINAL_STALL_DAEMON:-$ROOT/dist/pim/opt/pim/bin/chk_cam_operate.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-final-stall.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The watch and its helpers are one contiguous block of the daemon script:
# from _write_final_health() to the closing brace of CheckFinalArrival().
block=$(awk '
    /^_write_final_health\(\) \{/ { p = 1 }
    p { print }
    /^CheckFinalArrival\(\) \{/ { c = 1 }
    c && /^}/ { exit }
' "$DAEMON")
grep -q '^CheckFinalArrival() {' <<<"$block" || fail "could not extract CheckFinalArrival from $DAEMON"
# The block is evaluated at the start of every scenario (a fresh daemon), after the names it
# reads below are set.

# --- what the function reads from the daemon -------------------------------------------
KEY=RST
tag=final_stall_watch_test
ENABLE_VAL=true
app=gstApp
vhl_name=VD0001
cap_en=false
cap_record_en=false
csi1_en=1
csi2_en=1
file_check_delay=10
startup_grace_extra_sec=10
final_path_cfg="$WORK/final"
FINAL_HEARTBEAT_FILE="$WORK/cam_last_final_ts"
FINAL_HEALTH_FILE="$WORK/cam_final_health"
FILE_CHECK="$WORK/file_check"
REQUESTS="$WORK/requests"
PIM_CAMERA_RUNTIME_JSON="$WORK/runtime.json"
export PIM_CAMERA_PROCESS_ROOT="$WORK/proc"
mkdir -p "$final_path_cfg" "$PIM_CAMERA_PROCESS_ROOT"

# --- stubs --------------------------------------------------------------------------------
# NOW is the monotonic clock (/proc/uptime); the wall clock is NOW + WALL_SKEW.
NOW=5000
WALL_SKEW=1700000000
date() {
    if [ "${1:-}" = "+%s" ]; then echo "$((NOW + WALL_SKEW))"; else command date "$@"; fi
}
_cam_runtime_app_into() { printf -v "$1" '%s' gstApp; }
logger() { :; }
is_ram_only_mode() { [ "$RAM_ONLY" = 1 ]; }
# The fallback scan sees no recent file unless a scenario says so.
find() { [ "$FIND_HIT" != 1 ] || echo "$final_path_cfg/${vhl_name}_x"; }
pgrep() {
    [ -n "$APP_PID" ] || return 1
    echo "$APP_PID"
}
# A request is carried out at once.  With EFFECT=1 an app restart gives a new pid that
# starts its first fragment START_DELAY seconds later; with EFFECT=0 nothing changes.
cam_submit_internal_action() {
    if [ "$REFUSE" -gt 0 ]; then
        REFUSE=$((REFUSE - 1))
        REFUSED=$((REFUSED + 1))
        return 75
    fi
    printf '%s %s\n' "$1" "$((NOW - T0))" >> "$REQUESTS"
    case "$1" in
        gstapp_restart|module_reload)
            if [ "$EFFECT" = 1 ]; then
                APP_PID=$((APP_PID + 1))
                REC_START=$((NOW + START_DELAY))
                timer=0
            fi
            [ "$ARRIVE_AFTER_RESTART" != 1 ] || ARRIVE=1
            ;;
        reboot_fallback) REBOOT=1 ;;
    esac
}

# --- the daemon loop, reduced to what moves `timer` and calls the watch ----------------------
# One iteration is 2s.  The start marker holds a value for the first file_check_delay
# seconds after every fragment boundary: vcm writes it on its schedule (VCM=1) whether or not
# the app records, gstApp writes it when it opens a fragment.  While it holds a value timer is
# 0; without a marker timer returns to 0 at rec_time + file_check_delay ("no start marker").
# When the loop consumes the marker it also reads the session value, which only a recording
# gstApp has written, and tells the watch.  The maintenance block runs when timer % 60 == 0.
# A finished fragment reaches the final path 2s after the next one starts.
sim_run() {
    local end=$((NOW + $1)) rel phase recording
    while [ "$NOW" -lt "$end" ] && [ "$REBOOT" != 1 ]; do
        echo "$NOW.00 0.00" > "$PIM_CAMERA_PROCESS_ROOT/uptime"
        startTime=""
        recording=0
        phase=$(( (NOW - T0) % rec_time ))
        if [ "$REC_START" -ge 0 ] && [ "$NOW" -ge "$REC_START" ]; then
            recording=1
            rel=$((NOW - REC_START))
            phase=$((rel % rec_time))
            if [ "$ARRIVE" = 1 ] && [ "$rel" -ge "$rec_time" ] && [ "$phase" -ge 2 ] && [ "$phase" -lt 4 ]; then
                echo "$((NOW + WALL_SKEW))" > "$FINAL_HEARTBEAT_FILE"
            fi
        fi
        if [ "$recording" = 1 ] || [ "$VCM" = 1 ]; then
            [ "$phase" -gt "$file_check_delay" ] || startTime="marker"
        fi
        if [ -n "$startTime" ]; then
            timer=0
            # The iteration that consumes the marker: gstApp's session value, if any.
            if [ "$phase" -ge "$file_check_delay" ] && [ "$recording" = 1 ] && declare -F FinalWatchNoteSession >/dev/null; then
                FinalWatchNoteSession || :
            fi
        elif [ "$timer" -ge $((rec_time + file_check_delay)) ]; then
            timer=0
        fi
        if [ $((timer % 60)) -eq 0 ]; then
            CheckFinalArrival || :
        fi
        timer=$((timer + 2))
        NOW=$((NOW + 2))
    done
}

scenario() {  # name, rec_min
    name=$1
    rec_min=$2
    rec_time=$((rec_min * 60))
    timer=0
    final_stall_cnt=0
    file_chk_reboot=true
    RAM_ONLY=0
    FIND_HIT=0
    APP_PID=100
    REC_START=$NOW
    ARRIVE=1
    ARRIVE_AFTER_RESTART=0
    EFFECT=1
    START_DELAY=20
    REBOOT=0
    VCM=1
    REFUSE=0
    REFUSED=0
    T0=$NOW
    startTime=""
    rm -f "$FINAL_HEARTBEAT_FILE" "$FINAL_HEALTH_FILE" "$REQUESTS"
    : > "$REQUESTS"
    # A fresh daemon: forget whatever the previous scenario left in the watch's own state.
    eval "$block"
}
requests() { cut -d' ' -f1 "$REQUESTS" | tr '\n' ' ' | sed 's/ $//'; }
request_times() { cut -d' ' -f2 "$REQUESTS" | tr '\n' ' ' | sed 's/ $//'; }
status() { cut -d' ' -f1 "$FINAL_HEALTH_FILE" 2>/dev/null || :; }
expect_requests() {
    local got
    got=$(requests)
    [ "$got" = "$1" ] || fail "$name: requests were [$got] at [$(request_times)]s, expected [$1]"
}
expect_status() {
    local got
    got=$(status)
    [ "$got" = "$1" ] || fail "$name: status is [$got], expected [$1] ($(cat "$FINAL_HEALTH_FILE" 2>/dev/null))"
}
# No two verdicts closer than the check window: one stall is counted once.
expect_spacing() {
    local prev="" t
    for t in $(request_times); do
        if [ -n "$prev" ] && [ $((t - prev)) -lt "$1" ]; then
            fail "$name: two requests ${prev}s and ${t}s are closer than ${1}s"
        fi
        prev=$t
    done
}

# 1. Fragments arrive every minute: nothing is requested and the watch reports OK.
if [ "${FINAL_STALL_SKIP_STEADY:-0}" != 1 ]; then
    scenario 'steady arrivals' 1
    sim_run 900
    expect_requests ''
    expect_status OK
fi

# 2. Fragments keep starting but none arrives; each restart brings a new app instance that
#    stalls the same way.  The ladder runs to the reboot request, one step per verdict.
scenario 'silent stall, restarts take effect' 1
ARRIVE=0
sim_run 2400
expect_requests 'gstapp_restart gstapp_restart module_reload module_reload reboot_fallback'
expect_spacing 140

# 3. The same stall when the requests change nothing (same pid keeps recording): still one
#    step per verdict, not one per maintenance pass.
scenario 'silent stall, requests change nothing' 1
ARRIVE=0
EFFECT=0
sim_run 2400
expect_requests 'gstapp_restart gstapp_restart module_reload module_reload reboot_fallback'
expect_spacing 140

# 4. file_check_reboot is off: after the fourth step the counter starts over, no reboot.
scenario 'silent stall, reboot disabled' 1
ARRIVE=0
EFFECT=0
file_chk_reboot=false
sim_run 1500
case "$(requests)" in
    'gstapp_restart gstapp_restart module_reload module_reload'*) ;;
    *) fail "$name: requests were [$(requests)]" ;;
esac
grep -q reboot_fallback "$REQUESTS" && fail "$name: a reboot was requested with file_check_reboot off"

# 5. The app is up but has not opened a fragment (slow camera prepare) while vcm keeps
#    writing the minute marker: no verdict however long it takes.  Once it records and
#    fragments arrive the watch reports OK.
scenario 'slow start under vcm markers' 1
REC_START=-1
sim_run 600
expect_requests ''
expect_status WARMUP
REC_START=$NOW
sim_run 400
expect_requests ''
expect_status OK

# 5b. A restart that takes long to record again (160s) is not a second stall: the watch
#     waits for the new instance to open a fragment.
scenario 'stall, slow restart cures it' 1
ARRIVE=0
ARRIVE_AFTER_RESTART=1
START_DELAY=160
sim_run 300
# While the requested recovery is awaited the status stays STALL, not WARMUP.
expect_requests 'gstapp_restart'
expect_status STALL
sim_run 1200
expect_requests 'gstapp_restart'
expect_status OK

# 5c. Another ladder restarts the app during a healthy run and the new instance takes 160s
#     to record again.  The watch was armed for the old instance; before a verdict it sees
#     the pid changed and waits for the new one instead of counting the gap as a stall.
scenario 'external restart, slow start' 1
sim_run 300
APP_PID=$((APP_PID + 1))
REC_START=$((NOW + 160))
timer=0
sim_run 600
expect_requests ''
expect_status OK

# 5d. No arrival is recorded in the arrival-time file, but the final path has recent files
#     (the fallback scan): not a stall.
scenario 'recent final files without the arrival file' 1
ARRIVE=0
FIND_HIT=1
sim_run 900
expect_requests ''
case "$(status)" in
    OK|OK_FB) ;;
    *) fail "$name: status is [$(status)], expected OK or OK_FB" ;;
esac

# 6. One stall, the restart cures it: a single request, then OK with the counter back at 0.
scenario 'stall cured by the first restart' 1
ARRIVE=0
ARRIVE_AFTER_RESTART=1
sim_run 1200
expect_requests 'gstapp_restart'
expect_status OK
[ "$final_stall_cnt" -eq 0 ] || fail "$name: the counter stayed at $final_stall_cnt after arrivals resumed"

# 7. A stall that begins in the middle of a healthy run is caught too.
scenario 'stall after healthy minutes' 1
sim_run 600
expect_requests ''
ARRIVE=0
ARRIVE_AFTER_RESTART=1
sim_run 600
expect_requests 'gstapp_restart'
first=$(request_times)
[ "$first" -ge 720 ] || fail "$name: the stall was reported ${first}s in, before the 2-minute window had passed"

# 8. Five-minute fragments: the window is 10 minutes, and the stall is still reported.
scenario 'silent stall, rec_min 5' 5
ARRIVE=0
ARRIVE_AFTER_RESTART=1
sim_run 3000
expect_requests 'gstapp_restart'
first=$(request_times)
[ "$first" -ge 600 ] || fail "$name: the stall was reported ${first}s in, before the 10-minute window had passed"

# 9. The wall clock steps forward a year during a healthy run: not a stall.
scenario 'wall clock step' 1
sim_run 400
WALL_SKEW=$((WALL_SKEW + 31536000))
sim_run 600
expect_requests ''
expect_status OK
WALL_SKEW=1700000000

# 10. A refused request (another request in flight) is not counted as a ladder step.
scenario 'refused request' 1
ARRIVE=0
EFFECT=0
REFUSE=2
sim_run 1500
[ "$REFUSED" -eq 2 ] || fail "$name: $REFUSED submissions were refused, expected 2"
case "$(requests)" in
    'gstapp_restart gstapp_restart module_reload'*) ;;
    *) fail "$name: requests were [$(requests)]; refused submissions must not use up ladder steps" ;;
esac

# 11. RAM-only mode and disabled recording still stand the watch down.
scenario 'ram only' 1
ARRIVE=0
RAM_ONLY=1
sim_run 900
expect_requests ''
expect_status RAM_ONLY
scenario 'recording disabled' 1
ARRIVE=0
csi1_en=0
csi2_en=0
sim_run 900
expect_requests ''
expect_status REC_DISABLED
csi1_en=1
csi2_en=1

# The loop arms the watch in one place only: where it has read gstApp's session value.  A
# call keyed on the minute marker instead would let vcm's markers arm it (scenario 5).
calls=$(grep -n 'FinalWatchNoteSession' "$DAEMON" | grep -v -E '^[0-9]+:(FinalWatchNoteSession\(\) \{|[[:space:]]*#)' || :)
[ "$(grep -c . <<<"$calls")" -eq 1 ] || fail "the daemon calls FinalWatchNoteSession in other than one place: $calls"
grep -q -E '^[0-9]+:[[:space:]]+\[ -z "\$session_id" \] \|\| FinalWatchNoteSession$' <<<"$calls" \
    || fail "the daemon does not arm the watch from the session value: $calls"

echo "final stall watch: PASS"
