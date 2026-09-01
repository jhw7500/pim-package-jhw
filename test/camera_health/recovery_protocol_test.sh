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
    fake_stat 222
}
snapshot_terminal_bytes() {
    terminal_owner_before=$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")
    terminal_active_before=$(cksum "$PIM_CAMERA_RUN_DIR/recovery/active.json")
    terminal_history_before=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")
    terminal_result_before=$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")
    terminal_counter_before=$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")
    terminal_service_before=$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")
}
assert_terminal_bytes_unchanged() {
    local label=$1
    [ "$terminal_owner_before" = "$(cksum "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail "$label mutated owner"
    [ "$terminal_active_before" = "$(cksum "$PIM_CAMERA_RUN_DIR/recovery/active.json")" ] || fail "$label mutated active lease"
    [ "$terminal_history_before" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/history/$normal_terminal_id.json")" ] || fail "$label mutated history"
    [ "$terminal_result_before" = "$(cksum "$PIM_CAMERA_RUN_DIR/recovery/results/$normal_terminal_id.json")" ] || fail "$label mutated result"
    [ "$terminal_counter_before" = "$(cksum "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "$label mutated counters"
    [ "$terminal_service_before" = "$(cksum "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail "$label mutated service state"
}

printf 'test-boot-id\n' > "$PIM_CAMERA_BOOT_ID_FILE"
fake_stat 111
# This source is intentionally the RED boundary: Task 2 has not created it yet.
source "$PIM_LIB/cam_recovery.sh"

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
