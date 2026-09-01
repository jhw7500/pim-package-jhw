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
cam_request_transition RUNNING
expect_rc 64 cam_action_counter_begin module_reload "$id"
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
cam_request_claim; cam_request_transition RUNNING; cam_action_counter_begin gstapp_restart "$wait_id"; cam_action_counter_finish gstapp_restart "$wait_id" SUCCEEDED 0; cam_request_finish SUCCEEDED 0
wait "$wait_pid"
[ "$(cat "$wait_out")" = "CAM_RECOVERY_RESULT id=$wait_id type=gstapp_restart status=SUCCEEDED rc=0" ] || fail "success sentinel"

apply_id=$("$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" apply-config --source operator --reason "reload config")
cam_request_claim; cam_request_transition RUNNING; cam_request_finish SUCCEEDED 0
jq -e '.actions.gstapp_restart.attempted == 2 and .actions.module_reload.attempted == 0' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "apply-config incremented an action counter"

owner_active
wait_out="$WORK/wait.out"
"$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl" request module_reload --source operator --reason "manual repair" --wait 3 >"$wait_out" &
wait_pid=$!
for _ in $(seq 1 30); do [ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && break; sleep 0.1; done
[ -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] || fail "wait request not pending"
wait_id=$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/pending.json")
cam_request_claim; cam_request_transition RUNNING; cam_action_counter_begin module_reload "$wait_id"; cam_action_counter_finish module_reload "$wait_id" FAILED 17; cam_request_finish FAILED 17
set +e; wait "$wait_pid"; wait_rc=$?; set -e
[ "$wait_rc" -eq 17 ] || fail "wait failure rc=$wait_rc"
[ "$(cat "$wait_out")" = "CAM_RECOVERY_RESULT id=$wait_id type=module_reload status=FAILED rc=17" ] || fail "failed sentinel"
jq -e '.actions.module_reload.failed == 1 and .actions.module_reload.consecutive_failures == 1' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "first failure counter"
owner_active
second_failed=$(cam_request_submit module_reload watcher "second failure")
cam_request_claim; cam_request_transition RUNNING; cam_action_counter_begin module_reload "$second_failed"; cam_action_counter_finish module_reload "$second_failed" FAILED 18; cam_request_finish FAILED 18
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
corrupt_id=$(cam_request_submit module_reload counter "corrupt state")
cam_request_claim; cam_request_transition RUNNING
printf '{"actions":{"gstapp_restart":{}}}\n' > "$PIM_CAMERA_STATE_DIR/recovery/state.json"
expect_rc 70 cam_action_counter_begin module_reload "$corrupt_id"
[ "$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/active.json")" = "$corrupt_id" ] || fail "corrupt state changed active lease"

echo "recovery protocol: PASS"
