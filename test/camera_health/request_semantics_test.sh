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
# A fresh ACTIVE owner with no request.
fresh_owner() {
    rm -rf "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROC_ROOT"
    printf 'test-boot-id\n' > "$PIM_CAMERA_BOOT_ID_FILE"
    fake_stat 111
    cam_owner_create "$DAEMON_PID"; cam_owner_set_lifecycle ACTIVE
}
# A claimed request owned by a fresh ACTIVE owner; sets id.
start_request() {
    fresh_owner
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

# --- C. counter begin/finish gates on the active record ----------------------
# Both read the active status and id; a request that is not in the right phase,
# or another request's id, is refused with 64 before anything is written.
other_id=00000000-0000-4000-8000-000000000000
label='counter begin on a request that is not RUNNING'
start_request gstapp_restart
cam_request_transition QUIESCING; snapshot
expect_rc 64 cam_action_counter_begin gstapp_restart "$id"
unchanged active history state
label='counter begin for another request id'
cam_request_transition RUNNING; snapshot
expect_rc 64 cam_action_counter_begin gstapp_restart "$other_id"
unchanged active history state
label='counter finish for another request id'
cam_action_counter_begin gstapp_restart "$id"; snapshot
expect_rc 64 cam_action_counter_finish gstapp_restart "$other_id" SUCCEEDED 0
unchanged active history state
label='counter finish on a request that is neither RUNNING nor VERIFYING'
cam_request_transition FAILED; snapshot
expect_rc 64 cam_action_counter_finish gstapp_restart "$id" FAILED 3
unchanged active history state

# --- D. the owner guard before every write (_cr_record_owner_ready) ----------
# The memo holds what jq extracted, never a verdict: each caller's lifecycle
# set is compared afresh, so one caller's rejection is not another's answer.
label='owner guard lifecycle sets'
start_request gstapp_restart
record=$(cat "$active_file")
expect_rc 0 _cr_record_owner_ready "$record" ACTIVE DEGRADED
expect_rc 69 _cr_record_owner_ready "$record" RECOVERING APPLYING_CONFIG
expect_rc 0 _cr_record_owner_ready "$record" ACTIVE
expect_rc 69 _cr_record_owner_ready "$record"
label='owner guard on a multi-document record'
expect_rc 69 _cr_record_owner_ready "$record"$'\n'"$record" ACTIVE
label='owner guard on a multi-document owner'
cp "$PIM_CAMERA_RUN_DIR/owner.json" "$WORK/owner.single"
cat "$WORK/owner.single" "$WORK/owner.single" > "$PIM_CAMERA_RUN_DIR/owner.json"
expect_rc 69 _cr_record_owner_ready "$record" ACTIVE
cp "$WORK/owner.single" "$PIM_CAMERA_RUN_DIR/owner.json"
# Stricter than before issue #150 (a): the owner schema filter used index(),
# which finds the sub-array ["ACTIVE"], so the guard accepted it.  The filter now
# requires a string - for the live owner and for the owner a record carries.
label='owner guard on a record whose owner lifecycle is an array'
array_record=$(jq -c '.owner.lifecycle=["ACTIVE"]' <<<"$record")
expect_rc 69 _cr_record_owner_ready "$array_record" ACTIVE
expect_rc 1 _cr_record_owner_matches "$array_record"
guard_err=$(_cr_record_owner_ready "$array_record" ACTIVE 2>&1 >/dev/null || true)
[ -z "$guard_err" ] || fail "the array lifecycle was refused through a jq error: $guard_err"
label='owner guard on an array lifecycle'
owner_edit '.lifecycle=["ACTIVE"]'
expect_rc 69 _cr_record_owner_ready "$record" ACTIVE
guard_err=$(_cr_record_owner_ready "$record" ACTIVE 2>&1 >/dev/null || true)
[ -z "$guard_err" ] || fail "the array lifecycle was refused through a jq error: $guard_err"

# Claim and history updates pass the record to jq as one argument, which exec
# refuses from 128KiB.  The guard refuses such a record before it is written,
# so a request that could never be claimed does not block the queue.
label='a record too long for one argument is refused at submit'
fresh_owner
long=$(printf '%070000d' 0)
expect_rc 69 cam_request_submit gstapp_restart "$long" "$long"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "an unclaimable request was queued"
id=$(cam_request_submit gstapp_restart operator 'after a refused long request')
expect_rc 0 cam_request_claim

# --- E. behaviour the issue #150 redesign is approved to change --------------
# Pinned as it is today, so that the redesign changes it by flipping these
# assertions on purpose rather than as a side effect.

# Approved change (1): a history file holding two JSON documents only comes from
# tampering.  Today the transition updates both, because jq applies
# '.request=$request' to every document of the stream, and returns 0.
label='transition with a two-document history'
start_request gstapp_restart
cam_request_transition QUIESCING
history_doc=$(cat "$(history_file)")
printf '%s\n%s\n' "$history_doc" "$history_doc" > "$(history_file)"
expect_rc 0 cam_request_transition RUNNING
jq -e '.status=="RUNNING"' "$active_file" >/dev/null || fail "active is not RUNNING"
history_next=$(jq -c --argjson a "$(cat "$active_file")" '.request=$a' <<<"$history_doc")
printf '%s\n%s\n' "$history_next" "$history_next" | cmp -s - "$(history_file)" \
    || fail "history is not the two documents, each with the new request"

# Approved change (3): a record just under the 128KiB argument limit passes the
# submit guard (section D pins the refusal from 128KiB on), but the operations
# that hand jq a document larger than the record as one argument fail on it.
# The redesign passes no document through argv and is expected to flip both
# cases below to a completed request.  Sizes are exact in this sandbox: owner
# fields, uuids and timestamps have fixed lengths, so a record is a fixed part
# plus the reason, and each case checks the size it asked for.
label='near-limit record: fixed part'
fresh_owner
cam_request_submit gstapp_restart operator x >/dev/null
record_fixed=$(( $(wc -c < "$PIM_CAMERA_RUN_DIR/recovery/pending.json") - 2 ))
# A pending gstapp_restart whose record is exactly $1 bytes; sets id.
near_limit_request() {
    local bytes=$1
    fresh_owner
    id=$(cam_request_submit gstapp_restart operator "$(printf "%0$(( bytes - record_fixed ))d" 0)") \
        || fail "submit refused a $bytes-byte record (rc $?)"
    [ "$(( $(wc -c < "$PIM_CAMERA_RUN_DIR/recovery/pending.json") - 1 ))" -eq "$bytes" ] || fail "the record is not $bytes bytes"
}
# exec's refusal is the cause being pinned; its message goes to a file.
argv_call() { "$@" 2>>"$WORK/argv.err"; }
countered_to_verifying() {
    expect_rc 0 argv_call cam_request_claim
    expect_rc 0 argv_call cam_request_transition QUIESCING
    expect_rc 0 argv_call cam_request_transition RUNNING
    expect_rc 0 argv_call cam_action_counter_begin gstapp_restart "$id"
    expect_rc 0 argv_call cam_request_transition VERIFYING
    expect_rc 0 argv_call cam_action_counter_finish gstapp_restart "$id" SUCCEEDED 0
}
# Control: the same request with a smaller record completes.
label='near-limit record: 130000 bytes completes'
near_limit_request 130000
countered_to_verifying; remember_actions
expect_rc 0 argv_call cam_request_finish SUCCEEDED 0
assert_finished
# 131000 bytes: every step up to finish succeeds; finish passes the history,
# which embeds the record, to jq as one argument and returns 70 before writing
# anything, so active.json is left behind.
label='near-limit record: 131000 bytes, finish fails'
: > "$WORK/argv.err"
near_limit_request 131000
countered_to_verifying; snapshot
expect_rc 70 argv_call cam_request_finish SUCCEEDED 0
unchanged active history result state
jq -e '.status=="VERIFYING"' "$active_file" >/dev/null || fail "active is not left at VERIFYING"
grep -q 'Argument list too long' "$WORK/argv.err" || fail "finish did not fail on exec's argument limit"
# 131060 bytes: the first transition adds status and updated_at, which takes
# the updated record over the guard's limit; it returns 69 and writes nothing.
label='near-limit record: 131060 bytes, first transition fails'
near_limit_request 131060
expect_rc 0 argv_call cam_request_claim; snapshot
expect_rc 69 argv_call cam_request_transition QUIESCING
unchanged active history
jq -e '.status=="PENDING"' "$active_file" >/dev/null || fail "active is not left at PENDING"

echo "request semantics: PASS"
