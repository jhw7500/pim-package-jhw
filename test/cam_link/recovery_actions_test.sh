#!/usr/bin/env bash
# Executor contract: runs only against command/sysfs stubs.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-recovery-actions.XXXXXX")
export WORK
trap 'rm -rf "$WORK"' EXIT
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_RUN_DIR="$WORK/run"
export PIM_CAMERA_STATE_DIR="$WORK/state"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot-id"
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
export PIM_CAMERA_RUNTIME_JSON="$WORK/run/config/pim_runtime.json"
export PIM_CAMERA_SOURCE_ROOT="$WORK/source"
export PIM_CAMERA_RUNTIME_HELPER="$PIM_BIN/camera_runtime_config.py"
export PIM_CAMERA_CONTROL_WORK_DIR="$PIM_CAMERA_RUN_DIR/control"
export PIM_CAMERA_SYSFS_ROOT="$WORK/sys"
export PIM_CAMERA_DEVICE_ROOT="$WORK/dev"
export PIM_CAMERA_CALL_LOG="$WORK/calls"
export PIM_CAMERA_START_CAM="$WORK/start-cam"
export PIM_CAMERA_SHM_DIR="$WORK/shm"
export PIM_CAMERA_PROCESS_ROOT="$WORK/processes"
DAEMON_PID=4242

fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { "$@" || fail "command failed: $*"; }
expect_rc() { local wanted=$1; shift; set +e; "$@"; local got=$?; set -e; [ "$got" = "$wanted" ] || fail "expected rc=$wanted got=$got: $*"; }
fake_stat() { mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"; { printf '%s' "$DAEMON_PID (cam-operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' 111 0 0\n'; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"; }
runtime() { mkdir -p "$(dirname "$PIM_CAMERA_RUNTIME_JSON")"; printf '%s\n' '{"VHL_CAM":{"app":"gstApp","capture":{"enable":false},"tmp_path":"'"$WORK"'/recordings","vhl_name":"VD3001"},"ORD":{},"VCM":{}}' > "$PIM_CAMERA_RUNTIME_JSON"; mkdir -p "$WORK/recordings"; printf '%s\n' '20260901 12:34:56' > "$WORK/start-time"; export PIM_CAMERA_SESSION_TIME_FILE="$WORK/start-time"; }
owner_active() { rm -f "$PIM_CAMERA_RUN_DIR/owner.json"; cam_owner_create "$DAEMON_PID"; cam_owner_set_lifecycle ACTIVE; }
prepare_sysfs() {
    local d
    for d in mxc-mipi-csi2-sam mxc-isi isi-capture isi-m2m; do mkdir -p "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d"; : > "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d/unbind"; : > "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d/bind"; done
    mkdir -p "$PIM_CAMERA_DEVICE_ROOT"; : > "$PIM_CAMERA_DEVICE_ROOT/video3"; : > "$PIM_CAMERA_DEVICE_ROOT/video4"
    mkdir -p "$PIM_CAMERA_SHM_DIR"
}
prepare_stubs() {
    mkdir -p "$WORK/stub"; : > "$PIM_CAMERA_CALL_LOG"
    for cmd in rmmod modprobe reboot logger sleep; do
        printf '#!/bin/sh\nprintf "%%s %%s\\n" "$(basename "$0")" "$*" >> "$PIM_CAMERA_CALL_LOG"\n[ "$(basename "$0")" = modprobe ] && [ "$1" = "${FAIL_MODPROBE:-}" ] && exit 23\nexit 0\n' > "$WORK/stub/$cmd"
        chmod +x "$WORK/stub/$cmd"
    done
    printf '#!/bin/sh\nprintf "kill %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\n[ "${KEEP_BG:-0}" = 1 ] || rm -f "$PIM_CAMERA_PROCESS_ROOT/$2/cmdline"\nexit 0\n' > "$WORK/stub/kill"
    chmod +x "$WORK/stub/kill"
    printf '#!/bin/sh\nlast=\nfor arg; do last=$arg; done\nprintf "pgrep %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\ngrep -Fqx "$last" "$WORK/procs" 2>/dev/null\n' > "$WORK/stub/pgrep"
    printf '#!/bin/sh\nlast=\nfor arg; do last=$arg; done\nprintf "pkill %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\ngrep -Fvx "$last" "$WORK/procs" > "$WORK/procs.next" 2>/dev/null || :\nmv "$WORK/procs.next" "$WORK/procs"\ncase "$last" in *BG_Check_for_pim.sh) rm -f "$PIM_CAMERA_PROCESS_ROOT"/*/cmdline;; esac\n' > "$WORK/stub/pkill"
    printf '#!/bin/sh\nprintf "lsmod\\n" >> "$PIM_CAMERA_CALL_LOG"\nprintf "%%s\\n" "${LSMOD_ROWS:-}"\nexit 0\n' > "$WORK/stub/lsmod"
    printf '#!/bin/sh\nprintf "start_cam\\n" >> "$PIM_CAMERA_CALL_LOG"\nprintf "gstApp\\n" >> "$WORK/procs"\nmkdir -p "$PIM_CAMERA_PROCESS_ROOT/100"\nprintf "%%s" "100 (BG_Check_for_pim) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1000 0" > "$PIM_CAMERA_PROCESS_ROOT/100/stat"\nprintf "/bin/bash\\000'"$PIM_BIN"'/BG_Check_for_pim.sh\\0004\\000" > "$PIM_CAMERA_PROCESS_ROOT/100/cmdline"\nexit 0\n' > "$PIM_CAMERA_START_CAM"
    for cmd in ord vcm; do printf '#!/bin/sh\nprintf "start %%s\\n" "$(basename "$0")" >> "$PIM_CAMERA_CALL_LOG"\nprintf "%%s\\n" "$(basename "$0")" >> "$WORK/procs"\n' > "$WORK/stub/$cmd"; chmod +x "$WORK/stub/$cmd"; done
    chmod +x "$WORK/stub/pgrep" "$WORK/stub/pkill" "$WORK/stub/lsmod" "$PIM_CAMERA_START_CAM"
    export PATH="$WORK/stub:$PATH"
}

printf 'boot\n' > "$PIM_CAMERA_BOOT_ID_FILE"
fake_stat
prepare_stubs
enable -n kill
export PIM_CAMERA_BG_CHECKER="$PIM_BIN/BG_Check_for_pim.sh"
printf 'gstApp\n%s\n' "$PIM_CAMERA_BG_CHECKER" > "$WORK/procs"
mkdir -p "$PIM_CAMERA_PROCESS_ROOT/99"
printf '%s' '99 (BG_Check_for_pim) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999 0' > "$PIM_CAMERA_PROCESS_ROOT/99/stat"
printf '/bin/bash\000%s\0004\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/99/cmdline"
prepare_sysfs
runtime
# This is the RED boundary: Task 3 must provide the only action executor.
source "$PIM_LIB/cam_recovery.sh"
source "$PIM_LIB/cam_recovery_actions.sh"
source "$PIM_LIB/cam_operate_control.sh"
# Protocol durability is covered separately; avoid repeated disk flush latency here.
_cr_fsync_file() { :; }
_cr_fsync_dir() { :; }

owner_active
expect cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" gstapp_restart test "restart"
grep -q '^pkill .*gstApp' "$PIM_CAMERA_CALL_LOG" || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "gstapp restart did not quiesce app"; }
grep -q '^kill -TERM 99$' "$PIM_CAMERA_CALL_LOG" || fail "gstapp restart did not quiesce BG child by exact argv identity"
grep -q '^start_cam$' "$PIM_CAMERA_CALL_LOG" || fail "gstapp restart did not use internal launcher"

echo "=== degraded camera-health apply uses one real full quiesce ==="
mkdir -p "$PIM_CAMERA_SOURCE_ROOT"
cat > "$PIM_CAMERA_SOURCE_ROOT/edgeconf_apply.json" <<JSON
{"VHL_CAM":{"app":"gstApp","capture":{"enable":false},"tmp_path":"$WORK/recordings","vhl_name":"VD3001"}}
JSON
cat > "$PIM_CAMERA_SOURCE_ROOT/ord_vcm_conf.json" <<'JSON'
{"ORD":{},"VCM":{},"ETC":{"policy":"same"}}
JSON
python3 "$PIM_CAMERA_RUNTIME_HELPER" stage --source-root "$PIM_CAMERA_SOURCE_ROOT" --candidate "$WORK/candidate.json" --result "$WORK/source.json" >/dev/null
python3 "$PIM_CAMERA_RUNTIME_HELPER" publish --candidate "$WORK/candidate.json" --runtime-dir "$(dirname "$PIM_CAMERA_RUNTIME_JSON")" >/dev/null
python3 "$PIM_CAMERA_RUNTIME_HELPER" projection --file "$PIM_CAMERA_RUNTIME_JSON" --output "$WORK/projection.json" >/dev/null
projection=$(cat "$WORK/projection.json")
boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE")
invocation=$(jq -r .invocation_id "$PIM_CAMERA_RUN_DIR/owner.json")
jq -cn --arg boot "$boot" --arg invocation "$invocation" --argjson projection "$projection" '{schema:1,last_boot_id:$boot,last_successful_hardware_projection:$projection,dirty:false,degraded_reason:"camera unhealthy",degraded_target:"camera_health",last_invocation_id:$invocation}' > "$PIM_CAMERA_STATE_DIR/service-state.json"
cam_owner_set_lifecycle DEGRADED
printf 'ord\nvcm\n' >> "$WORK/procs"
eval "$(declare -f cam_quiesce_consumers | sed '1s/cam_quiesce_consumers/cam_quiesce_consumers_real/')"
cam_quiesce_consumers() {
    local rc=0
    printf 'quiesce-all-begin\n' >> "$PIM_CAMERA_CALL_LOG"
    cam_quiesce_consumers_real "$@" || rc=$?
    [ "$rc" -eq 0 ] && printf 'quiesce-all-complete\n' >> "$PIM_CAMERA_CALL_LOG"
    return "$rc"
}
eval "$(declare -f _coc_verify_all | sed '1s/_coc_verify_all/_coc_verify_all_real/')"
_coc_verify_all() {
    _coc_verify_all_real "$@" || return $?
    printf 'final-verify\n' >> "$PIM_CAMERA_CALL_LOG"
}
export LSMOD_ROWS=$'max9296 1 0\nimx8_media_dev 1 0'
: > "$PIM_CAMERA_CALL_LOG"
apply_id=$(cam_request_submit apply_config test "degraded camera repair")
cam_poll_pending_request
[ "$(grep -c '^quiesce-all-begin$' "$PIM_CAMERA_CALL_LOG")" -eq 1 ] || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "module apply did not invoke exactly one full quiesce"; }
[ "$(grep -c '^quiesce-all-complete$' "$PIM_CAMERA_CALL_LOG")" -eq 1 ] || fail "module apply did not confirm all consumers stopped"
quiesce_line=$(grep -n '^quiesce-all-complete$' "$PIM_CAMERA_CALL_LOG" | cut -d: -f1)
module_line=$(grep -n -m1 -E '^(rmmod|modprobe) ' "$PIM_CAMERA_CALL_LOG" | cut -d: -f1)
start_line=$(grep -n -m1 -E '^(start ord|start vcm|start_cam)$' "$PIM_CAMERA_CALL_LOG" | cut -d: -f1)
verify_line=$(grep -n '^final-verify$' "$PIM_CAMERA_CALL_LOG" | tail -1 | cut -d: -f1)
[ "$quiesce_line" -lt "$module_line" ] && [ "$module_line" -lt "$start_line" ] && [ "$start_line" -lt "$verify_line" ] || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "module apply order was not quiesce -> module -> restart -> final verify"; }
jq -e --arg id "$apply_id" '.id==$id and .status=="SUCCEEDED" and .rc==0' "$PIM_CAMERA_RUN_DIR/recovery/results/$apply_id.json" >/dev/null || fail "module apply result"

cam_owner_set_lifecycle DEGRADED
jq '.degraded_reason="camera unhealthy" | .degraded_target="camera_health" | .dirty=false' "$PIM_CAMERA_STATE_DIR/service-state.json" > "$WORK/service.next" && mv "$WORK/service.next" "$PIM_CAMERA_STATE_DIR/service-state.json"
: > "$PIM_CAMERA_CALL_LOG"
export KEEP_BG=1 PIM_CAMERA_CONSUMERS_QUIESCED=1
failed_apply_id=$(cam_request_submit apply_config test "quiesce must fail closed")
expect_rc 1 cam_poll_pending_request
unset KEEP_BG PIM_CAMERA_CONSUMERS_QUIESCED
grep -q '^quiesce-all-begin$' "$PIM_CAMERA_CALL_LOG" || fail "forged pre-quiesced apply skipped real quiesce"
! grep -Eq '^(rmmod|modprobe) ' "$PIM_CAMERA_CALL_LOG" || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail "quiesce failure allowed module effect"; }
jq -e --arg id "$failed_apply_id" '.id==$id and .status=="FAILED" and .rc>0' "$PIM_CAMERA_RUN_DIR/recovery/results/$failed_apply_id.json" >/dev/null || fail "quiesce failure result"
# The first request proves the full lease guard before process side effects.  The
# remaining stub-only order cases do not need to re-run its expensive tuple reads.
cam_executor_assert_context() { return 0; }

echo "=== hardware recovery preserves target settle windows ==="
settle_fail=0
owner_active
: > "$PIM_CAMERA_CALL_LOG"
expect cam_module_reload "$PIM_CAMERA_RUNTIME_JSON"
module_settle=$(grep -E '^(rmmod|modprobe|sleep) ' "$PIM_CAMERA_CALL_LOG")
expected_module_settle=$'rmmod imx8-media-dev\nrmmod max9296\nsleep 0.2\nmodprobe max9296\nsleep 0.1\nmodprobe imx8-media-dev'
if [ "$module_settle" != "$expected_module_settle" ]; then
    printf 'module settle expected:\n%s\nmodule settle actual:\n%s\n' "$expected_module_settle" "$module_settle" >&2
    settle_fail=1
fi

owner_active
printf '{bad json}\n' > "$PIM_CAMERA_RUNTIME_JSON"
: > "$PIM_CAMERA_CALL_LOG"
expect_rc 64 cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" module_reload test invalid
[ ! -s "$PIM_CAMERA_CALL_LOG" ] || fail "invalid runtime performed a side effect"
runtime

owner_active
FAIL_MODPROBE=max9296 expect cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" module_reload test fallback
grep -q '^reboot ' "$PIM_CAMERA_CALL_LOG" || fail "module and hard-reset failure did not request reboot"
[ "$(grep -c '^reboot ' "$PIM_CAMERA_CALL_LOG")" -eq 1 ] || fail "reboot requested more than once"
history=$(grep -rl '"reboot_fallback"' "$PIM_CAMERA_STATE_DIR/recovery/history")
jq -e '[.actions[].action] == ["module_reload","camera_hard_reset","reboot_fallback"]' "$history" >/dev/null || { cat "$history" >&2; fail "fallback actions were not ordered"; }

owner_active
: > "$PIM_CAMERA_CALL_LOG"
touch "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/isi-capture/32e00000.isi:cap_device"
touch "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/isi-m2m/32e00000.isi:m2m_device"
expect cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" camera_hard_reset test hard
unbind=$(grep '^sysfs unbind ' "$PIM_CAMERA_CALL_LOG" | tr '\n' ',')
bind=$(grep '^sysfs bind ' "$PIM_CAMERA_CALL_LOG" | tr '\n' ',')
case "$unbind" in *isi-capture*isi-m2m*mxc-isi*mxc-mipi-csi2-sam*) ;; *) fail "child-first unbind order: $unbind";; esac
case "$bind" in *mxc-mipi-csi2-sam*mxc-isi*) ;; *) fail "parent-first bind order: $bind";; esac
! grep -q 'systemctl .*cam-operate' "$PIM_CAMERA_CALL_LOG" || fail "hard reset controlled cam-operate service"
! grep -q '^sysfs bind 32e00000.isi:cap_device ' "$PIM_CAMERA_CALL_LOG" || fail "auto-bound capture child was bound twice"
! grep -q '^sysfs bind 32e00000.isi:m2m_device ' "$PIM_CAMERA_CALL_LOG" || fail "auto-bound m2m child was bound twice"
hard_reset_settle=$(awk '
    $0 == "rmmod imx8-media-dev" { hardware = 1 }
    hardware && /^(rmmod|modprobe|sleep|sysfs (unbind|bind)) / { print }
    hardware && /^(start ord|start vcm|start_cam)$/ { exit }
' "$PIM_CAMERA_CALL_LOG" | sed "s#$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/##")
expected_hard_reset_settle=$'rmmod imx8-media-dev\nsleep 1\nrmmod max9296\nsleep 1\nsysfs unbind 32e00000.isi:cap_device isi-capture/unbind\nsysfs unbind 32e02000.isi:cap_device isi-capture/unbind\nsleep 1\nsysfs unbind 32e00000.isi:m2m_device isi-m2m/unbind\nsleep 1\nsysfs unbind 32e00000.isi mxc-isi/unbind\nsysfs unbind 32e02000.isi mxc-isi/unbind\nsleep 1\nsysfs unbind 32e40000.csi mxc-mipi-csi2-sam/unbind\nsysfs unbind 32e50000.csi mxc-mipi-csi2-sam/unbind\nsleep 2\nsysfs bind 32e40000.csi mxc-mipi-csi2-sam/bind\nsysfs bind 32e50000.csi mxc-mipi-csi2-sam/bind\nsleep 1\nsysfs bind 32e00000.isi mxc-isi/bind\nsysfs bind 32e02000.isi mxc-isi/bind\nsleep 2\nsysfs bind 32e02000.isi:cap_device isi-capture/bind\nsleep 1\nmodprobe max9296\nsleep 3\nmodprobe imx8-media-dev\nsleep 5'
if [ "$hard_reset_settle" != "$expected_hard_reset_settle" ]; then
    printf 'hard-reset settle expected:\n%s\nhard-reset settle actual:\n%s\n' "$expected_hard_reset_settle" "$hard_reset_settle" >&2
    settle_fail=1
fi
[ "$settle_fail" -eq 0 ] || fail "hardware settle windows/order changed"

# Review regressions: cleanup must be session-scoped and never delete unrelated
# markers; BG identity must use full-command matching; child auto-bind is skipped.
mkdir -p "$WORK/recordings"
printf '%s\n' '{"VHL_CAM":{"app":"gstApp","capture":{"enable":false},"tmp_path":"'"$WORK"'/recordings","vhl_name":"VD3001"},"ORD":{},"VCM":{}}' > "$PIM_CAMERA_RUNTIME_JSON"
printf '%s\n' '20260901 12:34:56' > "$WORK/start-time"
touch "$WORK/recordings/VD3001_20260901_1234-ch0.mp4" "$WORK/recordings/VD3001_20260901_1235-ch0.mp4" "$WORK/recordings/other_20260901_1234.mp4"
touch "$WORK/session_keep.video_done" "$WORK/session_keep.srt_done"
PIM_CAMERA_SESSION_TIME_FILE="$WORK/start-time" cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"
[ ! -e "$WORK/recordings/VD3001_20260901_1234-ch0.mp4" ] || fail "current session recording survived cleanup"
[ -e "$WORK/recordings/VD3001_20260901_1235-ch0.mp4" ] || fail "next session recording was over-deleted"
[ -e "$WORK/recordings/other_20260901_1234.mp4" ] || fail "other vehicle recording was over-deleted"
[ -e "$WORK/session_keep.video_done" ] && [ -e "$WORK/session_keep.srt_done" ] || fail "unrelated session marker was deleted"
printf '%s\n' '../../unsafe' > "$WORK/start-time"
PIM_CAMERA_SESSION_TIME_FILE="$WORK/start-time" cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"
[ -e "$WORK/recordings/VD3001_20260901_1235-ch0.mp4" ] || fail "malformed marker deleted a recording"
printf '%s\n' '20260901 12:34:56' > "$WORK/start-time"
ln -s "$WORK/recordings" "$WORK/linked-recordings"
printf '%s\n' '{"VHL_CAM":{"tmp_path":"'"$WORK"'/linked-recordings","vhl_name":"VD3001"},"ORD":{},"VCM":{}}' > "$PIM_CAMERA_RUNTIME_JSON"
expect_rc 64 env PIM_CAMERA_SESSION_TIME_FILE="$WORK/start-time" bash -c 'source "$PIM_LIB/cam_recovery_actions.sh"; cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"'

echo "recovery actions: PASS"
