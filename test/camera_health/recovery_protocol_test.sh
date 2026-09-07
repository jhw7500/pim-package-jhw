#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-recovery-protocol.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

export PIM_CAMERA_RUN_DIR="$WORK/run/pim-camera"
export PIM_CAMERA_STATE_DIR="$WORK/var/lib/pim-camera"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot_id"
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_CAMERA_RUNTIME_JSON="$PIM_CAMERA_STATE_DIR/runtime.json"
export PIM_CAMERA_CALL_LOG="$WORK/call.log"
DAEMON_PID=4242
CONTROLLED_WAIT_SECONDS=30

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() { local expected=$1; shift; set +e; "$@"; local actual=$?; set -e; [ "$actual" -eq "$expected" ] || fail "expected rc=$expected, got $actual: $*"; }
uuid() { [[ $1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "not UUID: $1"; }
fake_stat() { mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"; { printf '%s' "$DAEMON_PID (cam operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' %s 0 0\n' "$1"; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"; }
owner_active() { rm -f "$PIM_CAMERA_RUN_DIR/owner.json"; cam_owner_create "$DAEMON_PID"; cam_owner_set_lifecycle ACTIVE; }
reset_protocol_sandbox() {
    rm -rf "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROC_ROOT"
    printf 'test-boot-id\n' > "$PIM_CAMERA_BOOT_ID_FILE"
    fake_stat 111
}
create_normal_terminal_fixture() {
    local wait_pid wait_rc
    reset_protocol_sandbox
    owner_active
    mkdir -p "$PIM_CAMERA_STATE_DIR"
    printf '{"dirty":false,"sentinel":"normal-terminal"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
    printf '{"sentinel":"runtime"}\n' > "$PIM_CAMERA_RUNTIME_JSON"
    printf 'sentinel:call\n' > "$PIM_CAMERA_CALL_LOG"
    normal_terminal_wait="$WORK/normal-terminal-wait.out"
    "$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request module_reload --source operator --reason "normal terminal" --wait "$CONTROLLED_WAIT_SECONDS" >"$normal_terminal_wait" &
    wait_pid=$!
    for _ in $(seq 1 30); do [ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && break; sleep 0.1; done
    [ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "normal terminal request was not accepted"
    normal_terminal_id=$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/pending.json")
    cam_request_claim
    cam_request_transition QUIESCING
    cam_request_transition RUNNING
    cam_action_counter_begin module_reload "$normal_terminal_id"
    cam_request_transition VERIFYING
    cam_action_counter_finish module_reload "$normal_terminal_id" SUCCEEDED 0
    mkdir -p "$WORK/normal-terminal-fixture"
    cp "$PIM_CAMERA_RUN_DIR/recovery/active.json" "$WORK/normal-terminal-fixture/active.json"
    cam_request_finish SUCCEEDED 0
    set +e; wait "$wait_pid"; wait_rc=$?; set -e
    [ "$wait_rc" -eq 0 ] || fail "normal terminal waiter rc=$wait_rc"
    [ "$(cat "$normal_terminal_wait")" = "CAM_RECOVERY_RESULT id=$normal_terminal_id type=module_reload status=SUCCEEDED rc=0" ] || fail "normal terminal waiter lost original sentinel"
    cp "$PIM_CAMERA_RUN_DIR/owner.json" "$WORK/normal-terminal-fixture/owner.json"
    cp "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" "$WORK/normal-terminal-fixture/result.json"
    cp "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json" "$WORK/normal-terminal-fixture/history.json"
    cp "$PIM_CAMERA_STATE_DIR/recovery/state.json" "$WORK/normal-terminal-fixture/state.json"
    cp "$PIM_CAMERA_STATE_DIR/service-state.json" "$WORK/normal-terminal-fixture/service-state.json"
    cp "$PIM_CAMERA_RUNTIME_JSON" "$WORK/normal-terminal-fixture/runtime.json"
    cp "$PIM_CAMERA_CALL_LOG" "$WORK/normal-terminal-fixture/call.log"
}
restore_normal_terminal_fixture() {
    reset_protocol_sandbox
    mkdir -p "$PIM_CAMERA_RUN_DIR/recovery/results" "$PIM_CAMERA_STATE_DIR/recovery/history"
    cp "$WORK/normal-terminal-fixture/owner.json" "$PIM_CAMERA_RUN_DIR/owner.json"
    cp "$WORK/normal-terminal-fixture/active.json" "$PIM_CAMERA_RUN_DIR/recovery/active.json"
    cp "$WORK/normal-terminal-fixture/result.json" "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json"
    cp "$WORK/normal-terminal-fixture/history.json" "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json"
    cp "$WORK/normal-terminal-fixture/state.json" "$PIM_CAMERA_STATE_DIR/recovery/state.json"
    cp "$WORK/normal-terminal-fixture/service-state.json" "$PIM_CAMERA_STATE_DIR/service-state.json"
    cp "$WORK/normal-terminal-fixture/runtime.json" "$PIM_CAMERA_RUNTIME_JSON"
    cp "$WORK/normal-terminal-fixture/call.log" "$PIM_CAMERA_CALL_LOG"
    fake_stat 222
}
snapshot_terminal_bytes() {
    terminal_owner_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")
    terminal_active_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")
    terminal_history_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")
    terminal_result_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")
    terminal_counter_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
    terminal_service_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")
    terminal_runtime_before=$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")
    terminal_call_before=$(file_fingerprint "$PIM_CAMERA_CALL_LOG")
}
file_fingerprint() { if [ -e "$1" ]; then cksum "$1"; else printf 'ABSENT %s\n' "$1"; fi; }
assert_terminal_bytes_unchanged() {
    local label=$1
    [ "$terminal_owner_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "$label mutated owner"
    [ "$terminal_active_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")" ] || fail "$label mutated active lease"
    [ "$terminal_history_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")" ] || fail "$label mutated history"
    [ "$terminal_result_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")" ] || fail "$label mutated result"
    [ "$terminal_counter_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "$label mutated counters"
    [ "$terminal_service_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "$label mutated service state"
    [ "$terminal_runtime_before" = "$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")" ] || fail "$label mutated runtime"
    [ "$terminal_call_before" = "$(file_fingerprint "$PIM_CAMERA_CALL_LOG")" ] || fail "$label mutated call log"
}
create_finish_arithmetic_fixture() {
    local variant=$1 active terminal result history
    reset_protocol_sandbox
    owner_active
    mkdir -p "$PIM_CAMERA_STATE_DIR"
    printf '{"dirty":false,"sentinel":"finish-arithmetic"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
    printf '{"sentinel":"runtime"}\n' > "$PIM_CAMERA_RUNTIME_JSON"
    printf 'sentinel:call\n' > "$PIM_CAMERA_CALL_LOG"
    normal_terminal_id=$(cam_request_submit gstapp_restart test "finish arithmetic")
    cam_request_claim
    cam_request_transition QUIESCING
    cam_request_transition RUNNING
    cam_action_counter_begin gstapp_restart "$normal_terminal_id"
    cam_action_counter_finish gstapp_restart "$normal_terminal_id" FAILED 23
    jq -e --arg id "$normal_terminal_id" '
      .actions.gstapp_restart == {
        attempted:1,succeeded:0,failed:1,consecutive_failures:1,
        last_request_id:$id,last_started_at:.actions.gstapp_restart.last_started_at,
        last_finished_at:.actions.gstapp_restart.last_finished_at,
        last_status:"FAILED",last_rc:23
      }
    ' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "invalid exact arithmetic fixture"
    active=$(cat "$PIM_CAMERA_RUN_DIR/recovery/active.json")
    finish_arithmetic_finished=$(_cr_now)
    terminal=$(jq -c --argjson finished "$finish_arithmetic_finished" '.status="FAILED" | .rc=23 | .finished_at=$finished' <<<"$active")
    result=$(jq -c '{id,type,status,rc,source,reason,created_at,finished_at}' <<<"$terminal")
    case "$variant" in
        normal) ;;
        result_first)
            mkdir -p "$PIM_CAMERA_RUN_DIR/recovery/results"
            printf '%s\n' "$result" > "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json"
            ;;
        history_first)
            history=$(cat "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")
            jq -c --argjson terminal "$terminal" '.request=$terminal' <<<"$history" > "$WORK/finish-arithmetic.history"
            mv "$WORK/finish-arithmetic.history" "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json"
            ;;
        *) fail "unknown finish arithmetic variant: $variant" ;;
    esac
}

printf 'test-boot-id\n' > "$PIM_CAMERA_BOOT_ID_FILE"
fake_stat 111
# This source is intentionally the RED boundary: Task 2 has not created it yet.
source "$PIM_LIB/cam_recovery.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_operate_control.sh"

echo "=== request finish rejects impossible public-counter arithmetic ==="
finish_arithmetic_failures=0
for finish_variant in normal result_first history_first; do
    create_finish_arithmetic_fixture "$finish_variant"
    jq '.actions.gstapp_restart.attempted=2' "$PIM_CAMERA_STATE_DIR/recovery/state.json" > "$WORK/finish-arithmetic.state" && mv "$WORK/finish-arithmetic.state" "$PIM_CAMERA_STATE_DIR/recovery/state.json"
    snapshot_terminal_bytes
    set +e
    cam_request_finish FAILED 23
    finish_arithmetic_rc=$?
    set -e
    if [ "$finish_arithmetic_rc" -ne 70 ]; then
        printf 'ROUND2_RED: %s finish expected rc=70 got=%s\n' "$finish_variant" "$finish_arithmetic_rc" >&2
        finish_arithmetic_failures=$((finish_arithmetic_failures + 1))
    else
        assert_terminal_bytes_unchanged "$finish_variant impossible arithmetic"
    fi
done
[ "$finish_arithmetic_failures" -eq 0 ] || fail "$finish_arithmetic_failures finish arithmetic variants accepted impossible attempted count"

for finish_variant in normal result_first history_first; do
    create_finish_arithmetic_fixture "$finish_variant"
    finish_counter_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
    finish_owner_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")
    finish_service_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")
    finish_runtime_before=$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")
    finish_call_before=$(file_fingerprint "$PIM_CAMERA_CALL_LOG")
    finish_result_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")
    finish_history_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")
    expect_rc 0 cam_request_finish FAILED 23
    [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "$finish_variant exact arithmetic retained active lease"
    finish_converged=$(jq -r .finished_at "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")
    [[ $finish_converged =~ ^[0-9]+$ ]] && [ "$finish_converged" -ge "$finish_arithmetic_finished" ] || fail "$finish_variant exact arithmetic used an invalid terminal timestamp"
    jq -e --argjson finished "$finish_converged" '.request.status=="FAILED" and .request.rc==23 and .request.finished_at==$finished' "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json" >/dev/null || fail "$finish_variant exact arithmetic did not converge history"
    jq -e --argjson finished "$finish_converged" '.status=="FAILED" and .rc==23 and .finished_at==$finished' "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" >/dev/null || fail "$finish_variant exact arithmetic did not converge result"
    finish_terminal=$(jq -c .request "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")
    finish_result=$(cat "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")
    _cr_terminal_request_result_equal "$finish_terminal" "$finish_result" || fail "$finish_variant exact arithmetic lost terminal/result identity"
    [ "$finish_counter_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "$finish_variant exact arithmetic rewrote counters"
    [ "$finish_owner_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "$finish_variant exact arithmetic rewrote owner"
    [ "$finish_service_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "$finish_variant exact arithmetic rewrote service state"
    [ "$finish_runtime_before" = "$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")" ] || fail "$finish_variant exact arithmetic rewrote runtime"
    [ "$finish_call_before" = "$(file_fingerprint "$PIM_CAMERA_CALL_LOG")" ] || fail "$finish_variant exact arithmetic rewrote call log"
    case "$finish_variant" in
        result_first) [ "$finish_result_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")" ] || fail "result-first exact arithmetic rewrote result" ;;
        history_first) [ "$finish_history_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")" ] || fail "history-first exact arithmetic rewrote history" ;;
    esac
    if [ "$finish_variant" != normal ]; then
        [ "$finish_converged" -eq "$finish_arithmetic_finished" ] || fail "$finish_variant exact arithmetic changed terminal timestamp"
    fi
done

echo "=== STARTING recovery transition is private ==="
reset_protocol_sandbox
cam_owner_create "$DAEMON_PID"
starting_owner_before=$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")
expect_rc 64 cam_owner_set_lifecycle RECOVERING
[ "$starting_owner_before" = "$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "public STARTING recovery mutated owner"
jq -e '.lifecycle=="STARTING"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "public STARTING recovery changed lifecycle"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "public STARTING recovery created pending"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "public STARTING recovery created active"
[ ! -d "$PIM_CAMERA_STATE_DIR/recovery/history" ] || fail "public STARTING recovery created history"
[ ! -d "$PIM_CAMERA_RUN_DIR/recovery/results" ] || fail "public STARTING recovery created result"

echo "=== stale owner repairs exact history-first counter begin partial ==="
reset_protocol_sandbox
owner_active
mkdir -p "$PIM_CAMERA_STATE_DIR"
printf '{"dirty":false,"sentinel":"owner-stale-begin-partial"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
history_first_prior_id=$(cam_request_submit module_reload health "history-first predecessor" /source/stale 108)
cam_request_claim
cam_request_transition QUIESCING
cam_request_transition RUNNING
cam_action_counter_begin module_reload "$history_first_prior_id"
fake_stat 222
cam_owner_create "$DAEMON_PID"
history_first_prior_history="$PIM_CAMERA_STATE_DIR/recovery/history/$history_first_prior_id.json"
history_first_prior_result="$PIM_CAMERA_RUN_DIR/recovery/results/$history_first_prior_id.json"
history_first_prior_history_before=$(file_fingerprint "$history_first_prior_history")
history_first_prior_result_before=$(file_fingerprint "$history_first_prior_result")
cam_owner_set_lifecycle ACTIVE
history_first_current_id=$(cam_request_submit module_reload health "history-first current" /source/retry 109)
cam_request_claim
cam_request_transition QUIESCING
cam_request_transition RUNNING
PIM_CAMERA_TEST_FAILPOINT=counter_begin_after_history expect_rc 70 cam_action_counter_begin module_reload "$history_first_current_id"
fake_stat 333
expect_rc 0 cam_owner_create "$DAEMON_PID"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "history-first takeover retained active lease"
jq -e '.proc_start_time=="333" and .lifecycle=="STARTING"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "history-first takeover did not publish replacement owner"
jq -e --arg id "$history_first_current_id" '.request.id==$id and .request.status=="FAILED" and .request.rc==70 and .request.interrupted==true and .request.interrupted_reason=="owner_stale" and ([.actions[] | select(.action=="module_reload" and .request_id==$id and .status=="RUNNING")] | length)==1' "$PIM_CAMERA_STATE_DIR/recovery/history/$history_first_current_id.json" >/dev/null || fail "history-first takeover did not terminalize current history"
jq -e --arg id "$history_first_current_id" '.id==$id and .status=="FAILED" and .rc==70 and (has("interrupted")|not) and (has("interrupted_reason")|not)' "$PIM_CAMERA_RUN_DIR/recovery/results/$history_first_current_id.json" >/dev/null || fail "history-first takeover did not write strict current result"
jq -e --arg id "$history_first_current_id" '.actions.module_reload.attempted==2 and .actions.module_reload.succeeded==0 and .actions.module_reload.failed==1 and .actions.module_reload.consecutive_failures==1 and .actions.module_reload.last_request_id==$id and .actions.module_reload.last_status=="RUNNING" and .actions.module_reload.last_rc==null' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "history-first takeover repaired state incorrectly"
[ "$history_first_prior_history_before" = "$(file_fingerprint "$history_first_prior_history")" ] || fail "history-first takeover rewrote predecessor history"
[ "$history_first_prior_result_before" = "$(file_fingerprint "$history_first_prior_result")" ] || fail "history-first takeover rewrote predecessor result"
history_first_current_history="$PIM_CAMERA_STATE_DIR/recovery/history/$history_first_current_id.json"
history_first_current_before=$(file_fingerprint "$history_first_current_history")
cam_owner_set_lifecycle ACTIVE
history_first_third_id=$(cam_request_submit module_reload health "history-first third" /source/retry 110)
cam_request_claim
cam_request_transition QUIESCING
cam_request_transition RUNNING
cam_action_counter_begin module_reload "$history_first_third_id"
cam_action_counter_finish module_reload "$history_first_third_id" SUCCEEDED 0
cam_request_transition VERIFYING
cam_request_finish SUCCEEDED 0
jq -e --arg id "$history_first_third_id" '.id==$id and .status=="SUCCEEDED" and .rc==0' "$PIM_CAMERA_RUN_DIR/recovery/results/$history_first_third_id.json" >/dev/null || fail "history-first third request did not succeed"
jq -e '.actions.module_reload.attempted==3 and .actions.module_reload.succeeded==1 and .actions.module_reload.failed==2 and .actions.module_reload.consecutive_failures==0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "history-first third attempt did not settle exactly once"
[ "$history_first_current_before" = "$(file_fingerprint "$history_first_current_history")" ] || fail "history-first third attempt rewrote interrupted history"

echo "=== normal terminal active removal is idempotent ==="
create_normal_terminal_fixture

restore_normal_terminal_fixture
terminal_success_history=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")
terminal_success_result=$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")
terminal_success_counter=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")
terminal_success_service=$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")
expect_rc 0 cam_owner_create "$DAEMON_PID"
[ "$terminal_success_history" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")" ] || fail "consistent success rewrote terminal history"
[ "$terminal_success_result" = "$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")" ] || fail "consistent success rewrote terminal result"
[ "$terminal_success_counter" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "consistent success mutated counters"
[ "$terminal_success_service" = "$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "consistent success mutated service state"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "consistent success retained active lease"
jq -e '.proc_start_time=="222" and .lifecycle=="STARTING"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "consistent success did not publish replacement owner"

restore_normal_terminal_fixture
terminal_finished=$(jq -r .finished_at "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")
jq --argjson finished "$terminal_finished" '.status="FAILED" | .rc=17 | .finished_at=$finished' "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" > "$WORK/result.failed" && mv "$WORK/result.failed" "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json"
jq --argjson finished "$terminal_finished" '.request.status="FAILED" | .request.rc=17 | .request.finished_at=$finished' "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json" > "$WORK/history.failed" && mv "$WORK/history.failed" "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json"
terminal_failed_history=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")
terminal_failed_result=$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")
terminal_failed_service=$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")
expect_rc 0 cam_owner_create "$DAEMON_PID"
[ "$terminal_failed_history" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")" ] || fail "consistent failure rewrote terminal history"
[ "$terminal_failed_result" = "$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")" ] || fail "consistent failure rewrote terminal result"
[ "$terminal_failed_service" = "$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "consistent failure mutated service state"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "consistent failure retained active lease"

echo "=== normal terminal partial files converge exactly ==="
restore_normal_terminal_fixture
active_request=$(cat "$PIM_CAMERA_RUN_DIR/recovery/active.json")
jq -c --argjson request "$active_request" '.request=$request' "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json" > "$WORK/history.nonterminal" && mv "$WORK/history.nonterminal" "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json"
partial_actions=$(jq -c .actions "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")
partial_result=$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")
partial_counter=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")
partial_service=$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")
expect_rc 0 cam_owner_create "$DAEMON_PID"
jq -e --argjson finished "$terminal_finished" '.request.status=="SUCCEEDED" and .request.rc==0 and .request.finished_at==$finished' "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json" >/dev/null || fail "result-only partial did not complete history exactly"
[ "$partial_actions" = "$(jq -c .actions "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")" ] || fail "result-only partial changed actions"
[ "$partial_result" = "$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")" ] || fail "result-only partial rewrote result"
[ "$partial_counter" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "result-only partial changed counters"
[ "$partial_service" = "$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "result-only partial changed service state"

restore_normal_terminal_fixture
expected_result=$(cat "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")
rm -f "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json"
partial_history=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")
partial_counter=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")
partial_service=$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")
expect_rc 0 cam_owner_create "$DAEMON_PID"
[ "$expected_result" = "$(cat "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")" ] || fail "history-only partial did not recreate exact result"
[ "$partial_history" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")" ] || fail "history-only partial rewrote history"
[ "$partial_counter" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "history-only partial changed counters"
[ "$partial_service" = "$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "history-only partial changed service state"

echo "=== conflicting terminal files fail closed byte-for-byte ==="
for conflict in identity status_rc finished_at malformed; do
    restore_normal_terminal_fixture
    case "$conflict" in
        identity) jq '.reason="conflicting reason"' "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" > "$WORK/result.conflict" && mv "$WORK/result.conflict" "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" ;;
        status_rc) jq '.status="FAILED" | .rc=19' "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" > "$WORK/result.conflict" && mv "$WORK/result.conflict" "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" ;;
        finished_at) jq '.finished_at+=1' "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" > "$WORK/result.conflict" && mv "$WORK/result.conflict" "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" ;;
        malformed) jq '.finished_at=0' "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" > "$WORK/result.conflict" && mv "$WORK/result.conflict" "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" ;;
    esac
    snapshot_terminal_bytes
    expect_rc 70 cam_owner_create "$DAEMON_PID"
    assert_terminal_bytes_unchanged "$conflict conflict"
done

echo "=== contradictory interruption metadata fails closed byte-for-byte ==="
interruption_failures=''
for mutation in \
    result_success_pair result_flag_only result_reason_only result_false \
    result_reason_nonstring active_pair history_success_pair \
    result_failed_pair nonterminal_lease_history_pair \
    active_synthetic_pair terminal_lease_synthetic_history; do
    restore_normal_terminal_fixture
    result_file="$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json"
    active_file="$PIM_CAMERA_RUN_DIR/recovery/active.json"
    history_file="$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json"
    case "$mutation" in
        result_success_pair)
            jq '.interrupted=true | .interrupted_reason="owner_stale"' "$result_file" > "$WORK/interruption.json" && mv "$WORK/interruption.json" "$result_file"
            ;;
        result_flag_only)
            jq '.interrupted=true' "$result_file" > "$WORK/interruption.json" && mv "$WORK/interruption.json" "$result_file"
            ;;
        result_reason_only)
            jq '.interrupted_reason="owner_stale"' "$result_file" > "$WORK/interruption.json" && mv "$WORK/interruption.json" "$result_file"
            ;;
        result_false)
            jq '.interrupted=false | .interrupted_reason="owner_stale"' "$result_file" > "$WORK/interruption.json" && mv "$WORK/interruption.json" "$result_file"
            ;;
        result_reason_nonstring)
            jq '.interrupted=true | .interrupted_reason=7' "$result_file" > "$WORK/interruption.json" && mv "$WORK/interruption.json" "$result_file"
            ;;
        active_pair)
            jq '.interrupted=true | .interrupted_reason="owner_stale"' "$active_file" > "$WORK/interruption.json" && mv "$WORK/interruption.json" "$active_file"
            ;;
        history_success_pair)
            jq '.request.interrupted=true | .request.interrupted_reason="owner_stale"' "$history_file" > "$WORK/interruption.json" && mv "$WORK/interruption.json" "$history_file"
            ;;
        result_failed_pair)
            finished=$(jq -r .finished_at "$result_file")
            jq --argjson finished "$finished" '.status="FAILED" | .rc=17 | .finished_at=$finished | .interrupted=true | .interrupted_reason="owner_stale"' "$result_file" > "$WORK/interruption.result" && mv "$WORK/interruption.result" "$result_file"
            jq --argjson finished "$finished" '.request.status="FAILED" | .request.rc=17 | .request.finished_at=$finished' "$history_file" > "$WORK/interruption.history" && mv "$WORK/interruption.history" "$history_file"
            ;;
        nonterminal_lease_history_pair)
            rm -f "$result_file"
            jq '.interrupted=true | .interrupted_reason="owner_stale"' "$active_file" > "$WORK/interruption.active" && mv "$WORK/interruption.active" "$active_file"
            active_request=$(cat "$active_file")
            jq --argjson request "$active_request" '.request=$request' "$history_file" > "$WORK/interruption.history" && mv "$WORK/interruption.history" "$history_file"
            ;;
        active_synthetic_pair)
            finished=$(jq -r .finished_at "$result_file")
            jq --argjson finished "$finished" '.status="FAILED" | .rc=70 | .finished_at=$finished | .interrupted=true | .interrupted_reason="owner_stale"' "$active_file" > "$WORK/interruption.active" && mv "$WORK/interruption.active" "$active_file"
            active_request=$(cat "$active_file")
            jq --argjson request "$active_request" '.request=$request' "$history_file" > "$WORK/interruption.history" && mv "$WORK/interruption.history" "$history_file"
            jq --argjson finished "$finished" '.status="FAILED" | .rc=70 | .finished_at=$finished' "$result_file" > "$WORK/interruption.result" && mv "$WORK/interruption.result" "$result_file"
            ;;
        terminal_lease_synthetic_history)
            finished=$(jq -r .finished_at "$result_file")
            jq --argjson finished "$finished" '.status="FAILED" | .rc=70 | .finished_at=$finished' "$active_file" > "$WORK/interruption.active" && mv "$WORK/interruption.active" "$active_file"
            active_request=$(cat "$active_file")
            jq --argjson request "$active_request" '.request=($request + {interrupted:true,interrupted_reason:"owner_stale"})' "$history_file" > "$WORK/interruption.history" && mv "$WORK/interruption.history" "$history_file"
            jq --argjson finished "$finished" '.status="FAILED" | .rc=70 | .finished_at=$finished' "$result_file" > "$WORK/interruption.result" && mv "$WORK/interruption.result" "$result_file"
            ;;
    esac
    snapshot_terminal_bytes
    set +e
    cam_owner_create "$DAEMON_PID"
    interruption_rc=$?
    set -e
    if [ "$interruption_rc" -eq 70 ]; then
        assert_terminal_bytes_unchanged "$mutation"
    else
        interruption_failures="$interruption_failures $mutation:$interruption_rc"
    fi
done

snapshot_pending_provenance_bytes() {
    pending_owner_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")
    pending_lease_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/pending.json")
    pending_history_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/history/$pending_provenance_id.json")
    pending_result_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/results/$pending_provenance_id.json")
    pending_counter_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
    pending_service_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")
    pending_runtime_before=$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")
    pending_call_before=$(file_fingerprint "$PIM_CAMERA_CALL_LOG")
}
assert_pending_provenance_bytes_unchanged() {
    local label=$1
    [ "$pending_owner_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "$label mutated owner"
    [ "$pending_lease_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/pending.json")" ] || fail "$label mutated pending lease"
    [ "$pending_history_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/history/$pending_provenance_id.json")" ] || fail "$label mutated history"
    [ "$pending_result_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/results/$pending_provenance_id.json")" ] || fail "$label mutated result"
    [ "$pending_counter_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "$label mutated counters"
    [ "$pending_service_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "$label mutated service state"
    [ "$pending_runtime_before" = "$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")" ] || fail "$label mutated runtime"
    [ "$pending_call_before" = "$(file_fingerprint "$PIM_CAMERA_CALL_LOG")" ] || fail "$label mutated call log"
}

for mutation in pending_pair pending_flag_only pending_reason_only; do
    reset_protocol_sandbox
    owner_active
    mkdir -p "$PIM_CAMERA_STATE_DIR/recovery"
    printf '{"dirty":false,"sentinel":"pending-provenance"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
    _cr_state_template > "$PIM_CAMERA_STATE_DIR/recovery/state.json"
    printf '{"sentinel":"runtime"}\n' > "$PIM_CAMERA_RUNTIME_JSON"
    printf 'sentinel:call\n' > "$PIM_CAMERA_CALL_LOG"
    pending_provenance_id=$(cam_request_submit apply_config operator "$mutation" /source/pending 55)
    case "$mutation" in
        pending_pair) jq '.interrupted=true | .interrupted_reason="owner_stale"' "$PIM_CAMERA_RUN_DIR/recovery/pending.json" > "$WORK/pending-mutation" ;;
        pending_flag_only) jq '.interrupted=true' "$PIM_CAMERA_RUN_DIR/recovery/pending.json" > "$WORK/pending-mutation" ;;
        pending_reason_only) jq '.interrupted_reason="owner_stale"' "$PIM_CAMERA_RUN_DIR/recovery/pending.json" > "$WORK/pending-mutation" ;;
    esac
    mv "$WORK/pending-mutation" "$PIM_CAMERA_RUN_DIR/recovery/pending.json"
    fake_stat 222
    snapshot_pending_provenance_bytes
    set +e
    cam_owner_create "$DAEMON_PID"
    pending_provenance_rc=$?
    set -e
    if [ "$pending_provenance_rc" -eq 70 ]; then
        assert_pending_provenance_bytes_unchanged "$mutation"
    else
        interruption_failures="$interruption_failures $mutation:$pending_provenance_rc"
    fi
done

counter_finish_setup() {
    reset_protocol_sandbox
    owner_active
    mkdir -p "$PIM_CAMERA_STATE_DIR"
    printf '{"dirty":false,"sentinel":"counter-preflight"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
    printf '{"sentinel":"runtime"}\n' > "$PIM_CAMERA_RUNTIME_JSON"
    printf 'sentinel:call\n' > "$PIM_CAMERA_CALL_LOG"
    counter_finish_id=$(cam_request_submit module_reload health "$1")
    cam_request_claim
    cam_request_transition QUIESCING
    cam_request_transition RUNNING
    cam_action_counter_begin module_reload "$counter_finish_id"
    counter_finish_history="$PIM_CAMERA_STATE_DIR/recovery/history/$counter_finish_id.json"
    counter_finish_state="$PIM_CAMERA_STATE_DIR/recovery/state.json"
    counter_finish_started=$(jq -r '.actions[0].started_at' "$counter_finish_history")
    counter_finish_finished=$((counter_finish_started + 10))
}
counter_finish_snapshot() {
    counter_owner_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")
    counter_active_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")
    counter_history_before=$(file_fingerprint "$counter_finish_history")
    counter_state_before=$(file_fingerprint "$counter_finish_state")
    counter_result_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/results/$counter_finish_id.json")
    counter_service_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")
    counter_runtime_before=$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")
    counter_call_before=$(file_fingerprint "$PIM_CAMERA_CALL_LOG")
}
assert_counter_finish_bytes_unchanged() {
    local label=$1
    [ "$counter_owner_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "$label mutated owner"
    [ "$counter_active_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")" ] || fail "$label mutated active lease"
    [ "$counter_history_before" = "$(file_fingerprint "$counter_finish_history")" ] || fail "$label mutated history"
    [ "$counter_state_before" = "$(file_fingerprint "$counter_finish_state")" ] || fail "$label mutated counters"
    [ "$counter_result_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/results/$counter_finish_id.json")" ] || fail "$label mutated result"
    [ "$counter_service_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "$label mutated service state"
    [ "$counter_runtime_before" = "$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")" ] || fail "$label mutated runtime"
    [ "$counter_call_before" = "$(file_fingerprint "$PIM_CAMERA_CALL_LOG")" ] || fail "$label mutated call log"
}
counter_finish_state_terminal() {
    local status=$1 rc=$2 finished=$3
    jq --arg action module_reload --arg id "$counter_finish_id" --arg status "$status" --argjson rc "$rc" --argjson finished "$finished" '
      .actions[$action].last_request_id=$id |
      .actions[$action].last_finished_at=$finished |
      .actions[$action].last_status=$status |
      .actions[$action].last_rc=$rc |
      if $status=="SUCCEEDED" then
        .actions[$action].succeeded+=1 | .actions[$action].consecutive_failures=0
      else
        .actions[$action].failed+=1 | .actions[$action].consecutive_failures+=1
      end
    ' "$counter_finish_state" > "$WORK/counter-state-terminal" && mv "$WORK/counter-state-terminal" "$counter_finish_state"
}
counter_finish_history_terminal() {
    local status=$1 rc=$2 finished=$3
    jq --arg action module_reload --arg id "$counter_finish_id" --arg status "$status" --argjson rc "$rc" --argjson finished "$finished" '
      .actions |= map(if .action==$action and .request_id==$id then
        .status=$status | .rc=$rc | .finished_at=$finished
      else . end)
    ' "$counter_finish_history" > "$WORK/counter-history-terminal" && mv "$WORK/counter-history-terminal" "$counter_finish_history"
}

echo "=== counter finish validates complete attribution before writes ==="
counter_finish_failures=''
for mutation in \
    running_started_mismatch running_history_extra running_succeeded_preincrement \
    running_failed_preincrement running_both_preincrement running_attempted_extra \
    running_consecutive_exceeds_failed running_clock_before_start \
    state_terminal_started state_terminal_request state_terminal_status \
    state_terminal_rc state_terminal_finished state_terminal_attempted_extra \
    state_terminal_success_consecutive \
    history_terminal_started history_terminal_request history_terminal_status \
    history_terminal_action history_terminal_rc history_terminal_finished history_terminal_extra \
    history_terminal_state_succeeded history_terminal_state_failed \
    history_terminal_state_both history_terminal_state_attempted_extra \
    history_terminal_state_consecutive; do
    counter_finish_setup "$mutation"
    case "$mutation" in
        running_started_mismatch)
            jq '.actions.module_reload.last_started_at+=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        running_history_extra)
            jq '.actions[0].unexpected=true' "$counter_finish_history" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_history"
            ;;
        running_succeeded_preincrement)
            jq '.actions.module_reload.succeeded+=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        running_failed_preincrement)
            jq '.actions.module_reload.failed+=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        running_both_preincrement)
            jq '.actions.module_reload.succeeded+=1 | .actions.module_reload.failed+=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        running_attempted_extra)
            jq '.actions.module_reload.attempted+=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        running_consecutive_exceeds_failed)
            jq '.actions.module_reload.consecutive_failures=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        running_clock_before_start)
            _cr_now() { printf '%s\n' "$((counter_finish_started - 1))"; }
            ;;
        state_terminal_started)
            counter_finish_state_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions.module_reload.last_started_at+=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        state_terminal_request)
            counter_finish_state_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions.module_reload.last_request_id="00000000-0000-4000-8000-000000000003"' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        state_terminal_status)
            counter_finish_state_terminal FAILED 17 "$counter_finish_finished"
            ;;
        state_terminal_rc)
            counter_finish_state_terminal SUCCEEDED 9 "$counter_finish_finished"
            ;;
        state_terminal_finished)
            counter_finish_state_terminal SUCCEEDED 0 "$((counter_finish_started - 1))"
            ;;
        state_terminal_attempted_extra)
            counter_finish_state_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions.module_reload.attempted+=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        state_terminal_success_consecutive)
            counter_finish_state_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions.module_reload.consecutive_failures=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        history_terminal_started)
            counter_finish_history_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions[0].started_at+=1' "$counter_finish_history" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_history"
            ;;
        history_terminal_request)
            counter_finish_history_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions[0].request_id="00000000-0000-4000-8000-000000000004"' "$counter_finish_history" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_history"
            ;;
        history_terminal_status)
            counter_finish_history_terminal FAILED 17 "$counter_finish_finished"
            ;;
        history_terminal_action)
            counter_finish_history_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions[0].action="gstapp_restart"' "$counter_finish_history" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_history"
            ;;
        history_terminal_rc)
            counter_finish_history_terminal SUCCEEDED 9 "$counter_finish_finished"
            ;;
        history_terminal_finished)
            counter_finish_history_terminal SUCCEEDED 0 "$((counter_finish_started - 1))"
            ;;
        history_terminal_extra)
            counter_finish_history_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions[0].unexpected=true' "$counter_finish_history" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_history"
            ;;
        history_terminal_state_succeeded)
            counter_finish_history_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions.module_reload.succeeded+=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        history_terminal_state_failed)
            counter_finish_history_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions.module_reload.failed+=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        history_terminal_state_both)
            counter_finish_history_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions.module_reload.succeeded+=1 | .actions.module_reload.failed+=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        history_terminal_state_attempted_extra)
            counter_finish_history_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions.module_reload.attempted+=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
        history_terminal_state_consecutive)
            counter_finish_history_terminal SUCCEEDED 0 "$counter_finish_finished"
            jq '.actions.module_reload.consecutive_failures=1' "$counter_finish_state" > "$WORK/counter-mutation" && mv "$WORK/counter-mutation" "$counter_finish_state"
            ;;
    esac
    counter_finish_snapshot
    set +e
    cam_action_counter_finish module_reload "$counter_finish_id" SUCCEEDED 0
    counter_finish_rc=$?
    set -e
    [ "$mutation" != running_clock_before_start ] || _cr_now() { date +%s; }
    if [ "$counter_finish_rc" -eq 70 ]; then
        assert_counter_finish_bytes_unchanged "$mutation"
    else
        counter_finish_failures="$counter_finish_failures $mutation:$counter_finish_rc"
    fi
done
[ -z "$interruption_failures$counter_finish_failures" ] ||
    fail "round-5 mutations accepted: interruption:$interruption_failures counter:$counter_finish_failures"

seed_nonzero_running_counter() {
    jq '.actions.module_reload.attempted=6 | .actions.module_reload.succeeded=3 | .actions.module_reload.failed=2 | .actions.module_reload.consecutive_failures=2' "$counter_finish_state" > "$WORK/nonzero-state" && mv "$WORK/nonzero-state" "$counter_finish_state"
}

echo "=== nonzero cumulative counter finishes remain exact ==="
counter_finish_setup "nonzero normal"
seed_nonzero_running_counter
cam_action_counter_finish module_reload "$counter_finish_id" SUCCEEDED 0
jq -e '.actions.module_reload.attempted==6 and .actions.module_reload.succeeded==4 and .actions.module_reload.failed==2 and .actions.module_reload.consecutive_failures==0' "$counter_finish_state" >/dev/null || fail "nonzero normal totals"
jq -e --argjson finished "$(jq -r '.actions.module_reload.last_finished_at' "$counter_finish_state")" '.actions[0].status=="SUCCEEDED" and .actions[0].rc==0 and .actions[0].finished_at==$finished' "$counter_finish_history" >/dev/null || fail "nonzero normal history/state finish mismatch"

counter_finish_setup "nonzero history terminal reciprocal"
seed_nonzero_running_counter
PIM_CAMERA_TEST_FAILPOINT=counter_finish_after_history expect_rc 70 cam_action_counter_finish module_reload "$counter_finish_id" SUCCEEDED 0
nonzero_history_finished=$(jq -r '.actions[0].finished_at' "$counter_finish_history")
cam_action_counter_finish module_reload "$counter_finish_id" SUCCEEDED 0
jq -e --argjson finished "$nonzero_history_finished" '.actions.module_reload.attempted==6 and .actions.module_reload.succeeded==4 and .actions.module_reload.failed==2 and .actions.module_reload.consecutive_failures==0 and .actions.module_reload.last_finished_at==$finished' "$counter_finish_state" >/dev/null || fail "nonzero history-terminal reciprocal totals"

counter_finish_setup "nonzero state terminal reciprocal"
seed_nonzero_running_counter
cp "$counter_finish_history" "$WORK/nonzero-running-history"
cam_action_counter_finish module_reload "$counter_finish_id" FAILED 17
nonzero_state_finished=$(jq -r '.actions.module_reload.last_finished_at' "$counter_finish_state")
nonzero_state_terminal=$(file_fingerprint "$counter_finish_state")
cp "$WORK/nonzero-running-history" "$counter_finish_history"
cam_action_counter_finish module_reload "$counter_finish_id" FAILED 17
[ "$nonzero_state_terminal" = "$(file_fingerprint "$counter_finish_state")" ] || fail "nonzero state-terminal reciprocal rewrote state"
jq -e --argjson finished "$nonzero_state_finished" '.actions[0].status=="FAILED" and .actions[0].rc==17 and .actions[0].finished_at==$finished' "$counter_finish_history" >/dev/null || fail "nonzero state-terminal reciprocal history"
jq -e '.actions.module_reload.attempted==6 and .actions.module_reload.succeeded==3 and .actions.module_reload.failed==3 and .actions.module_reload.consecutive_failures==3' "$counter_finish_state" >/dev/null || fail "nonzero state-terminal reciprocal totals"

echo "=== normal terminal action attribution fails closed ==="
mutation_failures=''
for mutation in \
    history_running counter_running counter_wrong_rc counter_wrong_request \
    counter_wrong_started counter_wrong_finished unknown_action duplicate_public \
    action_wrong_request action_invalid_status action_invalid_rc action_started_zero \
    action_finished_before public_countered_false missing_state corrupt_state \
    malformed_service success_interrupted failed_interrupted; do
    restore_normal_terminal_fixture
    history_file="$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json"
    state_file="$PIM_CAMERA_STATE_DIR/recovery/state.json"
    case "$mutation" in
        history_running) jq '.actions[0].status="RUNNING"' "$history_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$history_file" ;;
        counter_running) jq '.actions.module_reload.last_status="RUNNING"' "$state_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$state_file" ;;
        counter_wrong_rc) jq '.actions.module_reload.last_rc=9' "$state_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$state_file" ;;
        counter_wrong_request) jq '.actions.module_reload.last_request_id="00000000-0000-4000-8000-000000000001"' "$state_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$state_file" ;;
        counter_wrong_started) jq '.actions.module_reload.last_started_at+=1' "$state_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$state_file" ;;
        counter_wrong_finished) jq '.actions.module_reload.last_finished_at+=1' "$state_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$state_file" ;;
        unknown_action) jq '.actions[0].action="unknown_action"' "$history_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$history_file" ;;
        duplicate_public) jq '.actions += [.actions[0]]' "$history_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$history_file" ;;
        action_wrong_request) jq '.actions[0].request_id="00000000-0000-4000-8000-000000000002"' "$history_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$history_file" ;;
        action_invalid_status) jq '.actions[0].status="BROKEN"' "$history_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$history_file" ;;
        action_invalid_rc) jq '.actions[0].rc=5' "$history_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$history_file" ;;
        action_started_zero) jq '.actions[0].started_at=0' "$history_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$history_file" ;;
        action_finished_before) jq '.actions[0].finished_at=(.actions[0].started_at-1)' "$history_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$history_file" ;;
        public_countered_false) jq '.actions[0].countered=false' "$history_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$history_file" ;;
        missing_state) rm -f "$state_file" ;;
        corrupt_state) printf '{bad state}\n' > "$state_file" ;;
        malformed_service) printf '[]\n' > "$PIM_CAMERA_STATE_DIR/service-state.json" ;;
        success_interrupted) jq '.request.interrupted=true' "$history_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$history_file" ;;
        failed_interrupted)
            finished=$(jq -r .finished_at "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")
            jq --argjson finished "$finished" '.status="FAILED" | .rc=17 | .finished_at=$finished' "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json" > "$WORK/mutation.result" && mv "$WORK/mutation.result" "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json"
            jq --argjson finished "$finished" '.request.status="FAILED" | .request.rc=17 | .request.finished_at=$finished' "$history_file" > "$WORK/mutation.base" && mv "$WORK/mutation.base" "$history_file"
            jq '.request.interrupted=true' "$history_file" > "$WORK/mutation.json" && mv "$WORK/mutation.json" "$history_file"
            ;;
    esac
    snapshot_terminal_bytes
    set +e
    cam_owner_create "$DAEMON_PID"
    mutation_rc=$?
    set -e
    if [ "$mutation_rc" -eq 70 ]; then
        assert_terminal_bytes_unchanged "$mutation"
    else
        mutation_failures="$mutation_failures $mutation:$mutation_rc"
    fi
done
[ -z "$mutation_failures" ] || fail "terminal action mutations accepted:$mutation_failures"

echo "=== action counter writers share exact timestamps ==="
printf '2000000000\n' > "$WORK/incrementing-now"
_cr_now() {
    local value
    value=$(cat "$WORK/incrementing-now") || return 1
    printf '%s\n' "$value"
    printf '%s\n' "$((value + 1))" > "$WORK/incrementing-now"
}
reset_protocol_sandbox
owner_active
mkdir -p "$PIM_CAMERA_STATE_DIR"
printf '{"dirty":false,"sentinel":"writer-time"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
writer_time_id=$(cam_request_submit module_reload health "writer timestamp" /source/active 99)
cam_request_claim
cam_request_transition QUIESCING
cam_request_transition RUNNING
cam_action_counter_begin module_reload "$writer_time_id"
writer_history_started=$(jq -r '.actions[0].started_at' "$PIM_CAMERA_STATE_DIR/recovery/history/$writer_time_id.json")
writer_state_started=$(jq -r '.actions.module_reload.last_started_at' "$PIM_CAMERA_STATE_DIR/recovery/state.json")
cam_action_counter_finish module_reload "$writer_time_id" SUCCEEDED 0
writer_history_finished=$(jq -r '.actions[0].finished_at' "$PIM_CAMERA_STATE_DIR/recovery/history/$writer_time_id.json")
writer_state_finished=$(jq -r '.actions.module_reload.last_finished_at' "$PIM_CAMERA_STATE_DIR/recovery/state.json")
jq -e '.actions.module_reload.attempted==1 and .actions.module_reload.succeeded==1 and .actions.module_reload.failed==0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "normal finish counter totals"
cam_request_transition VERIFYING
cp "$PIM_CAMERA_RUN_DIR/recovery/active.json" "$WORK/writer-time.active"
cam_request_finish SUCCEEDED 0
cp "$WORK/writer-time.active" "$PIM_CAMERA_RUN_DIR/recovery/active.json"
fake_stat 222
set +e
cam_owner_create "$DAEMON_PID"
writer_takeover_rc=$?
set -e
[ "$writer_history_started" = "$writer_state_started" ] &&
    [ "$writer_history_finished" = "$writer_state_finished" ] &&
    [ "$writer_takeover_rc" -eq 0 ] ||
    fail "split counter timestamps begin=$writer_history_started/$writer_state_started finish=$writer_history_finished/$writer_state_finished takeover=$writer_takeover_rc"

writer_retry_setup() {
    reset_protocol_sandbox
    owner_active
    mkdir -p "$PIM_CAMERA_STATE_DIR"
    printf '{"dirty":false,"sentinel":"writer-retry"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
    writer_retry_id=$(cam_request_submit module_reload health "$1" /source/active 98)
    cam_request_claim
    cam_request_transition QUIESCING
    cam_request_transition RUNNING
}
writer_retry_complete() {
    local label=$1
    cam_request_transition VERIFYING
    cp "$PIM_CAMERA_RUN_DIR/recovery/active.json" "$WORK/$label.active"
    cam_request_finish SUCCEEDED 0
    cp "$WORK/$label.active" "$PIM_CAMERA_RUN_DIR/recovery/active.json"
    fake_stat 222
    set +e
    cam_owner_create "$DAEMON_PID"
    writer_retry_takeover_rc=$?
    set -e
}
writer_retry_failures=''

writer_retry_setup "begin history-only retry"
PIM_CAMERA_TEST_FAILPOINT=counter_begin_after_history expect_rc 70 cam_action_counter_begin module_reload "$writer_retry_id"
retry_history_time=$(jq -r '.actions[0].started_at' "$PIM_CAMERA_STATE_DIR/recovery/history/$writer_retry_id.json")
cam_action_counter_begin module_reload "$writer_retry_id"
retry_state_time=$(jq -r '.actions.module_reload.last_started_at' "$PIM_CAMERA_STATE_DIR/recovery/state.json")
cam_action_counter_finish module_reload "$writer_retry_id" SUCCEEDED 0
writer_retry_complete begin-history-only
[ "$retry_history_time" = "$retry_state_time" ] || writer_retry_failures="$writer_retry_failures begin-history-only:$retry_history_time/$retry_state_time"
[ "$writer_retry_takeover_rc" -eq 0 ] || writer_retry_failures="$writer_retry_failures begin-history-only-takeover:$writer_retry_takeover_rc"

writer_retry_setup "begin state-only retry"
cam_action_counter_begin module_reload "$writer_retry_id"
retry_state_time=$(jq -r '.actions.module_reload.last_started_at' "$PIM_CAMERA_STATE_DIR/recovery/state.json")
jq '.actions=[]' "$PIM_CAMERA_STATE_DIR/recovery/history/$writer_retry_id.json" > "$WORK/retry-history.json" && mv "$WORK/retry-history.json" "$PIM_CAMERA_STATE_DIR/recovery/history/$writer_retry_id.json"
cam_action_counter_begin module_reload "$writer_retry_id"
retry_history_time=$(jq -r '.actions[0].started_at' "$PIM_CAMERA_STATE_DIR/recovery/history/$writer_retry_id.json")
cam_action_counter_finish module_reload "$writer_retry_id" SUCCEEDED 0
writer_retry_complete begin-state-only
[ "$retry_history_time" = "$retry_state_time" ] || writer_retry_failures="$writer_retry_failures begin-state-only:$retry_history_time/$retry_state_time"
[ "$writer_retry_takeover_rc" -eq 0 ] || writer_retry_failures="$writer_retry_failures begin-state-only-takeover:$writer_retry_takeover_rc"

writer_retry_setup "finish history-terminal retry"
cam_action_counter_begin module_reload "$writer_retry_id"
PIM_CAMERA_TEST_FAILPOINT=counter_finish_after_history expect_rc 70 cam_action_counter_finish module_reload "$writer_retry_id" SUCCEEDED 0
retry_history_time=$(jq -r '.actions[0].finished_at' "$PIM_CAMERA_STATE_DIR/recovery/history/$writer_retry_id.json")
jq -e '.actions.module_reload.attempted==1 and .actions.module_reload.succeeded==0 and .actions.module_reload.failed==0 and .actions.module_reload.last_status=="RUNNING"' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "history-terminal partial changed counter totals"
cam_action_counter_finish module_reload "$writer_retry_id" SUCCEEDED 0
retry_state_time=$(jq -r '.actions.module_reload.last_finished_at' "$PIM_CAMERA_STATE_DIR/recovery/state.json")
jq -e '.actions.module_reload.attempted==1 and .actions.module_reload.succeeded==1 and .actions.module_reload.failed==0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "history-terminal retry counter totals"
writer_retry_complete finish-history-terminal
[ "$retry_history_time" = "$retry_state_time" ] || writer_retry_failures="$writer_retry_failures finish-history-terminal:$retry_history_time/$retry_state_time"
[ "$writer_retry_takeover_rc" -eq 0 ] || writer_retry_failures="$writer_retry_failures finish-history-terminal-takeover:$writer_retry_takeover_rc"

writer_retry_setup "finish state-terminal retry"
cam_action_counter_begin module_reload "$writer_retry_id"
cp "$PIM_CAMERA_STATE_DIR/recovery/history/$writer_retry_id.json" "$WORK/running-history.json"
cam_action_counter_finish module_reload "$writer_retry_id" SUCCEEDED 0
retry_state_time=$(jq -r '.actions.module_reload.last_finished_at' "$PIM_CAMERA_STATE_DIR/recovery/state.json")
retry_state_terminal=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
jq -e '.actions.module_reload.attempted==1 and .actions.module_reload.succeeded==1 and .actions.module_reload.failed==0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "state-terminal fixture counter totals"
cp "$WORK/running-history.json" "$PIM_CAMERA_STATE_DIR/recovery/history/$writer_retry_id.json"
cam_action_counter_finish module_reload "$writer_retry_id" SUCCEEDED 0
retry_history_time=$(jq -r '.actions[0].finished_at' "$PIM_CAMERA_STATE_DIR/recovery/history/$writer_retry_id.json")
[ "$retry_state_terminal" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "state-terminal retry rewrote counters"
jq -e '.actions.module_reload.attempted==1 and .actions.module_reload.succeeded==1 and .actions.module_reload.failed==0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "state-terminal retry counter totals"
writer_retry_complete finish-state-terminal
[ "$retry_history_time" = "$retry_state_time" ] || writer_retry_failures="$writer_retry_failures finish-state-terminal:$retry_history_time/$retry_state_time"
[ "$writer_retry_takeover_rc" -eq 0 ] || writer_retry_failures="$writer_retry_failures finish-state-terminal-takeover:$writer_retry_takeover_rc"

_cr_now() { date +%s; }
[ -z "$writer_retry_failures" ] || fail "counter retry timestamps diverged:$writer_retry_failures"

echo "=== reciprocal terminal action attribution remains valid ==="
reset_protocol_sandbox
owner_active
mkdir -p "$PIM_CAMERA_STATE_DIR"
printf '{"dirty":false,"sentinel":"uncountered"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
uncountered_id=$(cam_request_submit apply_config operator "uncountered terminal" /source/apply 100)
cam_request_claim
cam_request_transition QUIESCING
cam_request_transition RUNNING
_coc_record_step ord_restart SUCCEEDED 0
_coc_record_step vcm_restart SUCCEEDED 0
_coc_record_step policy_reload SUCCEEDED 0
cam_request_transition VERIFYING
cam_request_finish SUCCEEDED 0
jq -e --arg id "$uncountered_id" '
  [.actions[].action]==["ord_restart","vcm_restart","policy_reload"] and
  all(.actions[]; .request_id==$id and .countered==false and .status=="SUCCEEDED" and .rc==0)
' "$PIM_CAMERA_STATE_DIR/recovery/history/$uncountered_id.json" >/dev/null || fail "real uncountered terminal fixture"
uncountered_history=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$uncountered_id.json")
uncountered_service=$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")
[ ! -e "$PIM_CAMERA_STATE_DIR/recovery/state.json" ] || fail "uncountered fixture unexpectedly created global counters"
fake_stat 222
expect_rc 0 cam_owner_create "$DAEMON_PID"
[ "$uncountered_history" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$uncountered_id.json")" ] || fail "uncountered takeover rewrote history"
[ "$uncountered_service" = "$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "uncountered takeover rewrote service state"
[ ! -e "$PIM_CAMERA_STATE_DIR/recovery/state.json" ] || fail "uncountered takeover created global counters"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "uncountered takeover retained active lease"

reset_protocol_sandbox
owner_active
mkdir -p "$PIM_CAMERA_STATE_DIR"
printf '{"dirty":false,"sentinel":"multiple-public"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
multiple_public_id=$(cam_request_submit apply_config operator "multiple public terminal" /source/apply 101)
cam_request_claim
cam_request_transition QUIESCING
cam_request_transition RUNNING
cam_action_counter_begin module_reload "$multiple_public_id"
cam_action_counter_finish module_reload "$multiple_public_id" SUCCEEDED 0
cam_action_counter_begin gstapp_restart "$multiple_public_id"
cam_action_counter_finish gstapp_restart "$multiple_public_id" SUCCEEDED 0
cam_request_transition VERIFYING
cam_request_finish SUCCEEDED 0
jq -e --arg id "$multiple_public_id" '
  [.actions[].action]==["module_reload","gstapp_restart"] and
  all(.actions[]; .request_id==$id and .status=="SUCCEEDED" and .rc==0)
' "$PIM_CAMERA_STATE_DIR/recovery/history/$multiple_public_id.json" >/dev/null || fail "real multiple-public terminal fixture"
multiple_history=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$multiple_public_id.json")
multiple_counter=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")
multiple_service=$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")
fake_stat 222
expect_rc 0 cam_owner_create "$DAEMON_PID"
[ "$multiple_history" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$multiple_public_id.json")" ] || fail "multiple-public takeover rewrote history"
[ "$multiple_counter" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "multiple-public takeover rewrote counters"
[ "$multiple_service" = "$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "multiple-public takeover rewrote service state"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "multiple-public takeover retained active lease"

echo "=== interrupted terminal retry preserves matching running evidence ==="
reset_protocol_sandbox
owner_active
mkdir -p "$PIM_CAMERA_STATE_DIR"
printf '{"dirty":false,"sentinel":"running-interrupted"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
running_interrupted_id=$(cam_request_submit module_reload health "running interrupted" /source/active 102)
cam_request_claim
cam_request_transition QUIESCING
cam_request_transition RUNNING
cam_action_counter_begin module_reload "$running_interrupted_id"
running_action=$(jq -c .actions "$PIM_CAMERA_STATE_DIR/recovery/history/$running_interrupted_id.json")
running_counter=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")
fake_stat 222
PIM_CAMERA_TEST_FAILPOINT=owner_reconcile_after_result expect_rc 70 cam_owner_create "$DAEMON_PID"
jq -e --arg id "$running_interrupted_id" '.request.id==$id and .request.status=="FAILED" and .request.rc==70 and .request.interrupted==true and .request.interrupted_reason=="owner_stale"' "$PIM_CAMERA_STATE_DIR/recovery/history/$running_interrupted_id.json" >/dev/null || fail "interrupted retry history"
[ "$running_action" = "$(jq -c .actions "$PIM_CAMERA_STATE_DIR/recovery/history/$running_interrupted_id.json")" ] || fail "interrupted first pass rewrote running action"
[ "$running_counter" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "interrupted first pass rewrote running counter"
interrupted_history=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$running_interrupted_id.json")
interrupted_result=$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$running_interrupted_id.json")
interrupted_counter=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")
interrupted_service=$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")
expect_rc 0 cam_owner_create "$DAEMON_PID"
[ "$interrupted_history" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$running_interrupted_id.json")" ] || fail "interrupted retry rewrote history"
[ "$interrupted_result" = "$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$running_interrupted_id.json")" ] || fail "interrupted retry rewrote result"
[ "$interrupted_counter" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "interrupted retry rewrote counters"
[ "$interrupted_service" = "$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "interrupted retry rewrote dirty service state"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "interrupted retry retained active lease"

echo "=== same-action retry settles owner-stale running attempt exactly once ==="
reset_protocol_sandbox
owner_active
mkdir -p "$PIM_CAMERA_STATE_DIR"
printf '{"dirty":false,"sentinel":"stale-running-settlement"}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
stale_running_id=$(cam_request_submit module_reload health "stale running predecessor" /source/stale 103)
cam_request_claim
cam_request_transition QUIESCING
cam_request_transition RUNNING
cam_action_counter_begin module_reload "$stale_running_id"
fake_stat 222
expect_rc 0 cam_owner_create "$DAEMON_PID"
stale_running_history=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/history/$stale_running_id.json")
cam_owner_set_lifecycle ACTIVE
retry_running_id=$(cam_request_submit module_reload health "same action retry" /source/retry 104)
cam_request_claim
cam_request_transition QUIESCING
cam_request_transition RUNNING
expect_rc 0 cam_action_counter_begin module_reload "$retry_running_id"
expect_rc 0 cam_action_counter_finish module_reload "$retry_running_id" SUCCEEDED 0
jq -e '.actions.module_reload.attempted==2 and .actions.module_reload.succeeded==1 and .actions.module_reload.failed==1 and .actions.module_reload.consecutive_failures==0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "same-action retry did not settle stale attempt exactly once"
[ "$stale_running_history" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/history/$stale_running_id.json")" ] || fail "same-action retry rewrote predecessor history"

stale_running_retry_setup() {
    local label=$1
    reset_protocol_sandbox
    owner_active
    mkdir -p "$PIM_CAMERA_STATE_DIR"
    printf '{"dirty":false,"sentinel":"%s"}\n' "$label" > "$PIM_CAMERA_STATE_DIR/service-state.json"
    printf '{"sentinel":"round-6-runtime"}\n' > "$PIM_CAMERA_RUNTIME_JSON"
    printf 'round-6-call\n' > "$PIM_CAMERA_CALL_LOG"
    stale_retry_prior_id=$(cam_request_submit module_reload health "$label predecessor" /source/stale 105)
    cam_request_claim
    cam_request_transition QUIESCING
    cam_request_transition RUNNING
    cam_action_counter_begin module_reload "$stale_retry_prior_id"
    fake_stat 222
    cam_owner_create "$DAEMON_PID"
    stale_retry_prior_history="$PIM_CAMERA_STATE_DIR/recovery/history/$stale_retry_prior_id.json"
    stale_retry_prior_result="$PIM_CAMERA_RUN_DIR/recovery/results/$stale_retry_prior_id.json"
    cam_owner_set_lifecycle ACTIVE
    stale_retry_id=$(cam_request_submit module_reload health "$label current" /source/retry 106)
    cam_request_claim
    cam_request_transition QUIESCING
    cam_request_transition RUNNING
    stale_retry_current_history="$PIM_CAMERA_STATE_DIR/recovery/history/$stale_retry_id.json"
}

echo "=== same-action stale settlement preserves failure and failpoint arithmetic ==="
stale_running_retry_setup "same action failure"
stale_retry_old_history=$(file_fingerprint "$stale_retry_prior_history")
cam_action_counter_begin module_reload "$stale_retry_id"
cam_action_counter_finish module_reload "$stale_retry_id" FAILED 17
jq -e '.actions.module_reload.attempted==2 and .actions.module_reload.succeeded==0 and .actions.module_reload.failed==2 and .actions.module_reload.consecutive_failures==2' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "same-action failure double-counted stale settlement"
[ "$stale_retry_old_history" = "$(file_fingerprint "$stale_retry_prior_history")" ] || fail "same-action failure rewrote predecessor history"

stale_running_retry_setup "same action begin failpoint"
stale_retry_old_history=$(file_fingerprint "$stale_retry_prior_history")
PIM_CAMERA_TEST_FAILPOINT=counter_begin_after_history expect_rc 70 cam_action_counter_begin module_reload "$stale_retry_id"
jq -e '.actions.module_reload.attempted==1 and .actions.module_reload.succeeded==0 and .actions.module_reload.failed==0 and .actions.module_reload.last_status=="RUNNING"' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "same-action begin failpoint changed state"
cam_action_counter_begin module_reload "$stale_retry_id"
cam_action_counter_finish module_reload "$stale_retry_id" SUCCEEDED 0
jq -e '.actions.module_reload.attempted==2 and .actions.module_reload.succeeded==1 and .actions.module_reload.failed==1 and .actions.module_reload.consecutive_failures==0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "same-action failpoint retry settled more than once"
[ "$stale_retry_old_history" = "$(file_fingerprint "$stale_retry_prior_history")" ] || fail "same-action failpoint rewrote predecessor history"

stale_running_retry_setup "same action state-only retry"
cam_action_counter_begin module_reload "$stale_retry_id"
jq '.actions=[]' "$stale_retry_current_history" > "$WORK/stale-state-only" && mv "$WORK/stale-state-only" "$stale_retry_current_history"
cam_action_counter_begin module_reload "$stale_retry_id"
cam_action_counter_finish module_reload "$stale_retry_id" SUCCEEDED 0
jq -e '.actions.module_reload.attempted==2 and .actions.module_reload.succeeded==1 and .actions.module_reload.failed==1 and .actions.module_reload.consecutive_failures==0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "same-action state-only retry resettled predecessor"

echo "=== consecutive stale interruptions settle once each ==="
stale_running_retry_setup "first interruption"
cam_action_counter_begin module_reload "$stale_retry_id"
second_stale_history="$stale_retry_current_history"
fake_stat 333
cam_owner_create "$DAEMON_PID"
second_stale_fingerprint=$(file_fingerprint "$second_stale_history")
cam_owner_set_lifecycle ACTIVE
third_retry_id=$(cam_request_submit module_reload health "third attempt" /source/retry 107)
cam_request_claim
cam_request_transition QUIESCING
cam_request_transition RUNNING
cam_action_counter_begin module_reload "$third_retry_id"
cam_action_counter_finish module_reload "$third_retry_id" SUCCEEDED 0
jq -e '.actions.module_reload.attempted==3 and .actions.module_reload.succeeded==1 and .actions.module_reload.failed==2 and .actions.module_reload.consecutive_failures==0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "consecutive stale interruptions were not settled once each"
[ "$second_stale_fingerprint" = "$(file_fingerprint "$second_stale_history")" ] || fail "third attempt rewrote second interruption history"

echo "=== different action leaves stale action unresolved ==="
stale_running_retry_setup "different action first"
module_before=$(jq -c '.actions.module_reload' "$PIM_CAMERA_STATE_DIR/recovery/state.json")
cam_action_counter_begin gstapp_restart "$stale_retry_id"
cam_action_counter_finish gstapp_restart "$stale_retry_id" SUCCEEDED 0
[ "$module_before" = "$(jq -c '.actions.module_reload' "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "different action settled module_reload"
jq -e '.actions.gstapp_restart.attempted==1 and .actions.gstapp_restart.succeeded==1 and .actions.gstapp_restart.failed==0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "different action did not finish independently"
cam_action_counter_begin module_reload "$stale_retry_id"
cam_action_counter_finish module_reload "$stale_retry_id" SUCCEEDED 0
jq -e '.actions.module_reload.attempted==2 and .actions.module_reload.succeeded==1 and .actions.module_reload.failed==1' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "later same action did not settle predecessor"

snapshot_stale_begin_bytes() {
    stale_begin_owner=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")
    stale_begin_active=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")
    stale_begin_current_history=$(file_fingerprint "$stale_retry_current_history")
    stale_begin_prior_history=$(file_fingerprint "$stale_retry_prior_history")
    stale_begin_result=$(file_fingerprint "$stale_retry_prior_result")
    stale_begin_state=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
    stale_begin_service=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")
    stale_begin_runtime=$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")
    stale_begin_call=$(file_fingerprint "$PIM_CAMERA_CALL_LOG")
}
assert_stale_begin_bytes_unchanged() {
    local label=$1
    [ "$stale_begin_owner" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "$label mutated owner"
    [ "$stale_begin_active" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")" ] || fail "$label mutated active"
    [ "$stale_begin_current_history" = "$(file_fingerprint "$stale_retry_current_history")" ] || fail "$label mutated current history"
    [ "$stale_begin_prior_history" = "$(file_fingerprint "$stale_retry_prior_history")" ] || fail "$label mutated prior history"
    [ "$stale_begin_result" = "$(file_fingerprint "$stale_retry_prior_result")" ] || fail "$label mutated result"
    [ "$stale_begin_state" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "$label mutated state"
    [ "$stale_begin_service" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "$label mutated service"
    [ "$stale_begin_runtime" = "$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")" ] || fail "$label mutated runtime"
    [ "$stale_begin_call" = "$(file_fingerprint "$PIM_CAMERA_CALL_LOG")" ] || fail "$label mutated call log"
}

echo "=== invalid stale settlement evidence fails closed byte-for-byte ==="
stale_begin_failures=''
for mutation in missing_result corrupt_result missing_history corrupt_history nonsynthetic request_id started_at duplicate_action missing_action bad_arithmetic; do
    stale_running_retry_setup "invalid $mutation"
    case "$mutation" in
        missing_result) rm -f "$stale_retry_prior_result" ;;
        corrupt_result) printf '{bad result}\n' > "$stale_retry_prior_result" ;;
        missing_history) rm -f "$stale_retry_prior_history" ;;
        corrupt_history) printf '{bad history}\n' > "$stale_retry_prior_history" ;;
        nonsynthetic) jq 'del(.request.interrupted,.request.interrupted_reason)' "$stale_retry_prior_history" > "$WORK/stale-mutation" && mv "$WORK/stale-mutation" "$stale_retry_prior_history" ;;
        request_id) jq '.request.id="00000000-0000-4000-8000-000000000008"' "$stale_retry_prior_history" > "$WORK/stale-mutation" && mv "$WORK/stale-mutation" "$stale_retry_prior_history" ;;
        started_at) jq '.actions[0].started_at+=1' "$stale_retry_prior_history" > "$WORK/stale-mutation" && mv "$WORK/stale-mutation" "$stale_retry_prior_history" ;;
        duplicate_action) jq '.actions += [.actions[0]]' "$stale_retry_prior_history" > "$WORK/stale-mutation" && mv "$WORK/stale-mutation" "$stale_retry_prior_history" ;;
        missing_action) jq '.actions=[]' "$stale_retry_prior_history" > "$WORK/stale-mutation" && mv "$WORK/stale-mutation" "$stale_retry_prior_history" ;;
        bad_arithmetic) jq '.actions.module_reload.attempted+=1' "$PIM_CAMERA_STATE_DIR/recovery/state.json" > "$WORK/stale-mutation" && mv "$WORK/stale-mutation" "$PIM_CAMERA_STATE_DIR/recovery/state.json" ;;
    esac
    snapshot_stale_begin_bytes
    set +e
    cam_action_counter_begin module_reload "$stale_retry_id"
    stale_begin_rc=$?
    set -e
    if [ "$stale_begin_rc" -eq 70 ]; then
        assert_stale_begin_bytes_unchanged "$mutation"
    else
        stale_begin_failures="$stale_begin_failures $mutation:$stale_begin_rc"
    fi
done
[ -z "$stale_begin_failures" ] || fail "invalid stale settlement evidence accepted:$stale_begin_failures"

round7_history_first_setup() {
    local label=$1
    stale_running_retry_setup "$label"
    PIM_CAMERA_TEST_FAILPOINT=counter_begin_after_history expect_rc 70 cam_action_counter_begin module_reload "$stale_retry_id"
    round7_current_result="$PIM_CAMERA_RUN_DIR/recovery/results/$stale_retry_id.json"
    fake_stat 333
}
round7_snapshot_bytes() {
    round7_owner_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")
    round7_active_before=$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")
    round7_current_history_before=$(file_fingerprint "$stale_retry_current_history")
    round7_current_result_before=$(file_fingerprint "$round7_current_result")
    round7_prior_history_before=$(file_fingerprint "$stale_retry_prior_history")
    round7_prior_result_before=$(file_fingerprint "$stale_retry_prior_result")
    round7_state_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
    round7_service_before=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")
    round7_runtime_before=$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")
    round7_call_before=$(file_fingerprint "$PIM_CAMERA_CALL_LOG")
}
round7_assert_bytes_unchanged() {
    local label=$1
    [ "$round7_owner_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "$label mutated owner"
    [ "$round7_active_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")" ] || fail "$label mutated active"
    [ "$round7_current_history_before" = "$(file_fingerprint "$stale_retry_current_history")" ] || fail "$label mutated current history"
    [ "$round7_current_result_before" = "$(file_fingerprint "$round7_current_result")" ] || fail "$label mutated current result"
    [ "$round7_prior_history_before" = "$(file_fingerprint "$stale_retry_prior_history")" ] || fail "$label mutated prior history"
    [ "$round7_prior_result_before" = "$(file_fingerprint "$stale_retry_prior_result")" ] || fail "$label mutated prior result"
    [ "$round7_state_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "$label mutated state"
    [ "$round7_service_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "$label mutated service"
    [ "$round7_runtime_before" = "$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")" ] || fail "$label mutated runtime"
    [ "$round7_call_before" = "$(file_fingerprint "$PIM_CAMERA_CALL_LOG")" ] || fail "$label mutated call log"
}

echo "=== repaired-state stale takeover retries exactly once ==="
round7_history_first_setup "round 7 state repair failpoint"
round7_snapshot_bytes
PIM_CAMERA_TEST_FAILPOINT=owner_reconcile_after_state_repair expect_rc 70 cam_owner_create "$DAEMON_PID"
[ "$round7_owner_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "state repair failpoint replaced owner"
[ "$round7_active_before" = "$(file_fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")" ] || fail "state repair failpoint removed active"
[ "$round7_current_history_before" = "$(file_fingerprint "$stale_retry_current_history")" ] || fail "state repair failpoint terminalized history"
[ "$round7_current_result_before" = "$(file_fingerprint "$round7_current_result")" ] || fail "state repair failpoint wrote result"
[ "$round7_prior_history_before" = "$(file_fingerprint "$stale_retry_prior_history")" ] || fail "state repair failpoint rewrote prior history"
[ "$round7_prior_result_before" = "$(file_fingerprint "$stale_retry_prior_result")" ] || fail "state repair failpoint rewrote prior result"
[ "$round7_service_before" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "state repair failpoint marked service dirty"
[ "$round7_runtime_before" = "$(file_fingerprint "$PIM_CAMERA_RUNTIME_JSON")" ] || fail "state repair failpoint mutated runtime"
[ "$round7_call_before" = "$(file_fingerprint "$PIM_CAMERA_CALL_LOG")" ] || fail "state repair failpoint mutated call log"
jq -e --arg id "$stale_retry_id" '.actions.module_reload.attempted==2 and .actions.module_reload.succeeded==0 and .actions.module_reload.failed==1 and .actions.module_reload.consecutive_failures==1 and .actions.module_reload.last_request_id==$id and .actions.module_reload.last_status=="RUNNING"' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "state repair failpoint did not persist exact repair"
round7_repaired_state=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
expect_rc 0 cam_owner_create "$DAEMON_PID"
[ "$round7_repaired_state" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "state repair retry settled twice"
[ "$round7_prior_history_before" = "$(file_fingerprint "$stale_retry_prior_history")" ] || fail "state repair retry rewrote prior history"
[ "$round7_prior_result_before" = "$(file_fingerprint "$stale_retry_prior_result")" ] || fail "state repair retry rewrote prior result"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "state repair retry retained active"

echo "=== repaired-state takeover preserves later reconcile failpoints ==="
for round7_failpoint in owner_reconcile_after_history owner_reconcile_after_result; do
    round7_history_first_setup "round 7 $round7_failpoint"
    round7_prior_history_before=$(file_fingerprint "$stale_retry_prior_history")
    round7_prior_result_before=$(file_fingerprint "$stale_retry_prior_result")
    PIM_CAMERA_TEST_FAILPOINT="$round7_failpoint" expect_rc 70 cam_owner_create "$DAEMON_PID"
    round7_repaired_state=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
    expect_rc 0 cam_owner_create "$DAEMON_PID"
    [ "$round7_repaired_state" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "$round7_failpoint retry settled twice"
    [ "$round7_prior_history_before" = "$(file_fingerprint "$stale_retry_prior_history")" ] || fail "$round7_failpoint rewrote prior history"
    [ "$round7_prior_result_before" = "$(file_fingerprint "$stale_retry_prior_result")" ] || fail "$round7_failpoint rewrote prior result"
    jq -e --arg id "$stale_retry_id" '.actions.module_reload.attempted==2 and .actions.module_reload.succeeded==0 and .actions.module_reload.failed==1 and .actions.module_reload.consecutive_failures==1 and .actions.module_reload.last_request_id==$id and .actions.module_reload.last_status=="RUNNING"' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "$round7_failpoint retry counters"
done

echo "=== completed begin and pre-begin stale takeover remain exact ==="
stale_running_retry_setup "round 7 completed begin"
cam_action_counter_begin module_reload "$stale_retry_id"
round7_completed_state=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
round7_completed_prior_history=$(file_fingerprint "$stale_retry_prior_history")
round7_completed_prior_result=$(file_fingerprint "$stale_retry_prior_result")
fake_stat 333
expect_rc 0 cam_owner_create "$DAEMON_PID"
[ "$round7_completed_state" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "completed begin takeover rewrote state"
[ "$round7_completed_prior_history" = "$(file_fingerprint "$stale_retry_prior_history")" ] || fail "completed begin takeover rewrote prior history"
[ "$round7_completed_prior_result" = "$(file_fingerprint "$stale_retry_prior_result")" ] || fail "completed begin takeover rewrote prior result"

stale_running_retry_setup "round 7 pre-begin"
round7_prebegin_state=$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
round7_prebegin_prior_history=$(file_fingerprint "$stale_retry_prior_history")
round7_prebegin_prior_result=$(file_fingerprint "$stale_retry_prior_result")
fake_stat 333
expect_rc 0 cam_owner_create "$DAEMON_PID"
[ "$round7_prebegin_state" = "$(file_fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "pre-begin takeover settled unrelated state"
[ "$round7_prebegin_prior_history" = "$(file_fingerprint "$stale_retry_prior_history")" ] || fail "pre-begin takeover rewrote prior history"
[ "$round7_prebegin_prior_result" = "$(file_fingerprint "$stale_retry_prior_result")" ] || fail "pre-begin takeover rewrote prior result"
jq -e '.actions|length==0' "$stale_retry_current_history" >/dev/null || fail "pre-begin takeover invented current action"

echo "=== history-first repair preserves matching other action attribution ==="
stale_running_retry_setup "round 7 matching other action"
cam_action_counter_begin gstapp_restart "$stale_retry_id"
cam_action_counter_finish gstapp_restart "$stale_retry_id" SUCCEEDED 0
PIM_CAMERA_TEST_FAILPOINT=counter_begin_after_history expect_rc 70 cam_action_counter_begin module_reload "$stale_retry_id"
fake_stat 333
expect_rc 0 cam_owner_create "$DAEMON_PID"
jq -e --arg id "$stale_retry_id" '
  .actions.module_reload.attempted==2 and
  .actions.module_reload.succeeded==0 and
  .actions.module_reload.failed==1 and
  .actions.module_reload.consecutive_failures==1 and
  .actions.module_reload.last_request_id==$id and
  .actions.module_reload.last_status=="RUNNING" and
  .actions.gstapp_restart.attempted==1 and
  .actions.gstapp_restart.succeeded==1 and
  .actions.gstapp_restart.failed==0 and
  .actions.gstapp_restart.last_request_id==$id and
  .actions.gstapp_restart.last_status=="SUCCEEDED"
' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "history-first repair lost matching other action attribution"

echo "=== invalid history-first stale repair evidence fails closed ==="
round7_failures=''
for mutation in unexpected_current_result current_request prior_started_at current_action \
    missing_prior_history corrupt_prior_history missing_prior_result corrupt_prior_result \
    nonsynthetic_prior bad_prior_arithmetic duplicate_current multiple_current \
    other_current_state_mismatch; do
    round7_history_first_setup "round 7 invalid $mutation"
    case "$mutation" in
        unexpected_current_result)
            jq -c --argjson now "$(date +%s)" '.status="FAILED" | .rc=70 | .finished_at=$now | {id,type,status,rc,source,reason,created_at,finished_at,source_path,source_mtime}' "$PIM_CAMERA_RUN_DIR/recovery/active.json" > "$round7_current_result"
            ;;
        current_request) jq '.request.reason="mismatched current request"' "$stale_retry_current_history" > "$WORK/round7-mutation" && mv "$WORK/round7-mutation" "$stale_retry_current_history" ;;
        prior_started_at) jq '.actions[0].started_at+=1' "$stale_retry_prior_history" > "$WORK/round7-mutation" && mv "$WORK/round7-mutation" "$stale_retry_prior_history" ;;
        current_action) jq '.actions[0].action="gstapp_restart"' "$stale_retry_current_history" > "$WORK/round7-mutation" && mv "$WORK/round7-mutation" "$stale_retry_current_history" ;;
        missing_prior_history) rm -f "$stale_retry_prior_history" ;;
        corrupt_prior_history) printf '{bad prior history}\n' > "$stale_retry_prior_history" ;;
        missing_prior_result) rm -f "$stale_retry_prior_result" ;;
        corrupt_prior_result) printf '{bad prior result}\n' > "$stale_retry_prior_result" ;;
        nonsynthetic_prior) jq 'del(.request.interrupted,.request.interrupted_reason)' "$stale_retry_prior_history" > "$WORK/round7-mutation" && mv "$WORK/round7-mutation" "$stale_retry_prior_history" ;;
        bad_prior_arithmetic) jq '.actions.module_reload.attempted+=1' "$PIM_CAMERA_STATE_DIR/recovery/state.json" > "$WORK/round7-mutation" && mv "$WORK/round7-mutation" "$PIM_CAMERA_STATE_DIR/recovery/state.json" ;;
        duplicate_current) jq '.actions += [.actions[0]]' "$stale_retry_current_history" > "$WORK/round7-mutation" && mv "$WORK/round7-mutation" "$stale_retry_current_history" ;;
        multiple_current)
            jq --arg id "$stale_retry_id" '.actions += [{action:"gstapp_restart",request_id:$id,status:"RUNNING",started_at:(.actions[0].started_at+1)}]' "$stale_retry_current_history" > "$WORK/round7-mutation" && mv "$WORK/round7-mutation" "$stale_retry_current_history"
            ;;
        other_current_state_mismatch)
            jq --arg id "$stale_retry_id" '.actions += [{action:"gstapp_restart",request_id:$id,status:"SUCCEEDED",rc:0,started_at:.actions[0].started_at,finished_at:.actions[0].started_at}]' "$stale_retry_current_history" > "$WORK/round7-mutation" && mv "$WORK/round7-mutation" "$stale_retry_current_history"
            ;;
    esac
    round7_snapshot_bytes
    set +e
    cam_owner_create "$DAEMON_PID"
    round7_rc=$?
    set -e
    if [ "$round7_rc" -eq 70 ]; then
        round7_assert_bytes_unchanged "$mutation"
    else
        round7_failures="$round7_failures $mutation:$round7_rc"
    fi
done
[ -z "$round7_failures" ] || fail "invalid history-first repair evidence accepted:$round7_failures"

echo "=== stale owner acquisition terminalizes accepted leases ==="
reset_protocol_sandbox
owner_active
mkdir -p "$PIM_CAMERA_STATE_DIR"
printf '{"dirty":false}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
stale_pending_id=$(cam_request_submit apply_config operator "stale pending" /source/pending 321)
stale_pending_owner=$(jq -c '{boot_id,invocation_id,pid,proc_start_time,token,created_at}' "$PIM_CAMERA_RUN_DIR/owner.json")
fake_stat 222
cam_owner_create "$DAEMON_PID"
jq -e --arg id "$stale_pending_id" '.id==$id and .type=="apply_config" and .source=="operator" and .reason=="stale pending" and .status=="FAILED" and .rc>0 and .source_path=="/source/pending" and .source_mtime==321' "$PIM_CAMERA_RUN_DIR/recovery/results/$stale_pending_id.json" >/dev/null || fail "stale pending waiter has no complete terminal result"
jq -e --arg id "$stale_pending_id" '.request.id==$id and .request.type=="apply_config" and .request.source=="operator" and .request.reason=="stale pending" and .request.status=="FAILED" and .request.rc>0 and .request.interrupted==true and (.actions|length)==0' "$PIM_CAMERA_STATE_DIR/recovery/history/$stale_pending_id.json" >/dev/null || fail "stale pending history was not terminalized"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "stale pending lease survived acquisition"
[ "$stale_pending_owner" != "$(jq -c '{boot_id,invocation_id,pid,proc_start_time,token,created_at}' "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "stale pending owner was not replaced"
jq -e '.proc_start_time=="222" and .lifecycle=="STARTING"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "replacement owner tuple"
jq -e '.dirty==true' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "stale pending acquisition did not mark dirty"

echo "=== stale reconciliation resumes after durable result ==="
reset_protocol_sandbox
owner_active
mkdir -p "$PIM_CAMERA_STATE_DIR"
printf '{"dirty":false}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
stale_retry_id=$(cam_request_submit apply_config operator "stale retry" /source/retry 777)
stale_retry_owner=$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")
fake_stat 222
PIM_CAMERA_TEST_FAILPOINT=owner_reconcile_after_result expect_rc 70 cam_owner_create "$DAEMON_PID"
[ "$stale_retry_owner" = "$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "partial reconciliation replaced stale owner"
[ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "partial reconciliation removed lease before commit"
jq -e --arg id "$stale_retry_id" '.request.id==$id and .request.status=="FAILED" and .request.rc==70 and .request.interrupted==true' "$PIM_CAMERA_STATE_DIR/recovery/history/$stale_retry_id.json" >/dev/null || fail "partial reconciliation history is not terminal"
jq -e --arg id "$stale_retry_id" '.id==$id and .status=="FAILED" and .rc==70' "$PIM_CAMERA_RUN_DIR/recovery/results/$stale_retry_id.json" >/dev/null || fail "partial reconciliation result is not terminal"
stale_retry_history=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$stale_retry_id.json")
stale_retry_result=$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$stale_retry_id.json")
cam_owner_create "$DAEMON_PID"
[ "$stale_retry_history" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$stale_retry_id.json")" ] || fail "retry rewrote terminal history"
[ "$stale_retry_result" = "$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$stale_retry_id.json")" ] || fail "retry rewrote terminal result"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "retry did not remove reconciled lease"
jq -e '.proc_start_time=="222" and .lifecycle=="STARTING"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "retry did not publish replacement owner"

reset_protocol_sandbox
owner_active
mkdir -p "$PIM_CAMERA_STATE_DIR"
printf '{"dirty":false}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
stale_wait_out="$WORK/stale-wait.out"
"$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" apply-config --source operator --reason "stale waiter" --wait "$CONTROLLED_WAIT_SECONDS" >"$stale_wait_out" &
stale_wait_pid=$!
for _ in $(seq 1 30); do [ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && break; sleep 0.1; done
[ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "stale waiter request was not accepted"
stale_wait_id=$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/pending.json")
fake_stat 222
cam_owner_create "$DAEMON_PID"
set +e; wait "$stale_wait_pid"; stale_wait_rc=$?; set -e
[ "$stale_wait_rc" -eq 70 ] || fail "stale waiter returned rc=$stale_wait_rc"
[ "$(cat "$stale_wait_out")" = "CAM_RECOVERY_RESULT id=$stale_wait_id type=apply_config status=FAILED rc=70" ] || fail "stale waiter did not consume terminal result"

reset_protocol_sandbox
owner_active
mkdir -p "$PIM_CAMERA_STATE_DIR"
printf '{"dirty":false}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
stale_active_id=$(cam_request_submit module_reload health "stale active" /source/active 654)
cam_request_claim
cam_request_transition QUIESCING
cam_request_transition RUNNING
cam_action_counter_begin module_reload "$stale_active_id"
active_actions_before=$(jq -c .actions "$PIM_CAMERA_STATE_DIR/recovery/history/$stale_active_id.json")
counter_before=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")
fake_stat 222
cam_owner_create "$DAEMON_PID"
jq -e --arg id "$stale_active_id" '.id==$id and .type=="module_reload" and .source=="health" and .reason=="stale active" and .status=="FAILED" and .rc>0 and .source_path=="/source/active" and .source_mtime==654' "$PIM_CAMERA_RUN_DIR/recovery/results/$stale_active_id.json" >/dev/null || fail "stale active waiter has no complete terminal result"
jq -e --arg id "$stale_active_id" '.request.id==$id and .request.status=="FAILED" and .request.rc>0 and .request.interrupted==true' "$PIM_CAMERA_STATE_DIR/recovery/history/$stale_active_id.json" >/dev/null || fail "stale active history was not terminalized"
[ "$active_actions_before" = "$(jq -c .actions "$PIM_CAMERA_STATE_DIR/recovery/history/$stale_active_id.json")" ] || fail "stale active action history was not preserved"
[ "$counter_before" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "stale active reconciliation mutated counters"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "stale active lease survived acquisition"
jq -e '.dirty==true' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "stale active acquisition did not mark dirty"

echo "=== corrupt abandoned lease fails closed ==="
reset_protocol_sandbox
owner_active
mkdir -p "$PIM_CAMERA_STATE_DIR/recovery" "$PIM_CAMERA_RUN_DIR/recovery"
printf '{"dirty":false}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
printf '{bad json}\n' > "$PIM_CAMERA_RUN_DIR/recovery/pending.json"
corrupt_owner_before=$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")
corrupt_service_before=$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")
corrupt_pending_before=$(cksum "$PIM_CAMERA_RUN_DIR/recovery/pending.json")
fake_stat 222
expect_rc 70 cam_owner_create "$DAEMON_PID"
[ "$corrupt_owner_before" = "$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "corrupt reconciliation replaced owner"
[ "$corrupt_service_before" = "$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "corrupt reconciliation mutated service state"
[ "$corrupt_pending_before" = "$(cksum "$PIM_CAMERA_RUN_DIR/recovery/pending.json")" ] || fail "corrupt reconciliation deleted or rewrote lease"
[ ! -d "$PIM_CAMERA_RUN_DIR/recovery/results" ] || fail "corrupt reconciliation created a result"
[ ! -d "$PIM_CAMERA_STATE_DIR/recovery/history" ] || fail "corrupt reconciliation created history"

reset_protocol_sandbox

cam_owner_create "$DAEMON_PID"
jq -e '.boot_id == "test-boot-id" and (.invocation_id | strings) and .pid == 4242 and .proc_start_time == "111" and (.token | strings) and (.created_at | numbers) and .lifecycle == "STARTING"' "$PIM_CAMERA_RUN_DIR/owner.json" >/dev/null || fail "owner record tuple"
invocation=$(jq -r .invocation_id "$PIM_CAMERA_RUN_DIR/owner.json")
token=$(jq -r .token "$PIM_CAMERA_RUN_DIR/owner.json")
uuid "$invocation"
fake_stat 222
expect_rc 69 cam_owner_assert "$invocation" "$token"
fake_stat 111
expect_rc 69 cam_owner_assert "$invocation" wrong-token
cam_owner_set_lifecycle ACTIVE
cam_owner_set_lifecycle RECOVERING
cam_owner_set_lifecycle DEGRADED
cam_owner_set_lifecycle APPLYING_CONFIG
cam_owner_set_lifecycle ACTIVE
cam_owner_set_lifecycle STOPPING
expect_rc 64 cam_owner_set_lifecycle ACTIVE

owner_active
id=$(cam_request_submit gstapp_restart watcher "camera absent" /source/path 123)
uuid "$id"
jq -e --arg id "$id" '.id == $id and .source == "watcher" and .reason == "camera absent" and .source_path == "/source/path" and .source_mtime == 123' "$PIM_CAMERA_RUN_DIR/recovery/pending.json" >/dev/null || fail "pending request fields"
owner_created=$(jq -r .created_at "$PIM_CAMERA_RUN_DIR/owner.json")
jq '.created_at += 1' "$PIM_CAMERA_RUN_DIR/owner.json" > "$WORK/owner-mutated.json" && mv "$WORK/owner-mutated.json" "$PIM_CAMERA_RUN_DIR/owner.json"
expect_rc 69 cam_request_claim
[ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "created_at mismatch performed claim"
jq --argjson created "$owner_created" '.created_at=$created' "$PIM_CAMERA_RUN_DIR/owner.json" > "$WORK/owner-restored.json" && mv "$WORK/owner-restored.json" "$PIM_CAMERA_RUN_DIR/owner.json"
expect_rc 75 cam_request_submit module_reload watcher second
expect_rc 75 env PIM_CAMERA_RUN_DIR="$PIM_CAMERA_RUN_DIR" PIM_CAMERA_STATE_DIR="$PIM_CAMERA_STATE_DIR" PIM_CAMERA_BOOT_ID_FILE="$PIM_CAMERA_BOOT_ID_FILE" PIM_CAMERA_PROC_ROOT="$PIM_CAMERA_PROC_ROOT" PIM_LIB="$PIM_LIB" bash -c 'source "$PIM_LIB/cam_recovery.sh"; cam_request_submit module_reload other "second process"'
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending-2.json" ] || fail "second queue file created"
cam_request_claim
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "pending survived claim"
jq -e --arg id "$id" '.id == $id and .source == "watcher" and .reason == "camera absent"' "$PIM_CAMERA_RUN_DIR/recovery/active.json" >/dev/null || fail "claim did not preserve request"
cam_request_transition QUIESCING; cam_request_transition RUNNING
cam_action_counter_begin gstapp_restart "$id"
expect_rc 64 cam_action_counter_begin gstapp_restart "$id"
expect_rc 64 cam_action_counter_finish gstapp_restart "$id" SUCCEEDED 17
cam_action_counter_finish gstapp_restart "$id" SUCCEEDED 0
expect_rc 64 cam_request_finish SUCCEEDED 17
expect_rc 64 cam_request_finish FAILED 0
cam_request_finish SUCCEEDED 0
jq -e '.actions.gstapp_restart.attempted == 1 and .actions.gstapp_restart.succeeded == 1 and .actions.gstapp_restart.failed == 0 and .actions.gstapp_restart.consecutive_failures == 0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "success counter"
bash -c 'source "$PIM_LIB/cam_recovery.sh"; jq -e ".actions.gstapp_restart.attempted == 1" "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null' || fail "counter not persistent"
jq -e '.request.source_path == "/source/path" and .request.source_mtime == 123 and (.actions | length == 1) and .actions[0].action == "gstapp_restart" and .actions[0].status == "SUCCEEDED" and (.actions[0].started_at | numbers) and (.actions[0].finished_at | numbers) and (tostring | test("sha|generation"; "i") | not)' "$PIM_CAMERA_STATE_DIR/recovery/history/$id.json" >/dev/null || fail "history contract"

owner_active
wait_out="$WORK/wait-success.out"
"$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request gstapp_restart --source operator --reason "manual repair" --wait "$CONTROLLED_WAIT_SECONDS" >"$wait_out" &
wait_pid=$!
for _ in $(seq 1 30); do [ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && break; sleep 0.1; done
wait_id=$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/pending.json")
cam_request_claim; cam_request_transition QUIESCING; cam_request_transition RUNNING; cam_action_counter_begin gstapp_restart "$wait_id"; cam_action_counter_finish gstapp_restart "$wait_id" SUCCEEDED 0; cam_request_finish SUCCEEDED 0
wait "$wait_pid"
[ "$(cat "$wait_out")" = "CAM_RECOVERY_RESULT id=$wait_id type=gstapp_restart status=SUCCEEDED rc=0" ] || fail "success sentinel"

apply_id=$("$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" apply-config --source operator --reason "reload config")
cam_request_claim; cam_request_transition QUIESCING; cam_request_transition RUNNING; cam_request_finish SUCCEEDED 0
jq -e '.actions.gstapp_restart.attempted == 2 and .actions.module_reload.attempted == 0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "apply-config incremented an action counter"

owner_active
wait_out="$WORK/wait.out"
"$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request module_reload --source operator --reason "manual repair" --wait "$CONTROLLED_WAIT_SECONDS" >"$wait_out" &
wait_pid=$!
for _ in $(seq 1 30); do [ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && break; sleep 0.1; done
[ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "wait request not pending"
wait_id=$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/pending.json")
cam_request_claim; cam_request_transition QUIESCING; cam_request_transition RUNNING; cam_action_counter_begin module_reload "$wait_id"; cam_action_counter_finish module_reload "$wait_id" FAILED 17; cam_request_finish FAILED 17
set +e; wait "$wait_pid"; wait_rc=$?; set -e
[ "$wait_rc" -eq 17 ] || fail "wait failure rc=$wait_rc"
[ "$(cat "$wait_out")" = "CAM_RECOVERY_RESULT id=$wait_id type=module_reload status=FAILED rc=17" ] || fail "failed sentinel"
jq -e '.actions.module_reload.failed == 1 and .actions.module_reload.consecutive_failures == 1' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "first failure counter"
owner_active
second_failed=$(cam_request_submit module_reload watcher "second failure")
cam_request_claim; cam_request_transition QUIESCING; cam_request_transition RUNNING; cam_action_counter_begin module_reload "$second_failed"; cam_action_counter_finish module_reload "$second_failed" FAILED 18; cam_request_finish FAILED 18
jq -e '.actions.module_reload.failed == 2 and .actions.module_reload.consecutive_failures == 2' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "consecutive failure counter"
bash -c 'source "$PIM_LIB/cam_recovery.sh"; jq -e ".actions.module_reload.failed == 2 and .actions.module_reload.consecutive_failures == 2" "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null' || fail "failure counters not persistent"

owner_active
expect_rc 124 "$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request camera_hard_reset --source operator --reason timeout --wait 1
[ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "timeout cancelled request"
rm -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json"
rm -f "$PIM_CAMERA_RUN_DIR/owner.json"
expect_rc 69 "$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request gstapp_restart --source x --reason y
owner_active
expect_rc 64 "$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request bad --source x --reason y
expect_rc 64 "$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request apply_config --source x --reason y
expect_rc 64 "$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request gstapp_restart --source '' --reason y
expect_rc 64 "$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request gstapp_restart --source x --reason ''

bad_root="$WORK/not-a-directory"; : > "$bad_root"
expect_rc 70 env PIM_CAMERA_RUN_DIR="$bad_root" PIM_CAMERA_STATE_DIR="$PIM_CAMERA_STATE_DIR" PIM_CAMERA_BOOT_ID_FILE="$PIM_CAMERA_BOOT_ID_FILE" PIM_CAMERA_PROC_ROOT="$PIM_CAMERA_PROC_ROOT" PIM_LIB="$PIM_LIB" bash -c 'source "$PIM_LIB/cam_recovery.sh"; cam_owner_create 4242'
mkdir -p "$PIM_CAMERA_STATE_DIR/recovery/history"
cat > "$PIM_CAMERA_STATE_DIR/recovery/history/interrupted.json" <<EOF
{"request":{"id":"interrupted","type":"module_reload","status":"RUNNING","rc":null,"owner":{"boot_id":"wrong","invocation_id":"wrong","pid":4242,"proc_start_time":"111","token":"wrong"}},"actions":[]}
EOF
cam_reconcile_interrupted
jq -e '.request.status == "FAILED" and .request.interrupted == true and .request.rc != 0' "$PIM_CAMERA_STATE_DIR/recovery/history/interrupted.json" >/dev/null || fail "interrupted reconciliation"
jq -e '.dirty == true' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail "dirty service state"
before=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/interrupted.json")
cam_reconcile_interrupted
[ "$before" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/interrupted.json")" ] || fail "interrupted reconciliation repeated"

owner_active
PIM_CAMERA_TEST_OWNER_ROLLOVER=pending expect_rc 69 cam_request_submit gstapp_restart rollover "snapshot race"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "owner rollover created pending lease"

owner_active
retry_id=$(cam_request_submit apply_config fallback "ordered actions")
cam_request_claim; cam_request_transition QUIESCING; cam_request_transition RUNNING
cp "$PIM_CAMERA_RUN_DIR/owner.json" "$WORK/owner-snapshot.json"
history_before=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$retry_id.json")
state_before=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")
PIM_CAMERA_TEST_OWNER_ROLLOVER=counter_history expect_rc 69 cam_action_counter_begin module_reload "$retry_id"
[ "$history_before" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$retry_id.json")" ] || fail "rollover changed history"
[ "$state_before" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "rollover changed counter state"
cp "$WORK/owner-snapshot.json" "$PIM_CAMERA_RUN_DIR/owner.json"
PIM_CAMERA_TEST_FAILPOINT=counter_begin_after_history expect_rc 70 cam_action_counter_begin module_reload "$retry_id"
jq -e '(.actions | length) == 1 and .actions[0].action == "module_reload" and .actions[0].status == "RUNNING"' "$PIM_CAMERA_STATE_DIR/recovery/history/$retry_id.json" >/dev/null || fail "begin partial history"
cam_action_counter_begin module_reload "$retry_id"
expect_rc 64 cam_action_counter_begin module_reload "$retry_id"
cam_action_counter_finish module_reload "$retry_id" FAILED 21
cam_action_counter_begin camera_hard_reset "$retry_id"
PIM_CAMERA_TEST_FAILPOINT=counter_finish_after_history expect_rc 70 cam_action_counter_finish camera_hard_reset "$retry_id" FAILED 22
cam_action_counter_finish camera_hard_reset "$retry_id" FAILED 22
cam_action_counter_begin reboot_fallback "$retry_id"
cam_action_counter_finish reboot_fallback "$retry_id" SUCCEEDED 0
cp "$PIM_CAMERA_RUN_DIR/owner.json" "$WORK/owner-result.json"
PIM_CAMERA_TEST_OWNER_ROLLOVER=result expect_rc 69 cam_request_finish SUCCEEDED 0
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/results/$retry_id.json" ] || fail "rollover wrote result"
[ -f "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "rollover removed active lease"
cp "$WORK/owner-result.json" "$PIM_CAMERA_RUN_DIR/owner.json"
cam_request_finish SUCCEEDED 0
jq -e '[.actions[].action] == ["module_reload","camera_hard_reset","reboot_fallback"] and [.actions[].status] == ["FAILED","FAILED","SUCCEEDED"]' "$PIM_CAMERA_STATE_DIR/recovery/history/$retry_id.json" >/dev/null || fail "ordered fallback history"

owner_active
state_first_id=$(cam_request_submit apply_config partial "state first")
cam_request_claim; cam_request_transition QUIESCING; cam_request_transition RUNNING
jq --arg id "$state_first_id" --argjson now "$(date +%s)" '.actions.gstapp_restart.attempted += 1 | .actions.gstapp_restart.last_request_id=$id | .actions.gstapp_restart.last_started_at=$now | .actions.gstapp_restart.last_status="RUNNING" | .actions.gstapp_restart.last_rc=null' "$PIM_CAMERA_STATE_DIR/recovery/state.json" > "$WORK/state-first-running.json" && mv "$WORK/state-first-running.json" "$PIM_CAMERA_STATE_DIR/recovery/state.json"
attempt_before=$(jq -r .actions.gstapp_restart.attempted "$PIM_CAMERA_STATE_DIR/recovery/state.json")
cam_action_counter_begin gstapp_restart "$state_first_id"
[ "$(jq -r .actions.gstapp_restart.attempted "$PIM_CAMERA_STATE_DIR/recovery/state.json")" = "$attempt_before" ] || fail "state-first begin double incremented"
jq --arg id "$state_first_id" --argjson now "$(date +%s)" '.actions.gstapp_restart.failed += 1 | .actions.gstapp_restart.consecutive_failures += 1 | .actions.gstapp_restart.last_request_id=$id | .actions.gstapp_restart.last_finished_at=$now | .actions.gstapp_restart.last_status="FAILED" | .actions.gstapp_restart.last_rc=31' "$PIM_CAMERA_STATE_DIR/recovery/state.json" > "$WORK/state-first-finished.json" && mv "$WORK/state-first-finished.json" "$PIM_CAMERA_STATE_DIR/recovery/state.json"
failed_before=$(jq -r .actions.gstapp_restart.failed "$PIM_CAMERA_STATE_DIR/recovery/state.json")
cam_action_counter_finish gstapp_restart "$state_first_id" FAILED 31
[ "$(jq -r .actions.gstapp_restart.failed "$PIM_CAMERA_STATE_DIR/recovery/state.json")" = "$failed_before" ] || fail "state-first finish double incremented"
cam_request_finish FAILED 31

owner_active
corrupt_wait="$WORK/corrupt-wait.out"
"$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request gstapp_restart --source operator --reason corrupt --wait "$CONTROLLED_WAIT_SECONDS" >"$corrupt_wait" &
corrupt_wait_pid=$!
for _ in $(seq 1 30); do [ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && break; sleep 0.1; done
corrupt_wait_id=$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/pending.json")
mkdir -p "$PIM_CAMERA_RUN_DIR/recovery/results"
printf '{"id":"%s","type":"gstapp_restart","status":"SUCCEEDED","rc":9}\n' "$corrupt_wait_id" > "$PIM_CAMERA_RUN_DIR/recovery/results/$corrupt_wait_id.json"
set +e; wait "$corrupt_wait_pid"; corrupt_wait_rc=$?; set -e
[ "$corrupt_wait_rc" -eq 70 ] || fail "corrupt wait rc=$corrupt_wait_rc"
rm -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" "$PIM_CAMERA_RUN_DIR/recovery/results/$corrupt_wait_id.json"

owner_active
corrupt_id=$(cam_request_submit module_reload counter "corrupt state")
cam_request_claim; cam_request_transition QUIESCING; cam_request_transition RUNNING
printf '{"actions":{"gstapp_restart":{}}}\n' > "$PIM_CAMERA_STATE_DIR/recovery/state.json"
expect_rc 70 cam_action_counter_begin module_reload "$corrupt_id"
[ "$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/active.json")" = "$corrupt_id" ] || fail "corrupt state changed active lease"

echo "recovery protocol: PASS"
