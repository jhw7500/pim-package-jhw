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
# shellcheck disable=SC2317 # called by the library, not by this file
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
prev_active=$(cat "$active_file")
cam_request_transition QUIESCING
# The written record is byte for byte what jq -c makes of the update.
[ "$(cat "$active_file")" = "$(jq -c --argjson t "$(jq .updated_at "$active_file")" '.status="QUIESCING" | .updated_at=$t' <<<"$prev_active")" ] \
    || fail "active is not the jq -c serialization of the update"
jq -e --arg id "$id" '.id==$id and .status=="QUIESCING" and (.updated_at|type=="number")' "$active_file" >/dev/null || fail "active not QUIESCING"
[ "$(jq -cS .request "$(history_file)")" = "$(jq -cS . "$active_file")" ] || fail "history request does not mirror active"

# The owner and the transition table are judged before the history is, so a
# corrupt history must not turn 64 or 69 into 70.  (The transition reads the
# history earlier since issue #150 - one jq takes both documents - but judges it
# only after the table.)
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

# Edge inputs the one-jq transition must read exactly as the old per-field jq
# calls did, whose $(...) dropped NUL bytes and trailing newlines.
active_edit() { jq -c "$1" "$active_file" > "$WORK/active.next" && mv "$WORK/active.next" "$active_file"; }
label='transition with a status that ends in a newline'
start_request gstapp_restart
active_edit '.status="PENDING\n"'
expect_rc 0 cam_request_transition QUIESCING
jq -e '.status=="QUIESCING"' "$active_file" >/dev/null || fail "active not QUIESCING"
[ "$(jq -cS .request "$(history_file)")" = "$(jq -cS . "$active_file")" ] || fail "history request does not mirror active"
label='transition with an id that ends in a newline'
start_request gstapp_restart
active_edit '.id += "\n"'
expect_rc 0 cam_request_transition QUIESCING
[ "$(jq -cS .request "$(history_file)")" = "$(jq -cS . "$active_file")" ] || fail "history request does not mirror active"
record=$(cat "$active_file"); memo_id=
_cr_jq_memo memo_id "$record" -r .id
[ "$memo_id" = "$(jq -r .id <<<"$record")" ] || fail "the memo holds another .id than jq prints: '$memo_id'"
# Approved with the redesign: an active record whose id is not a UUID gets no
# history path at all (it used to be joined into one unchecked, which can point
# outside the history directory); the history counts as unwritable.
label='transition with an id that is not a UUID'
start_request gstapp_restart
active_edit '.id="not-a-uuid"'
printf '%s\n' '{"request":{},"actions":[]}' > "$PIM_CAMERA_STATE_DIR/recovery/history/not-a-uuid.json"
crafted=$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/history/not-a-uuid.json")
expect_rc 70 cam_request_transition QUIESCING
jq -e '.status=="QUIESCING"' "$active_file" >/dev/null || fail "active was not written before the history failure"
[ "$crafted" = "$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/history/not-a-uuid.json")" ] || fail "a history outside the request's own path was written"
# Approved with the redesign: when jq cannot run at all the transition is 70,
# not the 64 it used to report after its status extraction failed.
label='transition when jq cannot run'
start_request gstapp_restart
cam_request_transition QUIESCING
mkdir -p "$WORK/nojq"; printf '#!/bin/sh\nexit 5\n' > "$WORK/nojq/jq"; chmod +x "$WORK/nojq/jq"
snapshot
PATH="$WORK/nojq:$PATH" expect_rc 70 cam_request_transition RUNNING
unchanged active history
hash -r
label='transition with a clock that prints no number'
start_request gstapp_restart
clock_fn=$(declare -f _cr_now)
# shellcheck disable=SC2317 # called by the library, not by this file
_cr_now() { echo not-a-number; }
snapshot
expect_rc 64 cam_request_transition RUNNING
expect_rc 70 cam_request_transition QUIESCING
unchanged active history
eval "$clock_fn"

# --- E. behaviour the issue #150 redesign is approved to change --------------
# Pinned as it is today, so that the redesign changes it by flipping these
# assertions on purpose rather than as a side effect.

# Approved change (1), made by the redesign: a history file holding two JSON
# documents, or none, only comes from tampering.  The transition used to update
# both documents, because jq applied '.request=$request' to every document of
# the stream, and to rewrite an empty file as an empty line - both with rc 0.  It
# now reads the history as one document, so these are histories it cannot
# update: 70 after the active write, as for any corrupt history.
label='transition with a two-document history'
start_request gstapp_restart
cam_request_transition QUIESCING
history_doc=$(cat "$(history_file)")
printf '%s\n%s\n' "$history_doc" "$history_doc" > "$(history_file)"
snapshot
expect_rc 70 cam_request_transition RUNNING
jq -e '.status=="RUNNING"' "$active_file" >/dev/null || fail "active was not written before the history failure"
unchanged history
for empty in '' '  '; do
    label="transition with an empty history ('$empty')"
    start_request gstapp_restart
    printf '%s' "$empty" > "$(history_file)"
    snapshot
    expect_rc 70 cam_request_transition QUIESCING
    jq -e '.status=="QUIESCING"' "$active_file" >/dev/null || fail "active was not written before the history failure"
    unchanged history
done

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

# --- F. claim and submit judge their documents as the old per-step jq did ----
# One jq per operation since issue #150 PR2: the outcomes below are the old
# ones under jq 1.6, which reflects only the last document of a stream in its
# rc and prints nothing for a document that fails.  The claim's shape test
# (jq -e) is 70 when the last document fails or is false and passes on no
# document; the owner match (jq -c .owner) is 69 unless exactly one document
# yields an owner; the history (--argjson) is 70 for anything but one document.
pending_file="$PIM_CAMERA_RUN_DIR/recovery/pending.json"
# The review's oracle: every memo entry is what jq prints for its key, so a
# prefilled value stands in for the jq it saves.
memo_matches_jq() {
    local key expect args=()
    for key in "${!_CR_JQ_MEMO[@]}"; do
        mapfile -d $'\037' -t args < <(printf '%s' "${key%%$'\036'*}")
        expect=$(jq "${args[@]}" <<<"${key#*$'\036'}" 2>/dev/null) || fail "the memo holds a value jq does not print: ${args[*]}"
        [ "${_CR_JQ_MEMO[$key]}" = "$expect" ] || fail "the memo holds another value than jq prints: ${args[*]}"
    done
}
# A well-formed pending owned by the current owner; $1 is a shell snippet that
# turns it ($good) into the text the case writes.
claim_case() { # label, text-making snippet, expected rc
    label="claim with $1"
    fresh_owner; mkdir -p "$(dirname "$pending_file")"
    local good text before
    # shellcheck disable=SC2034 # read by the eval'd snippet in $2
    good=$(jq -cn --argjson o "$(cat "$PIM_CAMERA_RUN_DIR/owner.json")" '{id:"11111111-2222-4333-8444-555555555555",type:"gstapp_restart",source:"s",reason:"r",status:"PENDING",created_at:1,owner:$o}')
    text=$(eval "$2"); printf '%s\n' "$text" > "$pending_file"
    before=$(fingerprint "$pending_file")
    expect_rc "$3" cam_request_claim
    [ "$before" = "$(fingerprint "$pending_file")" ] || fail "the pending request changed"
    [ ! -e "$active_file" ] || fail "an active request was created"
    [ -z "$(ls -A "$PIM_CAMERA_STATE_DIR/recovery/history" 2>/dev/null)" ] || fail "a history was written"
}
# shellcheck disable=SC2016 # expanded by claim_case
{
# jq 1.7 gives 4 on empty input, so the old code there was 70.
claim_case 'an empty pending' 'printf ""' 69
claim_case 'two pending documents' 'printf "%s\n%s" "$good" "$good"' 69
claim_case 'a pending followed by a number' 'printf "%s 5" "$good"' 70
claim_case 'a number, then a pending' 'printf "1 %s" "$good"' 70
claim_case 'a pending, true, a pending' 'printf "%s true %s" "$good" "$good"' 69
claim_case 'a number, then a pending of another owner' 'printf "1 %s" "$(jq -c ".owner.token=\"other\"" <<<"$good")"' 69
claim_case 'a false id' 'jq -c ".id=false" <<<"$good"' 70
claim_case 'an array' 'printf "[]"' 70
claim_case 'null' 'printf null' 70
# The old history took the pending as one argument, which exec refuses from
# 128KiB on - 70 before the guard's 69.
claim_case 'a pending of 131072 bytes' 'jq -c --arg r "$(printf "%0$(( 131072 - ${#good} + 1 ))d" 0)" ".reason=\$r" <<<"$good"' 70
# Approved with the redesign, as for the transition: no history path from an id
# that is not a UUID, and nothing is written.
claim_case 'an id that is not a UUID' 'jq -c ".id=\"not-a-uuid\"" <<<"$good"' 70
}
memo_matches_jq
label='claim of a 131071-byte pending'
fresh_owner; mkdir -p "$(dirname "$pending_file")"
pending=$(jq -cn --argjson o "$(cat "$PIM_CAMERA_RUN_DIR/owner.json")" '{id:"11111111-2222-4333-8444-555555555555",type:"gstapp_restart",source:"s",reason:"r",status:"PENDING",created_at:1,owner:$o}')
pending=$(jq -c --arg r "$(printf "%0$(( 131071 - ${#pending} + 1 ))d" 0)" '.reason=$r' <<<"$pending"); printf '%s\n' "$pending" > "$pending_file"
[ "${#pending}" -eq 131071 ] || fail "the pending is not 131071 bytes"
expect_rc 0 cam_request_claim
label='claim of a well-formed pending'
fresh_owner; mkdir -p "$(dirname "$pending_file")"
pending=$(jq -cn --argjson o "$(cat "$PIM_CAMERA_RUN_DIR/owner.json")" '{id:"11111111-2222-4333-8444-555555555555",type:"gstapp_restart",source:"s",reason:"r",status:"PENDING",created_at:1,owner:$o}'); printf '%s\n' "$pending" > "$pending_file"
id=$(jq -r .id <<<"$pending")
expect_rc 0 cam_request_claim
[ "$(cat "$(history_file)")" = "$(jq -cn --argjson request "$pending" '{request:$request,actions:[]}')" ] \
    || fail "the history is not the old serialization"
memo_owner=; memo_id=
_cr_jq_memo memo_owner "$pending" -c .owner; _cr_jq_memo memo_id "$pending" -r .id
[ "$memo_owner" = "$(jq -c .owner <<<"$pending")" ] || fail "the memo holds another .owner than jq prints"
[ "$memo_id" = "$id" ] || fail "the memo holds another .id than jq prints"

label='submit writes the old request bytes'
fresh_owner
clock_before=$(cat "$WORK/clock")
id=$(cam_request_submit module_reload watcher 'old bytes' /source/path 123)
request=$(cat "$pending_file")
[ "$request" = "$(jq -cn --arg id "$id" --argjson now "$((clock_before + 1))" --argjson owner "$(cat "$PIM_CAMERA_RUN_DIR/owner.json")" '{id:$id,type:"module_reload",source:"watcher",reason:"old bytes",status:"PENDING",created_at:$now,owner:$owner,source_path:"/source/path",source_mtime:123}')" ] \
    || fail "the request is not the old serialization: $request"
memo_owner=
_cr_jq_memo memo_owner "$request" -c .owner
[ "$memo_owner" = "$(jq -c .owner <<<"$request")" ] || fail "the memo holds another .owner than jq prints"
label='submit with a clock that prints no number'
fresh_owner
clock_fn=$(declare -f _cr_now)
# shellcheck disable=SC2317 # called by the library, not by this file
_cr_now() { echo not-a-number; }
expect_rc 70 cam_request_submit gstapp_restart operator 'no clock'
[ ! -e "$pending_file" ] || fail "a pending request was written"
eval "$clock_fn"
# The owner checks before the request see only the last document, so a number
# before the owner passes them and the old schema test.  The exported context,
# when there is one, then refused two documents (69); without it the old
# request did (70).
label='submit with a number before the owner'
fresh_owner
{ printf '1 '; cat "$PIM_CAMERA_RUN_DIR/owner.json"; } > "$WORK/owner.tmp"; mv "$WORK/owner.tmp" "$PIM_CAMERA_RUN_DIR/owner.json"
[ -n "${PIM_CAMERA_OWNER_INVOCATION:-}" ] || fail "the owner context is not exported"
expect_rc 69 cam_request_submit gstapp_restart operator 'two owner documents'
PIM_CAMERA_OWNER_INVOCATION='' expect_rc 70 cam_request_submit gstapp_restart operator 'two owner documents'
[ ! -e "$pending_file" ] || fail "a pending request was written"
# The old request took the owner and each field as one argument each, which
# exec refuses from 128KiB on - 70 after the schema; one byte less reaches the
# guard, whose limit the request is then over (69).
label='submit with a reason of 131072 bytes'
fresh_owner; : > "$WORK/argv.err"
expect_rc 70 argv_call cam_request_submit gstapp_restart operator "$(printf '%0131072d' 0)"
[ ! -e "$pending_file" ] || fail "a pending request was written"
grep -q 'Argument list too long' "$WORK/argv.err" || fail "submit did not fail on exec's argument limit"
# The owner of exactly $1 bytes, padded with a field the schema allows.
pad_owner() {
    local file="$PIM_CAMERA_RUN_DIR/owner.json" base
    base=$(jq -c '.pad=""' "$file")
    jq -c --arg p "$(printf "%0$(( $1 - ${#base} ))d" 0)" '.pad=$p' "$file" > "$file.tmp"; mv "$file.tmp" "$file"
    [ "$(( $(wc -c < "$file") - 1 ))" -eq "$1" ] || fail "the owner is not $1 bytes"
}
label='submit with an owner of 131072 bytes'
fresh_owner; pad_owner 131072
expect_rc 70 cam_request_submit gstapp_restart operator 'large owner'
[ ! -e "$pending_file" ] || fail "a pending request was written"
label='submit with an owner of 131071 bytes'
fresh_owner; pad_owner 131071
expect_rc 69 cam_request_submit gstapp_restart operator 'large owner'
[ ! -e "$pending_file" ] || fail "a pending request was written"
# An owner nested 253 deep makes the request one level too deep for jq 1.6 to
# parse back.  The old guard refused it (69); jq 1.6 must not answer the error
# by re-running a try it has already left, which wrote "70" into the memo as
# the request's owner.
label='submit with a deeply nested owner'
fresh_owner
jq -c --argjson p "$(printf '%*s' 253 '' | tr ' ' '[')$(printf '%*s' 253 '' | tr ' ' ']')" '.pad=$p' \
    "$PIM_CAMERA_RUN_DIR/owner.json" > "$WORK/owner.tmp"; mv "$WORK/owner.tmp" "$PIM_CAMERA_RUN_DIR/owner.json"
expect_rc 69 cam_request_submit gstapp_restart operator 'deep owner'
[ ! -e "$pending_file" ] || fail "a pending request was written"
memo_matches_jq

echo "request semantics: PASS"
