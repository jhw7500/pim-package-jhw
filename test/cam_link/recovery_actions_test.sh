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
EDGE_TEMPLATE="$ROOT/dist/pim/opt/pim/config/edgeconf_pim_base.json"
ORD_TEMPLATE="$ROOT/dist/pim/opt/pim/config/ord_vcm_conf.json"
export PIM_CAMERA_SYSTEMCTL=systemctl
export PIM_CAMERA_ORD_STATE_FILE="$WORK/ord-state"
export PIM_CAMERA_ORD_POLL_FILE="$WORK/ord-poll"
DAEMON_PID=4242

fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { "$@" || fail "command failed: $*"; }
expect_rc() { local wanted=$1; shift; set +e; "$@"; local got=$?; set -e; [ "$got" = "$wanted" ] || fail "expected rc=$wanted got=$got: $*"; }
fake_stat() { mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"; { printf '%s' "$DAEMON_PID (cam-operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' 111 0 0\n'; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"; }
runtime() {
    mkdir -p "$(dirname "$PIM_CAMERA_RUNTIME_JSON")" "$WORK/recordings"
    jq -s --arg tmp "$WORK/recordings" '
        .[1] + {
            VHL_CAM:.[0].VHL_CAM,
            NETWORK:{ETH1:(.[0].NETWORK.ETH1 | {
                ping_check_enable,
                client_ip_addr,
                ping_max_fail_count
            })}
        } |
        .VHL_CAM.tmp_path=$tmp |
        .VHL_CAM.capture.enable=false
    ' "$EDGE_TEMPLATE" "$ORD_TEMPLATE" > "$PIM_CAMERA_RUNTIME_JSON"
    printf '%s\n' '20260901 12:34:56' > "$WORK/start-time"
    export PIM_CAMERA_SESSION_TIME_FILE="$WORK/start-time"
}
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
        printf '#!/bin/sh\nprintf "%%s %%s\\n" "$(basename "$0")" "$*" >> "$PIM_CAMERA_CALL_LOG"\n[ "$(basename "$0")" = modprobe ] && [ "$1" = "${FAIL_MODPROBE:-}" ] && exit 23\n[ "$(basename "$0")" = reboot ] && [ -n "${FAIL_REBOOT_RC:-}" ] && { echo "Failed to start reboot.target: Transaction is destructive." >&2; exit "$FAIL_REBOOT_RC"; }\nexit 0\n' > "$WORK/stub/$cmd"
        chmod +x "$WORK/stub/$cmd"
    done
    printf '#!/bin/sh\nprintf "kill %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\n[ "${KEEP_BG:-0}" = 1 ] || rm -f "$PIM_CAMERA_PROCESS_ROOT/$2/cmdline"\nexit 0\n' > "$WORK/stub/kill"
    chmod +x "$WORK/stub/kill"
    printf '#!/bin/sh\nexec 9>"$WORK/procs.lock"\nflock 9\nlast=\nfor arg; do last=$arg; done\nprintf "pgrep %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\ngrep -Fqx "$last" "$WORK/procs" 2>/dev/null\n' > "$WORK/stub/pgrep"
    printf '#!/bin/sh\nexec 9>"$WORK/procs.lock"\nflock 9\nlast=\nfor arg; do last=$arg; done\nprintf "pkill %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\ngrep -Fvx "$last" "$WORK/procs" > "$WORK/procs.next" 2>/dev/null || :\nmv "$WORK/procs.next" "$WORK/procs"\ncase "$last" in *BG_Check_for_pim.sh) rm -f "$PIM_CAMERA_PROCESS_ROOT"/*/cmdline;; esac\n' > "$WORK/stub/pkill"
    printf '#!/bin/sh\nprintf "lsmod\\n" >> "$PIM_CAMERA_CALL_LOG"\nprintf "%%s\\n" "${LSMOD_ROWS:-}"\nexit 0\n' > "$WORK/stub/lsmod"
    printf '#!/bin/sh\nexec 9>"$WORK/procs.lock"\nflock 9\nprintf "systemctl %%s\\n" "$*" >> "$PIM_CAMERA_CALL_LOG"\ncase "$1" in\n  is-active) state=$(cat "$PIM_CAMERA_ORD_STATE_FILE" 2>/dev/null || printf inactive); if [ "$state" = active-then-failed ]; then if [ ! -e "$PIM_CAMERA_ORD_POLL_FILE" ]; then : > "$PIM_CAMERA_ORD_POLL_FILE"; printf "active\\n"; exit 0; fi; printf "failed\\n"; exit 4; fi; printf "%%s\\n" "$state"; [ "$state" = active ] && exit 0 || [ "$state" = inactive ] && exit 3 || exit 4 ;;\n  show) [ "$2" = ord-operate.service ] && [ "$3" = --property=InvocationID ] && [ "$4" = --value ] || exit 64; printf "0123456789abcdef0123456789abcdef\\n" ;;\n  stop) grep -Fvx ord "$WORK/procs" > "$WORK/procs.next" 2>/dev/null || :; mv "$WORK/procs.next" "$WORK/procs"; printf "inactive\\n" > "$PIM_CAMERA_ORD_STATE_FILE"; rm -f "$PIM_CAMERA_RUN_DIR/ord-ready" "$PIM_CAMERA_ORD_POLL_FILE" ;;\n  restart) grep -Fvx ord "$WORK/procs" > "$WORK/procs.next" 2>/dev/null || :; mv "$WORK/procs.next" "$WORK/procs"; printf "ord\\n" >> "$WORK/procs"; mkdir -p "$PIM_CAMERA_RUN_DIR"; if [ "${ORD_RESTART_MODE:-ready}" = delayed-fail ]; then printf "active-then-failed\\n" > "$PIM_CAMERA_ORD_STATE_FILE"; rm -f "$PIM_CAMERA_RUN_DIR/ord-ready" "$PIM_CAMERA_ORD_POLL_FILE"; else printf "active\\n" > "$PIM_CAMERA_ORD_STATE_FILE"; printf "0123456789abcdef0123456789abcdef\\n" > "$PIM_CAMERA_RUN_DIR/ord-ready"; fi ;;\n  *) exit 64 ;;\nesac\n' > "$WORK/stub/systemctl"
    printf '#!/bin/sh\nexec 9>"$WORK/procs.lock"\nflock 9\nprintf "start_cam\\n" >> "$PIM_CAMERA_CALL_LOG"\nprintf "gstApp\\n" >> "$WORK/procs"\nmkdir -p "$PIM_CAMERA_PROCESS_ROOT/100"\nprintf "%%s" "100 (BG_Check_for_pim) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1000 0" > "$PIM_CAMERA_PROCESS_ROOT/100/stat"\nprintf "/bin/bash\\000'"$PIM_BIN"'/BG_Check_for_pim.sh\\0004\\000" > "$PIM_CAMERA_PROCESS_ROOT/100/cmdline"\nexit 0\n' > "$PIM_CAMERA_START_CAM"
    for cmd in ord vcm; do printf '#!/bin/sh\nexec 9>"$WORK/procs.lock"\nflock 9\nprintf "start %%s\\n" "$(basename "$0")" >> "$PIM_CAMERA_CALL_LOG"\nprintf "%%s\\n" "$(basename "$0")" >> "$WORK/procs"\n' > "$WORK/stub/$cmd"; chmod +x "$WORK/stub/$cmd"; done
    chmod +x "$WORK/stub/pgrep" "$WORK/stub/pkill" "$WORK/stub/lsmod" "$WORK/stub/systemctl" "$PIM_CAMERA_START_CAM"
    printf 'inactive\n' > "$PIM_CAMERA_ORD_STATE_FILE"
    export PATH="$WORK/stub:$PATH"
}

printf 'boot\n' > "$PIM_CAMERA_BOOT_ID_FILE"
fake_stat
prepare_stubs
enable -n kill
export PIM_CAMERA_BG_CHECKER="$PIM_BIN/BG_Check_for_pim.sh"
# $WORK/procs 는 여러 스텁이 동시에 건드린다 — cam_launch_consumer 가 vcm 을
# 백그라운드 서브셸로 띄우는 동안 전경은 ord 를 재시작하며 같은 파일을 읽고 다시 쓴다.
# append 가 그 읽기와 쓰기 사이에 끼면 줄이 사라지므로 모든 접근을 이 락으로 묶는다.
: > "$WORK/procs.lock"
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

echo "=== gstapp_stop stops the app and leaves the restart to cam-operate ==="
# The point of this action is that it does NOT relaunch: killcam confirms termination
# and cam_liveness_tick submits the restart on a later pass (issue #113).  It is also
# deliberately uncountered - giving it a counter would change the key set of the
# persistent state.json and make every already-deployed board's file fail
# _cr_state_valid, so the key-set assertion below is part of the contract.
: > "$PIM_CAMERA_CALL_LOG"
printf 'gstApp\n%s\n' "$PIM_CAMERA_BG_CHECKER" > "$WORK/procs"
rm -f "$PIM_CAMERA_PROCESS_ROOT"/*/cmdline
mkdir -p "$PIM_CAMERA_PROCESS_ROOT/99"
printf '%s' '99 (BG_Check_for_pim) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999 0' > "$PIM_CAMERA_PROCESS_ROOT/99/stat"
printf '/bin/bash\000%s\0004\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/99/cmdline"
owner_active
stop_state_keys=$(jq -c '.actions|keys|sort' "$PIM_CAMERA_STATE_DIR/recovery/state.json")
expect cam_request_submit gstapp_stop legacy-kill-test legacy-wrapper >/dev/null
stop_id=$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/pending.json")
expect cam_request_claim
expect cam_execute_pending_request
grep -q '^pkill .*gstApp' "$PIM_CAMERA_CALL_LOG" || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail 'gstapp_stop did not quiesce the app'; }
grep -q '^kill -TERM 99$' "$PIM_CAMERA_CALL_LOG" || fail 'gstapp_stop did not quiesce the BG child by exact argv identity'
! grep -q '^start_cam$' "$PIM_CAMERA_CALL_LOG" || { cat "$PIM_CAMERA_CALL_LOG" >&2; fail 'gstapp_stop relaunched the app - the restart belongs to cam-operate'; }
jq -e --arg id "$stop_id" '.type=="gstapp_stop" and .id==$id and .status=="SUCCEEDED" and .rc==0' \
    "$PIM_CAMERA_RUN_DIR/recovery/results/$stop_id.json" >/dev/null \
    || fail 'gstapp_stop did not publish a SUCCEEDED terminal result'
jq -e '[.actions[]|select(.action=="gstapp_stop")] | length==1 and .[0].countered==false' \
    "$PIM_CAMERA_STATE_DIR/recovery/history/$stop_id.json" >/dev/null \
    || fail 'gstapp_stop was not recorded as exactly one uncountered history step'
[ "$stop_state_keys" = "$(jq -c '.actions|keys|sort' "$PIM_CAMERA_STATE_DIR/recovery/state.json")" ] \
    || fail 'gstapp_stop changed the persistent counter key set'
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = ACTIVE ] || fail 'gstapp_stop left the owner non-ACTIVE'
{ [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ]; } \
    || fail 'gstapp_stop retained a lease'
# ACTIVE 진입에서는 후속 재시작을 제출하지 않는다 - 같은 iteration 의 liveness 가 한다.
# 아래 DEGRADED 절이 제출을 단언하므로 이 줄이 그 대조군이다.

echo "=== gstapp_stop must not clear the degraded record or raise the owner ==="
# The dangerous shape: a board whose recovery failed is left dirty+DEGRADED with gstApp
# already gone, so cam_stop_process returns 0 immediately and the request succeeds having
# done nothing.  If that success reaches _coc_persist_success it rewrites service-state
# with dirty:false and degraded_reason:null and the next boot is downgraded from
# camera_hard_reset to module_reload - one operator killcam erasing the record that the
# hardware was left dirty.  Asserted byte-for-byte, plus the plan it feeds.
: > "$PIM_CAMERA_CALL_LOG"
: > "$WORK/procs"
rm -f "$PIM_CAMERA_PROCESS_ROOT"/*/cmdline
owner_active
expect cam_mark_degraded HARD_RESET_FAILED camera_health true
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = DEGRADED ] || fail 'degraded setup did not take'
svc_before=$(cat "$PIM_CAMERA_STATE_DIR/service-state.json")
plan_before=$(cam_plan_startup_action "$PIM_CAMERA_RUNTIME_JSON" "$svc_before")
[ "$plan_before" = camera_hard_reset ] || fail "dirty state should plan camera_hard_reset, planned $plan_before"
expect cam_request_submit gstapp_stop operator "operator killcam after a failed reset" >/dev/null
expect cam_request_claim
expect cam_execute_pending_request
[ "$svc_before" = "$(cat "$PIM_CAMERA_STATE_DIR/service-state.json")" ] \
    || { diff <(printf '%s\n' "$svc_before") <(cat "$PIM_CAMERA_STATE_DIR/service-state.json") >&2 || true
         fail 'gstapp_stop rewrote service-state.json'; }
[ "$plan_before" = "$(cam_plan_startup_action "$PIM_CAMERA_RUNTIME_JSON" "$(cat "$PIM_CAMERA_STATE_DIR/service-state.json")")" ] \
    || fail 'gstapp_stop changed the next startup plan'
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = DEGRADED ] \
    || fail 'gstapp_stop raised a DEGRADED owner to ACTIVE'
# ...and the app must not be left down.  Nothing else would restart it here:
# cam_monitor_control_iteration only ticks liveness for ACTIVE and
# chk_cam_operate.sh's cam_submit_internal_action also requires ACTIVE, so the stop
# has to queue the restart itself on this path.  The stop's own lease is gone and the
# follow-up is pending, not active - it is submitted, not waited on.
[ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ] \
    || fail 'gstapp_stop left its own lease active on the degraded path'
jq -e '.type=="gstapp_restart" and .source=="gstapp-stop-followup" and .status=="PENDING"' \
    "$PIM_CAMERA_RUN_DIR/recovery/pending.json" >/dev/null \
    || { cat "$PIM_CAMERA_RUN_DIR/recovery/pending.json" >&2 2>/dev/null || true
         fail 'gstapp_stop from DEGRADED did not queue the follow-up restart'; }
# 후속 요청은 소비해서 다음 절에 넘기지 않는다
expect cam_request_claim
expect cam_request_finish SUCCEEDED 0
# 하네스 복원: _cr_lifecycle_allowed 에 DEGRADED:DEGRADED 가 없으므로 owner 를 DEGRADED 로
# 남기면 뒤 절의 cam_owner_set_lifecycle DEGRADED 가 rc 64 로 거부된다.  프로세스도 되돌린다.
owner_active
printf 'gstApp\n%s\n' "$PIM_CAMERA_BG_CHECKER" > "$WORK/procs"
mkdir -p "$PIM_CAMERA_PROCESS_ROOT/99"
printf '%s' '99 (BG_Check_for_pim) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999 0' > "$PIM_CAMERA_PROCESS_ROOT/99/stat"
printf '/bin/bash\000%s\0004\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/99/cmdline"

echo "=== cam_execute_recovery_request refuses gstapp_stop without taking a lease ==="
# That entry point's shared success path sets the owner ACTIVE for every type, so a stop
# succeeding there would raise a DEGRADED owner and erase the persisted fault - the same
# hazard the section above pins on the production path.  It refuses the type instead, and
# the refusal has to come before submit/claim, or a rejected call would strand the lease
# and a RECOVERING owner.
: > "$PIM_CAMERA_CALL_LOG"
owner_active
expect cam_mark_degraded HARD_RESET_FAILED camera_health true
refuse_svc=$(cat "$PIM_CAMERA_STATE_DIR/service-state.json")
expect_rc 64 cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" gstapp_stop operator "must be refused here"
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = DEGRADED ] \
    || fail 'refused gstapp_stop moved the owner off DEGRADED'
{ [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/pending.json" ] && [ ! -e "$PIM_CAMERA_RUN_DIR/recovery/active.json" ]; } \
    || fail 'refused gstapp_stop stranded a lease'
[ "$refuse_svc" = "$(cat "$PIM_CAMERA_STATE_DIR/service-state.json")" ] \
    || fail 'refused gstapp_stop rewrote service-state.json'
[ "$(grep -cE '^(pkill|kill) ' "$PIM_CAMERA_CALL_LOG" || true)" -eq 0 ] \
    || fail 'refused gstapp_stop still signalled a process'
# 거부가 너무 넓지 않은지: 다른 type 은 이 진입점에서 계속 동작해야 한다
: > "$PIM_CAMERA_CALL_LOG"
printf 'gstApp\n%s\n' "$PIM_CAMERA_BG_CHECKER" > "$WORK/procs"
mkdir -p "$PIM_CAMERA_PROCESS_ROOT/99"
printf '%s' '99 (BG_Check_for_pim) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999 0' > "$PIM_CAMERA_PROCESS_ROOT/99/stat"
printf '/bin/bash\000%s\0004\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/99/cmdline"
owner_active
expect cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" gstapp_restart test "still works"
grep -q '^start_cam$' "$PIM_CAMERA_CALL_LOG" || fail 'the refusal broke gstapp_restart at this entry point'

echo "=== degraded camera-health apply uses one real full quiesce ==="
mkdir -p "$PIM_CAMERA_SOURCE_ROOT"
jq --arg tmp "$WORK/recordings" '
    .VHL_CAM.tmp_path=$tmp |
    .VHL_CAM.capture.enable=false |
    {VHL_CAM:.VHL_CAM, NETWORK:.NETWORK}
' "$EDGE_TEMPLATE" > "$PIM_CAMERA_SOURCE_ROOT/edgeconf_apply.json"
jq '.ETC.policy="same"' "$ORD_TEMPLATE" > "$PIM_CAMERA_SOURCE_ROOT/ord_vcm_conf.json"
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
start_line=$(grep -n -m1 -E '^(systemctl restart ord-operate\.service|start vcm|start_cam)$' "$PIM_CAMERA_CALL_LOG" | cut -d: -f1)
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

# 이슈 #140: 구 코드도 일반 실패 줄로 rc 는 남긴다
# (`action FAILED: reboot_fallback rc=1 step=<unnamed>`). 빠진 것은 systemd 가 낸
# 거부 사유이고, step 이 <unnamed> 이라 "재부팅이 거부됐다"와 "복구가 실패했다"가
# 구분되지 않는다. reboot 는 systemctl 심링크라 사유를 stderr 로 내므로 그것이
# 액션 로그에 닿는지 고정한다. 구 코드는 출력을 버려 이 단정이 실패한다.
owner_active
: > "$PIM_CAMERA_CALL_LOG"
export PIM_CAMERA_ACTION_LOG="$WORK/action-refusal.log"
: > "$PIM_CAMERA_ACTION_LOG"
FAIL_MODPROBE=max9296 FAIL_REBOOT_RC=1 \
    expect_rc 1 cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" module_reload test refusal
grep -q 'reboot refused rc=1' "$PIM_CAMERA_ACTION_LOG" \
    || { cat "$PIM_CAMERA_ACTION_LOG" >&2; fail "재부팅 거부가 거부로 식별되지 않았다 (reboot refused 줄 없음)"; }
grep -q 'Transaction is destructive' "$PIM_CAMERA_ACTION_LOG" \
    || { cat "$PIM_CAMERA_ACTION_LOG" >&2; fail "systemd 가 낸 거부 사유가 액션 로그에 남지 않았다"; }
# 성공 경로는 로그 줄에 도달하지 않아야 한다 — 보존 검사.
: > "$PIM_CAMERA_ACTION_LOG"
owner_active
FAIL_MODPROBE=max9296 expect cam_execute_recovery_request "$PIM_CAMERA_RUNTIME_JSON" module_reload test nolog
grep -q 'reboot refused' "$PIM_CAMERA_ACTION_LOG" \
    && { cat "$PIM_CAMERA_ACTION_LOG" >&2; fail "성공한 reboot 가 거부로 기록됐다"; }
unset PIM_CAMERA_ACTION_LOG FAIL_REBOOT_RC

# 이슈 #141: journald 는 회전하므로 _cra_fail 이 남기는 단계 이름이 조사 시점에 이미
# 사라져 있다. 기록 스키마는 정확 키 집합 단정이라 손대지 않고, 같은 진단을 디스크로도
# 보낸다. 아래 셋이 그 영속 경로의 계약이다.
echo "=== 액션 진단의 영속 기록 (이슈 #141) ==="

# ① 부모 디렉터리가 없어도 남긴다. 구 코드는 mkdir 을 하지 않아 아무것도 안 쓴다.
deep="$WORK/nodir-a/nodir-b/actions.log"
rm -rf "$WORK/nodir-a"
PIM_CAMERA_ACTION_LOG="$deep" PIM_CAMERA_ACTION_TAG=t141 \
    _cra_log err "probe-mkdir rc=7"
[ -f "$deep" ] || fail "부모 디렉터리가 없을 때 진단이 유실됐다 (mkdir 미수행)"
grep -q 'probe-mkdir rc=7' "$deep" || { cat "$deep" >&2; fail "진단 줄이 기록되지 않았다"; }
# 시각 접두사가 붙어야 회전 뒤에도 history 의 started_at 과 맞출 수 있다.
grep -qE '^[0-9]+ err probe-mkdir rc=7$' "$deep" \
    || { cat "$deep" >&2; fail "기록 형식이 '<epoch> <level> <line>' 이 아니다"; }

# ② 상한을 넘으면 절삭하되 최신 줄은 남는다. 구 코드는 무한 성장한다.
rot="$WORK/rotate/actions.log"; rm -rf "$WORK/rotate"; mkdir -p "$WORK/rotate"
head -c 4096 /dev/zero | tr '\0' 'x' > "$rot"
printf '\n' >> "$rot"
before=$(stat -c%s "$rot")
PIM_CAMERA_ACTION_LOG="$rot" PIM_CAMERA_ACTION_LOG_MAX_BYTES=2048 PIM_CAMERA_ACTION_TAG=t141 \
    _cra_log err "probe-rotate rc=9"
after=$(stat -c%s "$rot")
[ "$after" -lt "$before" ] || fail "상한을 넘겼는데 절삭되지 않았다 (before=$before after=$after)"
[ "$after" -le 2048 ] || fail "절삭 후에도 상한을 넘는다 (after=$after)"
grep -q 'probe-rotate rc=9' "$rot" || { fail "절삭이 최신 진단 줄을 버렸다"; }

# ③ 기록이 불가능해도 액션을 깨지 않는다. 경로가 디렉터리면 추가가 실패한다.
#    이 하네스는 set -e 라, 구 코드의 무가드 printf 는 여기서 호출자를 중단시킨다.
baddir="$WORK/as-dir"; rm -rf "$baddir"; mkdir -p "$baddir"
PIM_CAMERA_ACTION_LOG="$baddir" PIM_CAMERA_ACTION_TAG=t141 \
    _cra_log err "probe-unwritable rc=11" \
    || fail "기록 불가가 _cra_log 를 실패시켰다 (액션이 깨진다)"
# VAR=x func 형태는 bash 에서 함수 종료 후 남지 않는다(실측). unset 을 하면
# 오히려 라이브러리가 source 시점에 넣은 PIM_CAMERA_ACTION_TAG 기본값을 지워
# 뒤따르는 _cra_log 가 set -u 에서 깨진다.

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
! grep -q '^start ord$' "$PIM_CAMERA_CALL_LOG" || fail "hard reset launched ORD outside systemd"
! grep -q '^sysfs bind 32e00000.isi:cap_device ' "$PIM_CAMERA_CALL_LOG" || fail "auto-bound capture child was bound twice"
! grep -q '^sysfs bind 32e00000.isi:m2m_device ' "$PIM_CAMERA_CALL_LOG" || fail "auto-bound m2m child was bound twice"
hard_reset_settle=$(awk '
    $0 == "rmmod imx8-media-dev" { hardware = 1 }
    hardware && /^(rmmod|modprobe|sleep|sysfs (unbind|bind)) / { print }
    hardware && /^(systemctl restart ord-operate\.service|start vcm|start_cam)$/ { exit }
' "$PIM_CAMERA_CALL_LOG" | sed "s#$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/##")
expected_hard_reset_settle=$'rmmod imx8-media-dev\nsleep 1\nrmmod max9296\nsleep 1\nsysfs unbind 32e00000.isi:cap_device isi-capture/unbind\nsysfs unbind 32e02000.isi:cap_device isi-capture/unbind\nsleep 1\nsysfs unbind 32e00000.isi:m2m_device isi-m2m/unbind\nsleep 1\nsysfs unbind 32e00000.isi mxc-isi/unbind\nsysfs unbind 32e02000.isi mxc-isi/unbind\nsleep 1\nsysfs unbind 32e40000.csi mxc-mipi-csi2-sam/unbind\nsysfs unbind 32e50000.csi mxc-mipi-csi2-sam/unbind\nsleep 2\nsysfs bind 32e40000.csi mxc-mipi-csi2-sam/bind\nsysfs bind 32e50000.csi mxc-mipi-csi2-sam/bind\nsleep 1\nsysfs bind 32e00000.isi mxc-isi/bind\nsysfs bind 32e02000.isi mxc-isi/bind\nsleep 2\nsysfs bind 32e02000.isi:cap_device isi-capture/bind\nsleep 1\nmodprobe max9296\nsleep 3\nmodprobe imx8-media-dev\nsleep 5'
if [ "$hard_reset_settle" != "$expected_hard_reset_settle" ]; then
    printf 'hard-reset settle expected:\n%s\nhard-reset settle actual:\n%s\n' "$expected_hard_reset_settle" "$hard_reset_settle" >&2
    settle_fail=1
fi
[ "$settle_fail" -eq 0 ] || fail "hardware settle windows/order changed"
# 이슈 #61 완료 조건 2번의 "정확히 한 번"은 지금까지 단정이 아니라 코드 독해에만 의존했다.
# 위 settle 비교는 순서만 고정하고 건수는 못 본다 — awk 가 첫 start_cam 에서 exit 하므로
# 두 번째 기동이 뒤에 있어도 같은 출력이 나온다. 호출 로그는 :304 에서 비워졌으므로
# 아래 건수는 이 hard reset 이 낸 것만 센다.
hard_reset_starts=$(grep -c '^start_cam$' "$PIM_CAMERA_CALL_LOG" || true)
[ "$hard_reset_starts" -eq 1 ] \
    || fail "hard reset started gstApp $hard_reset_starts time(s), expected exactly 1"

# Review regressions: cleanup must be session-scoped and never delete unrelated
# markers; BG identity must use full-command matching; child auto-bind is skipped.
mkdir -p "$WORK/recordings"
jq -s --arg tmp "$WORK/recordings" '
    .[1] + {
        VHL_CAM:.[0].VHL_CAM,
        NETWORK:{ETH1:(.[0].NETWORK.ETH1 | {
            ping_check_enable,
            client_ip_addr,
            ping_max_fail_count
        })}
    } |
    .VHL_CAM.tmp_path=$tmp |
    .VHL_CAM.capture.enable=false |
    .VHL_CAM.vhl_name="VD3001"
' "$EDGE_TEMPLATE" "$ORD_TEMPLATE" > "$PIM_CAMERA_RUNTIME_JSON"
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
jq -s --arg tmp "$WORK/linked-recordings" '
    .[1] + {
        VHL_CAM:.[0].VHL_CAM,
        NETWORK:{ETH1:(.[0].NETWORK.ETH1 | {
            ping_check_enable,
            client_ip_addr,
            ping_max_fail_count
        })}
    } |
    .VHL_CAM.tmp_path=$tmp |
    .VHL_CAM.vhl_name="VD3001"
' "$EDGE_TEMPLATE" "$ORD_TEMPLATE" > "$PIM_CAMERA_RUNTIME_JSON"
expect_rc 64 env PIM_CAMERA_SESSION_TIME_FILE="$WORK/start-time" bash -c 'source "$PIM_LIB/cam_recovery_actions.sh"; cam_cleanup_recording_orphans "$PIM_CAMERA_RUNTIME_JSON"'

echo "=== delayed ORD init failure cannot complete a recovery request ==="
runtime
owner_active
: > "$PIM_CAMERA_CALL_LOG"
failed_ord_id=$(cam_request_submit module_reload test "delayed ORD init failure")
export ORD_RESTART_MODE=delayed-fail PIM_CAMERA_READY_TIMEOUT_SEC=1 FAIL_REBOOT_RC=29
expect_rc 29 cam_poll_pending_request
unset ORD_RESTART_MODE PIM_CAMERA_READY_TIMEOUT_SEC FAIL_REBOOT_RC
jq -e --arg id "$failed_ord_id" '.id==$id and .status=="FAILED" and .rc==29' "$PIM_CAMERA_RUN_DIR/recovery/results/$failed_ord_id.json" >/dev/null || fail "delayed ORD init failure reached a successful request result"
[ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = DEGRADED ] || fail "delayed ORD init failure returned the owner to ACTIVE"
failed_ord_history=$(grep -rl -- "\"id\":\"$failed_ord_id\"" "$PIM_CAMERA_STATE_DIR/recovery/history")
jq -e '[.actions[] | {action,status,rc}] == [{"action":"module_reload","status":"FAILED","rc":1},{"action":"camera_hard_reset","status":"FAILED","rc":1},{"action":"reboot_fallback","status":"FAILED","rc":29}]' "$failed_ord_history" >/dev/null || fail "delayed ORD init failure did not propagate through recovery fallback"
# module_reload 2회 + camera_hard_reset 2회 = 4 가 원래 기대값이었다. 9987dfb(복구 액션의
# 실패 단계 로깅)가 restart_ord 실패 시 unit 상태를 한 번 더 조회하도록 추가해, 진단
# 재조회가 일어나는 camera_hard_reset 경로에서만 1회 늘어 5회가 된다.
[ "$(grep -Fxc 'systemctl is-active ord-operate.service' "$PIM_CAMERA_CALL_LOG")" -eq 5 ] || fail "recovery did not observe both delayed ORD init failures"

echo "recovery actions: PASS"
