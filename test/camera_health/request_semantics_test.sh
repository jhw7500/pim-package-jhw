#!/usr/bin/env bash
# Request transition and finish semantics, pinned before the issue #150 jq
# restructuring.  Every assertion describes the current code: which rc each
# rejection returns, which file is written before which, and how a finish that
# was interrupted by a crash resumes.  A change that merges jq calls must keep
# all of them; the recovery_protocol suite never asserts these directly.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-request-semantics.XXXXXX")
label=setup
# A command that fails under set -e outside expect_rc still names the section.
on_exit() { local rc=$?; rm -rf "$WORK"; [ "$rc" -eq 0 ] || echo "FAIL: $label: exited rc=$rc" >&2; }
trap on_exit EXIT
export PIM_CAMERA_RUN_DIR="$WORK/run/pim-camera"
export PIM_CAMERA_STATE_DIR="$WORK/var/lib/pim-camera"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot_id"
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
DAEMON_PID=4242
# shellcheck source=/dev/null
source "${REQUEST_SEMANTICS_LIB:-$PIM_LIB/cam_recovery.sh}"
# _coc_record_step is the real producer of the uncountered history steps.
# shellcheck source=/dev/null
source "$PIM_LIB/cam_operate_control.sh"
# Every _cr_now call returns a later second, so a resume that restamps
# finished_at changes the bytes even when crash and resume share a second.
# Callers use $(_cr_now), a subshell, so the clock lives in a file.
printf '1700000000\n' > "$WORK/clock"
_cr_now() { local now; now=$(( $(cat "$WORK/clock") + 1 )); printf '%s\n' "$now" > "$WORK/clock"; printf '%s\n' "$now"; }

fail() { echo "FAIL: $label: $*" >&2; exit 1; }
expect_rc() { local expected=$1 actual; shift; set +e +o pipefail; "$@"; actual=$?; set -e -o pipefail; [ "$actual" -eq "$expected" ] || fail "expected rc=$expected, got $actual: $*"; }
fake_stat() { mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"; { printf '%s' "$DAEMON_PID (cam operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' %s 0 0\n' "$1"; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"; }
fingerprint() { if [ -e "$1" ]; then cksum < "$1"; else echo ABSENT; fi; }
active_file="$PIM_CAMERA_RUN_DIR/recovery/active.json"
state_file="$PIM_CAMERA_STATE_DIR/recovery/state.json"
history_file() { printf '%s/recovery/history/%s.json' "$PIM_CAMERA_STATE_DIR" "$id"; }
result_file() { printf '%s/recovery/results/%s.json' "$PIM_CAMERA_RUN_DIR" "$id"; }
owner_edit() { jq -c "$1" "$PIM_CAMERA_RUN_DIR/owner.json" > "$WORK/owner.next" && mv "$WORK/owner.next" "$PIM_CAMERA_RUN_DIR/owner.json"; }
snapshot() {
    snap_active=$(fingerprint "$active_file"); snap_history=$(fingerprint "$(history_file)")
    snap_result=$(fingerprint "$(result_file)"); snap_state=$(fingerprint "$state_file")
}
unchanged() {
    local what
    for what in "$@"; do
        case $what in
            active) [ "$snap_active" = "$(fingerprint "$active_file")" ] || fail "active changed";;
            history) [ "$snap_history" = "$(fingerprint "$(history_file)")" ] || fail "history changed";;
            result) [ "$snap_result" = "$(fingerprint "$(result_file)")" ] || fail "result changed";;
            state) [ "$snap_state" = "$(fingerprint "$state_file")" ] || fail "state changed";;
        esac
    done
}
# A claimed request owned by a fresh ACTIVE owner; sets id.
start_request() {
    rm -rf "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROC_ROOT"
    printf 'test-boot-id\n' > "$PIM_CAMERA_BOOT_ID_FILE"
    fake_stat 111
    cam_owner_create "$DAEMON_PID"; cam_owner_set_lifecycle ACTIVE
    id=$(cam_request_submit "$1" operator "semantics $1")
    cam_request_claim
}
# Counted actions write state.json; gstapp_stop is never counted, so its
# finish must not need state.json at all.  Its history still holds a step:
# _coc_run_uncountered_step records gstapp_stop with countered:false, so the
# state.json requirement must come from counted actions, not from any action.
to_verifying() {
    start_request "$1"
    cam_request_transition QUIESCING; cam_request_transition RUNNING
    if [ "$2" = countered ]; then cam_action_counter_begin "$1" "$id"; fi
    if [ "$2" = uncountered ]; then _coc_record_step "$1" SUCCEEDED 0; fi
    cam_request_transition VERIFYING
    if [ "$2" = countered ]; then cam_action_counter_finish "$1" "$id" SUCCEEDED 0; fi
    if [ "$2" = uncountered ] && [ -e "$state_file" ]; then fail "precondition: uncountered request has state.json"; fi
    remember_actions
}
remember_actions() { actions_before=$(jq -c .actions "$(history_file)"); }
assert_finished() {
    local status=${1:-SUCCEEDED} rc=${2:-0}
    [ ! -e "$active_file" ] || fail "active survived finish"
    jq -e --arg s "$status" --argjson rc "$rc" '.status==$s and .rc==$rc' "$(result_file)" >/dev/null || fail "result is not $status/$rc"
    [ "$(jq -c .actions "$(history_file)")" = "$actions_before" ] || fail "finish changed the history actions"
    [ "$(jq -c '[.request.status,.request.rc,.request.finished_at]' "$(history_file)")" = "$(jq -c '[.status,.rc,.finished_at]' "$(result_file)")" ] \
        || fail "history request and result disagree"
}

# --- A. cam_request_transition ------------------------------------------------
label='transition argc'
start_request gstapp_restart
expect_rc 64 cam_request_transition
expect_rc 64 cam_request_transition QUIESCING RUNNING

label='transition not allowed'; snapshot
expect_rc 64 cam_request_transition RUNNING
unchanged active history

label='transition allowed'
cam_request_transition QUIESCING
jq -e --arg id "$id" '.id==$id and .status=="QUIESCING" and (.updated_at|type=="number")' "$active_file" >/dev/null || fail "active not QUIESCING"
[ "$(jq -cS .request "$(history_file)")" = "$(jq -cS . "$active_file")" ] || fail "history request does not mirror active"

# The transition table and the owner are judged before history is read, so a
# corrupt history must not turn 64 or 69 into 70.
printf '{broken\n' > "$(history_file)"
label='not allowed, corrupt history'; snapshot
expect_rc 64 cam_request_transition VERIFYING
unchanged active history
label='owner mismatch, corrupt history'
owner_edit '.created_at += 1'; snapshot
expect_rc 69 cam_request_transition RUNNING
expect_rc 69 cam_request_transition VERIFYING
unchanged active history
owner_edit '.created_at -= 1'
# Active is written first; a history that cannot be updated returns 70 after it.
label='allowed, corrupt history'; snapshot
expect_rc 70 cam_request_transition RUNNING
jq -e '.status=="RUNNING"' "$active_file" >/dev/null || fail "active was not written before the history failure"
unchanged history

label='allowed, missing history'
start_request gstapp_restart
rm -f "$(history_file)"
expect_rc 70 cam_request_transition QUIESCING
jq -e '.status=="QUIESCING"' "$active_file" >/dev/null || fail "active was not written before the history failure"
[ ! -e "$(history_file)" ] || fail "history recreated"

label='owner lifecycle gate'
start_request gstapp_restart
owner_edit '.lifecycle="STOPPING"'; snapshot
expect_rc 69 cam_request_transition QUIESCING
expect_rc 69 cam_request_transition RUNNING
unchanged active history
# jq index() matches sub-arrays, so the owner schema filter accepts ["ACTIVE"];
# the entry gate compares the lifecycle text in the shell and rejects it.
label='array lifecycle at transition'
owner_edit '.lifecycle=["ACTIVE"]'; snapshot
expect_rc 69 cam_request_transition QUIESCING
unchanged active history
label='missing active'
owner_edit '.lifecycle="ACTIVE"'
mv "$active_file" "$WORK/active.aside"
expect_rc 69 cam_request_transition QUIESCING
mv "$WORK/active.aside" "$active_file"

label='owner rollover before the active write'
start_request gstapp_restart; snapshot
PIM_CAMERA_TEST_OWNER_ROLLOVER=active expect_rc 69 cam_request_transition QUIESCING
unchanged active history
label='owner rollover before the history write'
start_request gstapp_restart; snapshot
PIM_CAMERA_TEST_OWNER_ROLLOVER=transition_history expect_rc 69 cam_request_transition QUIESCING
jq -e '.status=="QUIESCING"' "$active_file" >/dev/null || fail "active was not written before the history guard"
unchanged history

# --- B. cam_request_finish ----------------------------------------------------
label='finish without state.json (gstapp_stop)'
to_verifying gstapp_stop uncountered
expect_rc 0 cam_request_finish SUCCEEDED 0
assert_finished
[ ! -e "$state_file" ] || fail "finish created state.json"

label='gstapp_restart failed before its counter, no state.json'
start_request gstapp_restart
cam_request_transition QUIESCING; remember_actions
[ ! -e "$state_file" ] || fail "precondition: state.json exists"
expect_rc 0 cam_request_finish FAILED 5
assert_finished FAILED 5
[ ! -e "$state_file" ] || fail "finish created state.json"

label='apply_config succeeded, no state.json'
start_request apply_config
cam_request_transition QUIESCING; cam_request_transition RUNNING
_coc_record_step ord_restart SUCCEEDED 0; _coc_record_step policy_reload SUCCEEDED 0
cam_request_transition VERIFYING; remember_actions
[ "$(jq '[.actions[] | select(.countered == false)] | length' "$(history_file)")" -eq 2 ] || fail "precondition: uncountered steps missing"
[ ! -e "$state_file" ] || fail "precondition: state.json exists"
expect_rc 0 cam_request_finish SUCCEEDED 0
assert_finished
[ ! -e "$state_file" ] || fail "finish created state.json"

label='finish of a counted request needs state.json'
to_verifying gstapp_restart countered
rm -f "$state_file"; snapshot
expect_rc 70 cam_request_finish SUCCEEDED 0
unchanged active history result state

label='array lifecycle at finish'
to_verifying gstapp_stop uncountered
owner_edit '.lifecycle=["ACTIVE"]'; snapshot
expect_rc 69 cam_request_finish SUCCEEDED 0
unchanged active history result state

# B2: as in transition, the owner is judged before history is read.
label='finish owner mismatch, corrupt history'
to_verifying gstapp_stop uncountered
printf '{broken\n' > "$(history_file)"
owner_edit '.created_at += 1'; snapshot
expect_rc 69 cam_request_finish SUCCEEDED 0
unchanged active history result state
label='finish owner STOPPING, corrupt history'
owner_edit '.created_at -= 1 | .lifecycle="STOPPING"'; snapshot
expect_rc 69 cam_request_finish SUCCEEDED 0
unchanged active history result state

# B1: a transition interrupted between its active and history writes leaves
# active ahead of history; finish must refuse that pair, not certify it.
label='finish after a transition crash between active and history'
start_request gstapp_stop
cam_request_transition QUIESCING; cam_request_transition RUNNING
PIM_CAMERA_TEST_OWNER_ROLLOVER=transition_history expect_rc 69 cam_request_transition VERIFYING
owner_edit '.created_at -= 1'
jq -e '.status=="VERIFYING"' "$active_file" >/dev/null || fail "precondition: active not VERIFYING"
jq -e '.request.status=="RUNNING"' "$(history_file)" >/dev/null || fail "precondition: history not RUNNING"
snapshot
expect_rc 70 cam_request_finish SUCCEEDED 0
unchanged active history result state

# B5: owner guard positions inside finish.
label='owner rollover before the result write'
to_verifying gstapp_stop uncountered; snapshot
PIM_CAMERA_TEST_OWNER_ROLLOVER=result expect_rc 69 cam_request_finish SUCCEEDED 0
unchanged active history result state
label='owner rollover before the finish history write'
to_verifying gstapp_stop uncountered; snapshot
PIM_CAMERA_TEST_OWNER_ROLLOVER=finish_history expect_rc 69 cam_request_finish SUCCEEDED 0
[ -e "$(result_file)" ] || fail "result was not written before the history guard"
unchanged active history state
label='owner rollover before the active removal'
to_verifying gstapp_stop uncountered; snapshot
PIM_CAMERA_TEST_OWNER_ROLLOVER=active_remove expect_rc 69 cam_request_finish SUCCEEDED 0
[ -e "$(result_file)" ] || fail "result was not written before the removal guard"
jq -e '.request.status=="SUCCEEDED"' "$(history_file)" >/dev/null || fail "history was not written before the removal guard"
unchanged active state

# B6: a result that exists but is invalid is a failure, not a missing result.
label='corrupt result after a crash'
to_verifying gstapp_stop uncountered
PIM_CAMERA_TEST_FAILPOINT=request_finish_after_result expect_rc 70 cam_request_finish SUCCEEDED 0
printf '{broken\n' > "$(result_file)"; snapshot
expect_rc 70 cam_request_finish SUCCEEDED 0
unchanged active history result state

for kind in 'gstapp_restart countered' 'gstapp_stop uncountered'; do
    read -r type counting <<<"$kind"

    label="$type crash after result"
    to_verifying "$type" "$counting"
    PIM_CAMERA_TEST_FAILPOINT=request_finish_after_result expect_rc 70 cam_request_finish SUCCEEDED 0
    [ -e "$active_file" ] || fail "crash state lacks active"
    [ -e "$(result_file)" ] || fail "crash state lacks result"
    jq -e '.request.status=="VERIFYING"' "$(history_file)" >/dev/null || fail "history already terminal"
    snapshot
    expect_rc 70 cam_request_finish FAILED 3
    unchanged active history result state
    expect_rc 0 cam_request_finish SUCCEEDED 0
    unchanged result state
    assert_finished

    label="$type crash after history"
    to_verifying "$type" "$counting"
    PIM_CAMERA_TEST_FAILPOINT=request_finish_after_history expect_rc 70 cam_request_finish SUCCEEDED 0
    [ -e "$active_file" ] || fail "crash state lacks active"
    jq -e '.request.status=="SUCCEEDED"' "$(history_file)" >/dev/null || fail "history not terminal"
    snapshot
    expect_rc 70 cam_request_finish FAILED 3
    unchanged active history result state
    expect_rc 0 cam_request_finish SUCCEEDED 0
    unchanged history result state
    assert_finished

    label="$type terminal history, result lost"
    to_verifying "$type" "$counting"
    PIM_CAMERA_TEST_FAILPOINT=request_finish_after_history expect_rc 70 cam_request_finish SUCCEEDED 0
    cp "$(result_file)" "$WORK/result.before"; rm -f "$(result_file)"; snapshot
    expect_rc 70 cam_request_finish FAILED 3
    unchanged active history result state
    expect_rc 0 cam_request_finish SUCCEEDED 0
    cmp -s "$(result_file)" "$WORK/result.before" || fail "regenerated result differs from the lost one"
    unchanged history state
    assert_finished
done

echo "request semantics: PASS"
