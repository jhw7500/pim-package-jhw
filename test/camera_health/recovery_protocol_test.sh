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

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() { local expected=$1; shift; set +e; "$@"; local actual=$?; set -e; [ "$actual" -eq "$expected" ] || fail "expected rc=$expected, got $actual: $*"; }
uuid() { [[ $1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "not UUID: $1"; }
fake_stat() { mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"; { printf '%s' "$DAEMON_PID (cam operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' %s 0 0\n' "$1"; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"; }
owner_active() { rm -f "$PIM_CAMERA_RUN_DIR/owner.json"; cam_owner_create "$DAEMON_PID"; cam_owner_set_lifecycle ACTIVE; }

printf 'test-boot-id\n' > "$PIM_CAMERA_BOOT_ID_FILE"
fake_stat 111
# This source is intentionally the RED boundary: Task 2 has not created it yet.
source "$PIM_LIB/cam_recovery.sh"

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
"$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request gstapp_restart --source operator --reason "manual repair" --wait 3 >"$wait_out" &
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
"$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request module_reload --source operator --reason "manual repair" --wait 3 >"$wait_out" &
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
rollover_original=$(declare -f _cr_owner_lifecycle_in)
eval "${rollover_original/_cr_owner_lifecycle_in/_cr_owner_lifecycle_in_real}"
rollover_checks=0
_cr_owner_lifecycle_in() {
    rollover_checks=$((rollover_checks + 1))
    if [ "$rollover_checks" -eq 2 ]; then
        jq '.created_at += 1' "$PIM_CAMERA_RUN_DIR/owner.json" > "$WORK/rollover.json" && mv "$WORK/rollover.json" "$PIM_CAMERA_RUN_DIR/owner.json"
    fi
    _cr_owner_lifecycle_in_real "$@"
}
expect_rc 69 cam_request_submit gstapp_restart rollover "snapshot race"
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "owner rollover created pending lease"
unset -f _cr_owner_lifecycle_in _cr_owner_lifecycle_in_real
eval "$rollover_original"

owner_active
retry_id=$(cam_request_submit apply_config fallback "ordered actions")
cam_request_claim; cam_request_transition QUIESCING; cam_request_transition RUNNING
PIM_CAMERA_TEST_FAILPOINT=counter_begin_after_history expect_rc 70 cam_action_counter_begin module_reload "$retry_id"
jq -e '.actions | length == 1 and .actions[0].action == "module_reload" and .actions[0].status == "RUNNING"' "$PIM_CAMERA_STATE_DIR/recovery/history/$retry_id.json" >/dev/null || fail "begin partial history"
cam_action_counter_begin module_reload "$retry_id"
expect_rc 64 cam_action_counter_begin module_reload "$retry_id"
cam_action_counter_finish module_reload "$retry_id" FAILED 21
cam_action_counter_begin camera_hard_reset "$retry_id"
PIM_CAMERA_TEST_FAILPOINT=counter_finish_after_history expect_rc 70 cam_action_counter_finish camera_hard_reset "$retry_id" FAILED 22
cam_action_counter_finish camera_hard_reset "$retry_id" FAILED 22
cam_action_counter_begin reboot_fallback "$retry_id"
cam_action_counter_finish reboot_fallback "$retry_id" SUCCEEDED 0
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
"$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request gstapp_restart --source operator --reason corrupt --wait 3 >"$corrupt_wait" &
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
