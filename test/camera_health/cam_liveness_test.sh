#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-cam-liveness.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_RUN_DIR="$WORK/run"
export PIM_CAMERA_STATE_DIR="$WORK/state"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot-id"
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
export PIM_CAMERA_RUNTIME_JSON="$PIM_CAMERA_RUN_DIR/config/pim_runtime.json"
export PIM_CAMERA_RUNTIME_VALIDATOR="$PIM_BIN/camera_runtime_config.py"
export PIM_CAMERA_DEVICE_ROOT="$WORK/dev"
export PIM_CAMERA_BG_FLAG_FILE="$WORK/bg_chk_flag.bin"
export PIM_CAMERA_INIT_FLAG="$WORK/init_cam_flag"
export PIM_CAMERA_RESTART_FLAG="$WORK/restart_flag"
export PIM_CAMERA_CALL_LOG="$WORK/calls"
export PIM_CAMERA_LIVENESS_NOW=100
export PIM_CAMERA_V4L2_CTL=v4l2-ctl
export PIM_CAMERA_SYSTEMCTL=systemctl
export PIM_CAMERA_VCM_COMMAND=vcm
export PIM_CAMERA_LIVENESS_START_WAIT_SEC=100
EDGE_TEMPLATE="$ROOT/dist/pim/opt/pim/config/edgeconf_pim_base.json"
ORD_TEMPLATE="$ROOT/dist/pim/opt/pim/config/ord_vcm_conf.json"
DAEMON_PID=4242

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_rc() { local wanted=$1; shift; set +e; "$@"; local got=$?; set -e; [ "$got" -eq "$wanted" ] || fail "expected rc=$wanted got=$got: $*"; }
count_log() { grep -Fxc "$1" "$PIM_CAMERA_CALL_LOG" 2>/dev/null || true; }
fingerprint() { [ -e "$1" ] && cksum "$1" || printf 'absent\n'; }
reject_effects() {
    ! grep -Eq '^(restart:|start:vcm|request:)' "$PIM_CAMERA_CALL_LOG" || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "$1 performed a liveness effect"; }
}
force_tick_guard_rc() {
    local forced_rc=$1
    (
        _cl_active_guard() { return "$forced_rc"; }
        cam_liveness_tick
    )
}
monitor_config_reload() { printf 'config-reload\n' >> "$PIM_CAMERA_CALL_LOG"; }
monitor_effect_count() { grep -Ec '^(request:|restart:|start:vcm|config-reload$)' "$PIM_CAMERA_CALL_LOG" || true; }
fake_stat() {
    local start=${1:-111}
    mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"
    { printf '%s' "$DAEMON_PID (cam-operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' %s 0 0\n' "$start"; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
}
write_runtime() {
    mkdir -p "$(dirname "$PIM_CAMERA_RUNTIME_JSON")" "$PIM_CAMERA_DEVICE_ROOT"
    jq -s '
        .[1] + {VHL_CAM:.[0].VHL_CAM} |
        .VHL_CAM.capture.enable=false |
        .VHL_CAM.i2c2.ch0.enable=true |
        .VHL_CAM.i2c2.ch1.enable=false |
        .VHL_CAM.i2c1.ch2.enable=false |
        .VHL_CAM.i2c1.ch3.enable=false |
        .VHL_CAM.v4l_map={csi0_subdev:2,csi1_subdev:3}
    ' "$EDGE_TEMPLATE" "$ORD_TEMPLATE" > "$PIM_CAMERA_RUNTIME_JSON"
}
export_owner_context() {
    local owner
    owner=$(cat "$PIM_CAMERA_RUN_DIR/owner.json")
    export PIM_CAMERA_OWNER_BOOT_ID PIM_CAMERA_OWNER_INVOCATION PIM_CAMERA_OWNER_PID
    export PIM_CAMERA_OWNER_PROC_START_TIME PIM_CAMERA_OWNER_TOKEN PIM_CAMERA_OWNER_CREATED_AT
    PIM_CAMERA_OWNER_BOOT_ID=$(jq -r .boot_id <<<"$owner")
    PIM_CAMERA_OWNER_INVOCATION=$(jq -r .invocation_id <<<"$owner")
    PIM_CAMERA_OWNER_PID=$(jq -r .pid <<<"$owner")
    PIM_CAMERA_OWNER_PROC_START_TIME=$(jq -r .proc_start_time <<<"$owner")
    PIM_CAMERA_OWNER_TOKEN=$(jq -r .token <<<"$owner")
    PIM_CAMERA_OWNER_CREATED_AT=$(jq -r .created_at <<<"$owner")
}
owner_at() {
    local lifecycle=$1
    cam_owner_create "$DAEMON_PID"
    if [ "$lifecycle" != STARTING ]; then
        cam_owner_set_lifecycle ACTIVE
        [ "$lifecycle" = ACTIVE ] || cam_owner_set_lifecycle "$lifecycle"
    fi
    export_owner_context
}
reset_case() {
    rm -rf "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROC_ROOT" "$PIM_CAMERA_DEVICE_ROOT"
    mkdir -p "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROC_ROOT" "$PIM_CAMERA_DEVICE_ROOT"
    printf 'boot-a\n' > "$PIM_CAMERA_BOOT_ID_FILE"
    : > "$PIM_CAMERA_CALL_LOG"
    : > "$WORK/procs"
    rm -f "$PIM_CAMERA_BG_FLAG_FILE" "$PIM_CAMERA_INIT_FLAG" "$PIM_CAMERA_RESTART_FLAG"
    export ORD_STATE=active ORD_RESTART_RC=0 PIM_CAMERA_PGREP_ERROR= SUBDEV_RC=0 VCM_START_RC=0
    export PIM_CAMERA_V4L2_CTL=v4l2-ctl PIM_CAMERA_VCM_COMMAND=vcm
    PIM_CAMERA_LIVENESS_QUIESCED=0
    PIM_CAMERA_LIVENESS_GRACE_UNTIL=0
    PIM_CAMERA_LIVENESS_GRACE_USES=0
    export PIM_CAMERA_LIVENESS_QUIESCED PIM_CAMERA_LIVENESS_GRACE_UNTIL PIM_CAMERA_LIVENESS_GRACE_USES
    fake_stat
    write_runtime
}
set_counter() {
    local failures=$1 id=00000000-0000-4000-8000-000000000001 owner request terminal history result
    mkdir -p "$PIM_CAMERA_STATE_DIR/recovery" "$PIM_CAMERA_STATE_DIR/recovery/history" "$PIM_CAMERA_RUN_DIR/recovery/results"
    _cr_state_template | jq --argjson failures "$failures" --arg id "$id" '.actions.gstapp_restart.failed=$failures | .actions.gstapp_restart.attempted=$failures | .actions.gstapp_restart.consecutive_failures=$failures | if $failures>0 then .actions.gstapp_restart.last_request_id=$id | .actions.gstapp_restart.last_started_at=1 | .actions.gstapp_restart.last_finished_at=1 | .actions.gstapp_restart.last_status="FAILED" | .actions.gstapp_restart.last_rc=1 else . end' > "$PIM_CAMERA_STATE_DIR/recovery/state.json"
    [ "$failures" -gt 0 ] || return 0
    owner=$(cat "$PIM_CAMERA_RUN_DIR/owner.json")
    request=$(jq -cn --arg id "$id" --argjson owner "$owner" '{id:$id,type:"gstapp_restart",source:"liveness",reason:"gstapp process absent",status:"PENDING",created_at:1,owner:$owner}')
    terminal=$(jq -c '.status="FAILED" | .rc=1 | .finished_at=1' <<<"$request")
    history=$(jq -cn --argjson request "$terminal" --arg id "$id" '{request:$request,actions:[{action:"gstapp_restart",request_id:$id,status:"FAILED",started_at:1,finished_at:1,rc:1}]}')
    result=$(jq -c '{id,type,status,rc,source,reason,created_at,finished_at}' <<<"$terminal")
    printf '%s\n' "$history" > "$PIM_CAMERA_STATE_DIR/recovery/history/$id.json"
    printf '%s\n' "$result" > "$PIM_CAMERA_RUN_DIR/recovery/results/$id.json"
}
clear_leases() { rm -f "$PIM_CAMERA_RUN_DIR/recovery/pending.json" "$PIM_CAMERA_RUN_DIR/recovery/active.json"; }
prepare_gst_missing() {
    printf 'vcm\n' > "$WORK/procs"
    export ORD_STATE=active
    touch "$PIM_CAMERA_DEVICE_ROOT/video3"
    set_counter "${1:-0}"
}

mkdir -p "$WORK/stub"
cat > "$WORK/stub/systemctl" <<'SH'
#!/bin/sh
printf 'systemctl:%s\n' "$*" >> "$PIM_CAMERA_CALL_LOG"
case "$1" in
  is-active) printf '%s\n' "$ORD_STATE"; [ "$ORD_STATE" = active ] && exit 0 || [ "$ORD_STATE" = inactive ] && exit 3 || exit 4 ;;
  restart) printf 'restart:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"; exit "$ORD_RESTART_RC" ;;
  stop) printf 'stop-service:%s\n' "$2" >> "$PIM_CAMERA_CALL_LOG"; exit 0 ;;
esac
exit 64
SH
cat > "$WORK/stub/pgrep" <<'SH'
#!/bin/sh
target=
for arg; do target=$arg; done
printf 'pgrep:%s\n' "$*" >> "$PIM_CAMERA_CALL_LOG"
[ "$PIM_CAMERA_PGREP_ERROR" = "$target" ] && exit 8
grep -Fqx "$target" "$WORK/procs" 2>/dev/null
SH
cat > "$WORK/stub/v4l2-ctl" <<'SH'
#!/bin/sh
printf 'v4l2:%s\n' "$*" >> "$PIM_CAMERA_CALL_LOG"
exit "$SUBDEV_RC"
SH
cat > "$WORK/stub/vcm" <<'SH'
#!/bin/sh
printf 'start:vcm\n' >> "$PIM_CAMERA_CALL_LOG"
[ "$VCM_START_RC" -eq 0 ] || exit "$VCM_START_RC"
printf 'vcm\n' >> "$WORK/procs"
exit 0
SH
cat > "$WORK/stub/vcm-pre-exec" <<'SH'
#!/bin/sh
printf 'vcm-pre-exec\n' >> "$PIM_CAMERA_CALL_LOG"
: > "$WORK/vcm-hook-ready"
while [ ! -e "$WORK/vcm-hook-release" ]; do /bin/sleep 0.01; done
SH
cat > "$WORK/stub/vcm-slow-pre-exec" <<'SH'
#!/bin/sh
printf 'vcm-slow-pre-exec\n' >> "$PIM_CAMERA_CALL_LOG"
/bin/sleep 2
SH
cat > "$WORK/stub/logger" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$WORK/stub/sleep" <<'SH'
#!/bin/sh
/bin/sleep 0.01
SH
chmod +x "$WORK/stub"/*
export WORK PATH="$WORK/stub:$PATH"

# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery_actions.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_operate_control.sh"
_cr_fsync_file() { :; }
_cr_fsync_dir() { :; }

LIVENESS="$PIM_LIB/cam_liveness.sh"
[ -f "$LIVENESS" ] || fail "Task 5 liveness library is missing: $LIVENESS"
# shellcheck source=/dev/null
source "$LIVENESS"

eval "$(declare -f cam_request_submit | sed '1s/cam_request_submit/cam_request_submit_real/')"
cam_request_submit() {
    printf 'request:%s\n' "$1" >> "$PIM_CAMERA_CALL_LOG"
    cam_request_submit_real "$@"
}

echo '=== non-active, stale, quiesced, leased, and invalid guards ==='
for guard_rc in 69 70 75; do
    reset_case; owner_at ACTIVE
    expect_rc "$guard_rc" force_tick_guard_rc "$guard_rc"
    reject_effects "guard-rc-$guard_rc"
done
for lifecycle in STARTING APPLYING_CONFIG RECOVERING STOPPING DEGRADED; do
    reset_case; owner_at "$lifecycle"; cam_liveness_tick || :; reject_effects "$lifecycle"
done
reset_case; owner_at ACTIVE; fake_stat 222; cam_liveness_tick || :; reject_effects stale-owner
reset_case; owner_at ACTIVE; cam_liveness_quiesce; cam_liveness_tick || :; reject_effects quiesced
for lease in pending active; do
    reset_case; owner_at ACTIVE; mkdir -p "$PIM_CAMERA_RUN_DIR/recovery"; printf '{}\n' > "$PIM_CAMERA_RUN_DIR/recovery/$lease.json"; cam_liveness_tick || :; reject_effects "$lease-lease"
done
reset_case; owner_at ACTIVE; printf '{bad runtime}\n' > "$PIM_CAMERA_RUNTIME_JSON"; cam_liveness_tick || :; reject_effects invalid-runtime
reset_case; owner_at ACTIVE; printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=unknown
cam_liveness_tick || :; reject_effects ord-inspection-error
reset_case; owner_at ACTIVE; printf 'gstApp\n' > "$WORK/procs"; export PIM_CAMERA_PGREP_ERROR=vcm
cam_liveness_tick || :; reject_effects vcm-inspection-error

echo '=== exact ORD and VCM restart boundaries ==='
for effect in ord vcm request; do
    reset_case; owner_at ACTIVE
    case "$effect" in
        ord) printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=inactive ;;
        vcm) printf 'gstApp\n' > "$WORK/procs" ;;
        request) prepare_gst_missing 0 ;;
    esac
    owner_created_at=$(jq -r .created_at "$PIM_CAMERA_RUN_DIR/owner.json")
    runtime_before=$(fingerprint "$PIM_CAMERA_RUNTIME_JSON")
    state_before=$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
    PIM_CAMERA_TEST_OWNER_ROLLOVER="liveness_$effect" expect_rc 69 cam_liveness_tick
    [ "$(jq -r .created_at "$PIM_CAMERA_RUN_DIR/owner.json")" -eq $((owner_created_at + 1)) ] || fail "$effect race did not exercise created_at rollover"
    [ "$runtime_before" = "$(fingerprint "$PIM_CAMERA_RUNTIME_JSON")" ] || fail "$effect owner race mutated runtime"
    [ "$state_before" = "$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "$effect owner race mutated state"
    [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "$effect owner race created a lease"
    reject_effects "$effect-created-at-race"
done

for owner_field in boot_id invocation_id pid proc_start_time token created_at; do
    reset_case; owner_at ACTIVE; printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=inactive
    owner_field_before=$(jq -c --arg key "$owner_field" '.[$key]' "$PIM_CAMERA_RUN_DIR/owner.json")
    runtime_before=$(fingerprint "$PIM_CAMERA_RUNTIME_JSON")
    state_before=$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
    PIM_CAMERA_TEST_OWNER_ROLLOVER=liveness_ord PIM_CAMERA_TEST_OWNER_ROLLOVER_FIELD="$owner_field" expect_rc 69 cam_liveness_tick
    owner_field_after=$(jq -c --arg key "$owner_field" '.[$key]' "$PIM_CAMERA_RUN_DIR/owner.json")
    [ "$owner_field_before" != "$owner_field_after" ] || fail "$owner_field rollover hook did not mutate the immutable tuple"
    [ "$runtime_before" = "$(fingerprint "$PIM_CAMERA_RUNTIME_JSON")" ] || fail "$owner_field owner race mutated runtime"
    [ "$state_before" = "$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail "$owner_field owner race mutated state"
    [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "$owner_field owner race created a lease"
    reject_effects "$owner_field-immutable-race"
done

reset_case; owner_at ACTIVE; printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=inactive
cam_liveness_tick
[ "$(count_log restart:ord-operate.service)" -eq 1 ] || fail 'inactive ORD was not restarted exactly once'
! grep -q '^start:vcm$\|^request:' "$PIM_CAMERA_CALL_LOG" || fail 'ORD restart touched another consumer'

reset_case; owner_at ACTIVE; printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=failed
cam_liveness_tick
[ "$(count_log restart:ord-operate.service)" -eq 1 ] || fail 'failed ORD was not restarted exactly once'
! grep -q '^start:vcm$\|^request:' "$PIM_CAMERA_CALL_LOG" || fail 'failed ORD restart touched another consumer'

reset_case; owner_at ACTIVE; printf 'gstApp\n' > "$WORK/procs"
cam_liveness_tick
for _ in 1 2 3 4 5; do grep -q '^start:vcm$' "$PIM_CAMERA_CALL_LOG" && break; /bin/sleep 0.05; done
grep -q '^start:vcm$' "$PIM_CAMERA_CALL_LOG" || fail 'missing VCM was not started through its exact launcher'
! grep -q '^restart:' "$PIM_CAMERA_CALL_LOG" || fail 'VCM restart touched ORD'

echo '=== VCM crosses launch readiness while the parent retains the lock ==='
reset_case; owner_at ACTIVE; printf 'gstApp\n' > "$WORK/procs"
rm -f "$WORK/vcm-hook-ready" "$WORK/vcm-hook-release"
export PIM_CAMERA_TEST_VCM_PRE_EXEC_HOOK="$WORK/stub/vcm-pre-exec"
sleep() { /bin/sleep "$@"; }
cam_liveness_tick & vcm_tick_pid=$!
for _ in $(seq 1 100); do [ ! -e "$WORK/vcm-hook-ready" ] || break; /bin/sleep 0.01; done
[ -e "$WORK/vcm-hook-ready" ] || { wait "$vcm_tick_pid" 2>/dev/null || :; fail 'VCM pre-exec boundary hook was not reached'; }
expect_rc 75 cam_owner_set_lifecycle STOPPING
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = ACTIVE ] || fail 'STOPPING crossed the parent-held VCM launch lock'
: > "$WORK/vcm-hook-release"
wait "$vcm_tick_pid"
unset -f sleep
cam_owner_set_lifecycle STOPPING
printf 'stopping-durable\n' >> "$PIM_CAMERA_CALL_LOG"
start_line=$(grep -n '^start:vcm$' "$PIM_CAMERA_CALL_LOG" | cut -d: -f1)
stop_line=$(grep -n '^stopping-durable$' "$PIM_CAMERA_CALL_LOG" | cut -d: -f1)
[ -n "$start_line" ] && [ "$start_line" -lt "$stop_line" ] || fail 'STOPPING became durable before VCM crossed exec'
unset PIM_CAMERA_TEST_VCM_PRE_EXEC_HOOK

echo '=== guarded VCM startup tolerates target latency by default ==='
reset_case; owner_at ACTIVE; printf 'gstApp\n' > "$WORK/procs"
slow_vcm_rc=0
(
    unset PIM_CAMERA_LIVENESS_START_WAIT_SEC
    # shellcheck source=/dev/null
    source "$LIVENESS"
    export PIM_CAMERA_TEST_VCM_PRE_EXEC_HOOK="$WORK/stub/vcm-slow-pre-exec"
    sleep() { /bin/sleep "$@"; }
    tick_rc=0
    cam_liveness_tick || tick_rc=$?
    wait || :
    exit "$tick_rc"
) || slow_vcm_rc=$?
slow_vcm_lifecycle=$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")
if [ "$slow_vcm_rc" -ne 0 ] || [ "$slow_vcm_lifecycle" != ACTIVE ]; then
    printf 'VCM_START_WAIT_RED: rc=%s lifecycle=%s\n' "$slow_vcm_rc" "$slow_vcm_lifecycle" >&2
    fail 'guarded VCM startup exceeded the default liveness wait'
fi
grep -q '^start:vcm$' "$PIM_CAMERA_CALL_LOG" || fail 'guarded VCM did not become visible within the default wait'

echo '=== ORD and VCM start failure degrade only their target ==='
reset_case; owner_at ACTIVE; printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=inactive ORD_RESTART_RC=23
PIM_CAMERA_TEST_OWNER_ROLLOVER=liveness_degraded expect_rc 69 cam_liveness_tick
[ ! -e "$PIM_CAMERA_STATE_DIR/service-state.json" ] || fail 'owner rollover before degraded mutation wrote service state'
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = ACTIVE ] || fail 'owner rollover before degraded mutation changed lifecycle'
! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'owner rollover before degraded mutation requested recovery'

reset_case; owner_at ACTIVE; printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=inactive ORD_RESTART_RC=23
printf '{malformed service state}\n' > "$PIM_CAMERA_STATE_DIR/service-state.json"
malformed_service_before=$(fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")
expect_rc 70 cam_liveness_tick
[ "$malformed_service_before" = "$(fingerprint "$PIM_CAMERA_STATE_DIR/service-state.json")" ] || fail 'malformed service-state inspection was overwritten'
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = ACTIVE ] || fail 'malformed service-state inspection degraded owner'

reset_case; owner_at ACTIVE; printf 'vcm\ngstApp\n' > "$WORK/procs"; export ORD_STATE=inactive ORD_RESTART_RC=23
expect_rc 23 cam_liveness_tick
jq -e '.degraded_target=="ord" and .degraded_reason=="liveness_start_failed"' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail 'ORD failure did not persist exact degraded target'
reject_effects_without_restarts=$(grep '^request:' "$PIM_CAMERA_CALL_LOG" 2>/dev/null || true); [ -z "$reject_effects_without_restarts" ] || fail 'ORD failure requested camera recovery'

reset_case; owner_at ACTIVE; printf 'gstApp\n' > "$WORK/procs"; export PIM_CAMERA_VCM_COMMAND=missing-vcm-command
expect_rc 127 cam_liveness_tick
jq -e '.degraded_target=="vcm" and .degraded_reason=="liveness_start_failed"' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail 'VCM failure did not persist exact degraded target'
! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'VCM failure requested camera recovery'

reset_case; owner_at ACTIVE; printf 'gstApp\n' > "$WORK/procs"; export VCM_START_RC=23
expect_rc 1 cam_liveness_tick
jq -e '.degraded_target=="vcm" and .degraded_reason=="liveness_start_failed"' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null || fail 'immediate VCM exit was not degraded'
! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'immediate VCM exit requested camera recovery'

echo '=== gstApp gates, exact process match, and persistent threshold ==='
reset_case; owner_at ACTIVE; prepare_gst_missing 0
jq '.actions.gstapp_restart.consecutive_failures=5' "$PIM_CAMERA_STATE_DIR/recovery/state.json" > "$WORK/state.impossible" && mv "$WORK/state.impossible" "$PIM_CAMERA_STATE_DIR/recovery/state.json"
impossible_owner_before=$(fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")
impossible_runtime_before=$(fingerprint "$PIM_CAMERA_RUNTIME_JSON")
impossible_state_before=$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
expect_rc 70 cam_liveness_tick
[ "$impossible_owner_before" = "$(fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail 'impossible gstApp counter mutated owner'
[ "$impossible_runtime_before" = "$(fingerprint "$PIM_CAMERA_RUNTIME_JSON")" ] || fail 'impossible gstApp counter mutated runtime'
[ "$impossible_state_before" = "$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail 'impossible gstApp counter mutated state'
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail 'impossible gstApp counter created a lease'
! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'impossible gstApp counter called request submission'

reset_case; owner_at ACTIVE; prepare_gst_missing 0
jq '.VHL_CAM.i2c2.ch0.enable=false' "$PIM_CAMERA_RUNTIME_JSON" > "$WORK/runtime.next" && mv "$WORK/runtime.next" "$PIM_CAMERA_RUNTIME_JSON"
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'all-disabled runtime requested gstApp recovery'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; printf '3\n' > "$PIM_CAMERA_BG_FLAG_FILE"
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'disconnect requested gstApp recovery'

reset_case; owner_at ACTIVE; printf 'vcm\n' > "$WORK/procs"; set_counter 0
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'missing video node requested gstApp recovery'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; export SUBDEV_RC=1
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'unready subdev requested gstApp recovery'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; touch "$PIM_CAMERA_INIT_FLAG"
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'init flag requested gstApp recovery'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; touch "$PIM_CAMERA_RESTART_FLAG"; export SUBDEV_RC=1
cam_liveness_tick; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'active restart flag requested gstApp recovery'
rm -f "$PIM_CAMERA_RESTART_FLAG"
cam_liveness_tick; clear_leases
cam_liveness_tick; clear_leases
cam_liveness_tick
[ "$(count_log request:gstapp_restart)" -eq 2 ] || fail 'restart grace did not permit exactly two subdev bypasses'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; export PIM_CAMERA_V4L2_CTL=missing-v4l2-tool
cam_liveness_tick
[ "$(count_log request:gstapp_restart)" -eq 1 ] || fail 'absent v4l2-ctl did not preserve permissive gate'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; printf 'gstApp-helper\n' >> "$WORK/procs"
cam_liveness_tick
[ "$(count_log request:gstapp_restart)" -eq 1 ] || fail 'substring process match suppressed exact gstApp recovery'
clear_leases; : > "$PIM_CAMERA_CALL_LOG"; printf 'gstApp\n' >> "$WORK/procs"
cam_liveness_tick
! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'exact gstApp match created a duplicate request'

reset_case; owner_at ACTIVE; prepare_gst_missing 4
runtime_before=$(cksum "$PIM_CAMERA_RUNTIME_JSON")
cam_liveness_tick
[ "$(count_log request:gstapp_restart)" -eq 1 ] || fail 'below threshold did not request gstapp_restart'
[ "$runtime_before" = "$(cksum "$PIM_CAMERA_RUNTIME_JSON")" ] || fail 'liveness rebuilt or overwrote the fixed runtime'
clear_leases; : > "$PIM_CAMERA_CALL_LOG"; set_counter 5
cam_liveness_tick
[ "$(count_log request:module_reload)" -eq 1 ] || fail 'threshold 5 did not request module_reload'

clear_leases; : > "$PIM_CAMERA_CALL_LOG"; set_counter 2; PIM_CAMERA_LIVENESS_ESCALATION_THRESHOLD=2
cam_liveness_tick
[ "$(count_log request:module_reload)" -eq 1 ] || fail 'test-overridden escalation threshold was ignored'
PIM_CAMERA_LIVENESS_ESCALATION_THRESHOLD=5

reset_case; owner_at ACTIVE; prepare_gst_missing 5; printf '{invalid}\n' > "$PIM_CAMERA_RUNTIME_JSON"
cam_liveness_tick || :; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'invalid runtime escalated'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; mkdir -p "$PIM_CAMERA_RUN_DIR/recovery"; printf '{}\n' > "$PIM_CAMERA_RUN_DIR/recovery/pending.json"
cam_liveness_tick || :; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'existing lease created another request'

reset_case; owner_at ACTIVE; prepare_gst_missing 0; export PIM_CAMERA_PGREP_ERROR=gstApp
cam_liveness_tick || :; ! grep -q '^request:' "$PIM_CAMERA_CALL_LOG" || fail 'gstApp inspection error was treated as absence'

echo '=== liveness gstApp failures remain retryable until module escalation ==='
cam_action_gstapp_restart() { return 23; }
reset_case; owner_at ACTIVE; prepare_gst_missing 0
for failure in 1 2 3 4 5; do
    cam_liveness_tick
    jq -e '.type=="gstapp_restart" and .source=="liveness" and .reason=="gstapp process absent"' "$PIM_CAMERA_RUN_DIR/recovery/pending.json" >/dev/null || fail "liveness failure $failure did not submit exact gstApp request"
    cam_request_claim
    if [ "$failure" -eq 1 ]; then
        PIM_CAMERA_TEST_FAILPOINT=retryable_liveness_before_finish expect_rc 70 cam_execute_pending_request
        request_id=$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/active.json")
        history_file="$PIM_CAMERA_STATE_DIR/recovery/history/$request_id.json"
        result_file="$PIM_CAMERA_RUN_DIR/recovery/results/$request_id.json"
        jq -e '.status=="RUNNING" and (has("rc")|not) and (has("finished_at")|not)' "$PIM_CAMERA_RUN_DIR/recovery/active.json" >/dev/null || fail 'retry failpoint wrote a nonterminal FAILED request'
        jq -e '.request.status=="RUNNING" and (.actions[-1].status=="FAILED") and (.actions[-1].rc==23)' "$history_file" >/dev/null || fail 'retry failpoint did not preserve the recoverable RUNNING/terminal-action pair'
        [ ! -e "$result_file" ] || fail 'retry failpoint published a premature request result'

        cp "$history_file" "$WORK/retry-history.valid"
        jq '.actions[-1].rc=24' "$history_file" > "$WORK/retry-history.invalid" && mv "$WORK/retry-history.invalid" "$history_file"
        retry_active_before=$(fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")
        retry_owner_before=$(fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")
        retry_state_before=$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
        retry_history_before=$(fingerprint "$history_file")
        retry_result_before=$(fingerprint "$result_file")
        expect_rc 70 _coc_fail_retryable_liveness_gstapp 23
        [ "$retry_active_before" = "$(fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")" ] || fail 'invalid retry evidence mutated active request'
        [ "$retry_owner_before" = "$(fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail 'invalid retry evidence mutated owner'
        [ "$retry_state_before" = "$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail 'invalid retry evidence mutated counters'
        [ "$retry_history_before" = "$(fingerprint "$history_file")" ] || fail 'invalid retry evidence mutated history'
        [ "$retry_result_before" = "$(fingerprint "$result_file")" ] || fail 'invalid retry evidence published a result'
        cp "$WORK/retry-history.valid" "$history_file"

        printf '{malformed result}\n' > "$result_file"
        retry_active_before=$(fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")
        retry_owner_before=$(fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")
        retry_state_before=$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
        retry_history_before=$(fingerprint "$history_file")
        retry_result_before=$(fingerprint "$result_file")
        expect_rc 70 _coc_fail_retryable_liveness_gstapp 23
        [ "$retry_active_before" = "$(fingerprint "$PIM_CAMERA_RUN_DIR/recovery/active.json")" ] || fail 'malformed result mutated active request'
        [ "$retry_owner_before" = "$(fingerprint "$PIM_CAMERA_RUN_DIR/owner.json")" ] || fail 'malformed result mutated owner'
        [ "$retry_state_before" = "$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail 'malformed result mutated counters'
        [ "$retry_history_before" = "$(fingerprint "$history_file")" ] || fail 'malformed result mutated history'
        [ "$retry_result_before" = "$(fingerprint "$result_file")" ] || fail 'malformed result was overwritten'

        retry_terminal=$(jq -c '.status="FAILED" | .rc=23 | .finished_at=100' "$PIM_CAMERA_RUN_DIR/recovery/active.json")
        retry_result=$(jq -c '{id,type,status,rc,source,reason,created_at,finished_at}' <<<"$retry_terminal")
        printf '%s\n' "$retry_result" > "$result_file"
        retry_result_before=$(fingerprint "$result_file")
        expect_rc 23 _coc_fail_retryable_liveness_gstapp 23
        [ "$retry_result_before" = "$(fingerprint "$result_file")" ] || fail 'exact result-first retry rewrote result evidence'
        jq -e '.request.status=="FAILED" and .request.rc==23 and .request.finished_at==100' "$history_file" >/dev/null || fail 'exact result-first retry did not complete history from result'
    elif [ "$failure" -eq 2 ]; then
        PIM_CAMERA_TEST_FAILPOINT=retryable_liveness_after_finish expect_rc 70 cam_execute_pending_request
        request_id=$(jq -r '.actions.gstapp_restart.last_request_id' "$PIM_CAMERA_STATE_DIR/recovery/state.json")
        history_file="$PIM_CAMERA_STATE_DIR/recovery/history/$request_id.json"
        result_file="$PIM_CAMERA_RUN_DIR/recovery/results/$request_id.json"
        [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail 'post-finish failpoint retained active lease'
        [ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = RECOVERING ] || fail 'post-finish failpoint did not preserve RECOVERING owner'
        repair_state_before=$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")
        repair_history_before=$(fingerprint "$history_file")
        repair_result_before=$(fingerprint "$result_file")
        printf 'vcm\ngstApp\n' > "$WORK/procs"
        monitor_effects_before=$(monitor_effect_count)
        monitor_liveness_before=$(grep -c '^systemctl:is-active ord-operate.service$' "$PIM_CAMERA_CALL_LOG" || true)
        expect_rc 0 cam_monitor_control_iteration monitor_config_reload
        [ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = ACTIVE ] || fail 'same-process next loop did not repair owner ACTIVE'
        [ "$repair_state_before" = "$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail 'same-process repair duplicated counter write'
        [ "$repair_history_before" = "$(fingerprint "$history_file")" ] || fail 'same-process repair duplicated history write'
        [ "$repair_result_before" = "$(fingerprint "$result_file")" ] || fail 'same-process repair duplicated result write'
        [ "$monitor_effects_before" = "$(monitor_effect_count)" ] || fail 'same-process monitor repair created an action or reloaded config'
        [ "$(grep -c '^systemctl:is-active ord-operate.service$' "$PIM_CAMERA_CALL_LOG" || true)" -gt "$monitor_liveness_before" ] || fail 'same-process monitor repair did not make ACTIVE liveness eligible'
        [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail 'same-process monitor repair created a lease'

        cam_owner_set_lifecycle RECOVERING
        unset PIM_CAMERA_OWNER_BOOT_ID PIM_CAMERA_OWNER_INVOCATION PIM_CAMERA_OWNER_PID
        unset PIM_CAMERA_OWNER_PROC_START_TIME PIM_CAMERA_OWNER_TOKEN PIM_CAMERA_OWNER_CREATED_AT
        _coc_export_owner_context
        monitor_effects_before=$(monitor_effect_count)
        monitor_liveness_before=$(grep -c '^systemctl:is-active ord-operate.service$' "$PIM_CAMERA_CALL_LOG" || true)
        set +e
        PIM_CAMERA_TEST_MONITOR_ONCE=1 \
        PIM_CAMERA_TEST_MONITOR_RELOAD_TRACE="$PIM_CAMERA_CALL_LOG" \
            /usr/bin/timeout 10 bash "$PIM_BIN/chk_cam_operate.sh"
        daemon_loop_rc=$?
        set -e
        daemon_loop_lifecycle=$(jq -r '.lifecycle // empty' "$PIM_CAMERA_RUN_DIR/owner.json")
        if [ "$daemon_loop_rc" -ne 0 ] || [ "$daemon_loop_lifecycle" != ACTIVE ]; then
            printf 'ROUND3_RED: daemon_callsite_rc=%s lifecycle=%s\n' "$daemon_loop_rc" "$daemon_loop_lifecycle" >&2
            fail 'actual daemon monitor callsite did not repair the no-pending partial'
        fi
        [ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = ACTIVE ] || fail 'restarted-loop repair did not restore owner ACTIVE'
        [ "$repair_state_before" = "$(fingerprint "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] || fail 'restarted-loop repair duplicated counter write'
        [ "$repair_history_before" = "$(fingerprint "$history_file")" ] || fail 'restarted-loop repair duplicated history write'
        [ "$repair_result_before" = "$(fingerprint "$result_file")" ] || fail 'restarted-loop repair duplicated result write'
        [ "$monitor_effects_before" = "$(monitor_effect_count)" ] || fail 'restarted-loop monitor repair created an action or reloaded config'
        [ "$(grep -c '^systemctl:is-active ord-operate.service$' "$PIM_CAMERA_CALL_LOG" || true)" -gt "$monitor_liveness_before" ] || fail 'restarted-loop monitor repair did not make ACTIVE liveness eligible'
        [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail 'restarted-loop monitor repair created a lease'
        monitor_effects_before=$(monitor_effect_count)
        expect_rc 1 cam_monitor_control_iteration monitor_config_reload
        [ -z "${PIM_CAMERA_MONITOR_WORK_TYPE:-}" ] || fail 'post-repair no-work iteration retained stale work type'
        [ "$monitor_effects_before" = "$(monitor_effect_count)" ] || fail 'post-repair no-work iteration reused repair work'
        printf 'vcm\n' > "$WORK/procs"
    else
        expect_rc 23 cam_execute_pending_request
    fi
    jq -e --argjson failure "$failure" '.actions.gstapp_restart.failed==$failure and .actions.gstapp_restart.consecutive_failures==$failure and .actions.gstapp_restart.last_status=="FAILED" and .actions.gstapp_restart.last_rc==23' "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null || fail "liveness failure $failure was not countered exactly"
    [ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = ACTIVE ] || fail "liveness failure $failure made the owner terminal"
    [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] || fail "liveness failure $failure retained a lease"
done
cam_liveness_tick
jq -e '.type=="module_reload" and .source=="liveness" and .reason=="gstapp process absent"' "$PIM_CAMERA_RUN_DIR/recovery/pending.json" >/dev/null || fail 'five actual gstApp failures did not escalate the next tick to module_reload'

reset_case; owner_at ACTIVE; prepare_gst_missing 0
cam_request_submit gstapp_restart legacy-restart-app legacy-wrapper >/dev/null
cam_request_claim
expect_rc 23 cam_execute_pending_request
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = DEGRADED ] || fail 'legacy gstApp failure did not remain terminal DEGRADED'

cam_action_module_reload() { return 24; }
cam_action_camera_hard_reset() { return 24; }
cam_action_reboot_fallback() { return 24; }
reset_case; owner_at ACTIVE; prepare_gst_missing 5
cam_liveness_tick
jq -e '.type=="module_reload" and .source=="liveness"' "$PIM_CAMERA_RUN_DIR/recovery/pending.json" >/dev/null || fail 'non-gst liveness case did not submit module_reload'
cam_request_claim
expect_rc 24 cam_execute_pending_request
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = DEGRADED ] || fail 'non-gst liveness failure did not remain terminal DEGRADED'

echo '=== one-pass compatibility shim is finite ==='
cat > "$WORK/stub/recoveryctl" <<'SH'
#!/bin/sh
printf 'shim:%s\n' "$*" >> "$PIM_CAMERA_CALL_LOG"
exit 0
SH
chmod +x "$WORK/stub/recoveryctl"
PIM_CAMERA_RECOVERYCTL="$WORK/stub/recoveryctl" timeout 2 bash "$PIM_BIN/restart_app.sh"
[ "$(count_log 'shim:request gstapp_restart --source legacy-restart-app --reason legacy-wrapper --wait 120')" -eq 1 ] || fail 'restart_app shim did not forward exactly once'

echo 'cam liveness: PASS'
