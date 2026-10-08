#!/usr/bin/env bash
# jq spawns per recovery request, end to end (issue #150).  One jq spawn costs
# ~307ms on the board, so this count is a floor under every request's latency.
#
# Each flow runs the way the board runs it: the submit in its own bash process
# (cam-recoveryctl itself) and the daemon side in another fresh bash that calls
# cam_poll_pending_request, so neither starts with a warm _cr_jq_memo.  jq is
# counted through a PATH shim that appends one line per exec, which covers those
# two processes and every child they start.
#
# The shipped start_cam.sh runs too: it is a process of its own that checks the
# owner and the runtime again before it launches anything.  Only what it finally
# execs is stubbed - the app binary (gstApp, found through PATH) and the BG
# checker.  The real BG checker runs jq of its own when it starts; that is not
# counted here.
#
# The ceilings are a ratchet: each is the exact count measured on the commit that
# added this file.  A change that spawns more jq fails here; a change that spawns
# fewer lowers the ceiling in the same commit.
set -euo pipefail

# --- ceilings: jq spawns per flow (submit + daemon) ---------------------------
# Measured on e3da7ca as submit + daemon; the daemon side includes the 4 jq of
# each start_cam.sh run (one per flow that starts the app).  The assertion is on
# the total.
# flow                   ceiling   measured        terminal state the flow must reach
declare -A CEILING=(
    [gstapp_stop]=68           #   6 + 62          SUCCEEDED
    [gstapp_restart]=118       #   6 + 108 + 4     SUCCEEDED
    [camera_hard_reset]=120    #   6 + 110 + 4     SUCCEEDED
    [module_reload_fails]=196  #   6 + 190         FAILED rc=1: module_reload and
                               #                   camera_hard_reset fail at modprobe
                               #                   (rc 23) before the app starts,
                               #                   reboot_fallback is refused (rc 1)
)
FLOWS=(gstapp_stop gstapp_restart camera_hard_reset module_reload_fails)

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-jq-budget.XXXXXX")
export WORK
trap 'rm -rf "$WORK"' EXIT
# JQ_BUDGET_LIB_DIR and JQ_BUDGET_BIN_DIR swap the library and bin directories
# (mutation controls).  cam-recoveryctl, cam_operate_control.sh and start_cam.sh
# source from PIM_LIB; start_cam.sh itself is $PIM_BIN/start_cam.sh.  A swapped
# bin directory needs a config/ beside it: camera_runtime_config.py reads ../config.
export PIM_LIB="${JQ_BUDGET_LIB_DIR:-$ROOT/dist/pim/opt/pim/lib}"
export PIM_BIN="${JQ_BUDGET_BIN_DIR:-$ROOT/dist/pim/opt/pim/bin}"
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
# Unset, so the executor runs $PIM_BIN/start_cam.sh as it does on the board.
unset PIM_CAMERA_START_CAM
export PIM_CAMERA_SHM_DIR="$WORK/shm"
export PIM_CAMERA_PROCESS_ROOT="$WORK/processes"
export PIM_CAMERA_SYSTEMCTL=systemctl
export PIM_CAMERA_ORD_STATE_FILE="$WORK/ord-state"
export PIM_CAMERA_ORD_POLL_FILE="$WORK/ord-poll"
export PIM_CAMERA_BG_CHECKER="$WORK/bg/BG_Check_for_pim.sh"
export PIM_CAMERA_SESSION_TIME_FILE="$WORK/start-time"
EDGE_TEMPLATE="$ROOT/dist/pim/opt/pim/config/edgeconf_pim_base.json"
ORD_TEMPLATE="$ROOT/dist/pim/opt/pim/config/ord_vcm_conf.json"
DAEMON_PID=4242

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
die() { echo "FAIL: $*" >&2; exit 1; }

# --- stubs: the same command doubles as test/cam_link/recovery_actions_test.sh -
mkdir -p "$WORK/stub" "$WORK/shim" "$WORK/bg"
for cmd in rmmod modprobe reboot logger sleep; do
    cat > "$WORK/stub/$cmd" <<'SH'
#!/bin/sh
printf "%s %s\n" "$(basename "$0")" "$*" >> "$PIM_CAMERA_CALL_LOG"
[ "$(basename "$0")" = modprobe ] && [ "$1" = "${FAIL_MODPROBE:-}" ] && exit 23
[ "$(basename "$0")" = reboot ] && [ -n "${FAIL_REBOOT_RC:-}" ] && { echo "Failed to start reboot.target: Transaction is destructive." >&2; exit "$FAIL_REBOOT_RC"; }
exit 0
SH
done
cat > "$WORK/stub/kill" <<'SH'
#!/bin/sh
printf "kill %s\n" "$*" >> "$PIM_CAMERA_CALL_LOG"
rm -f "$PIM_CAMERA_PROCESS_ROOT/$2/cmdline"
exit 0
SH
cat > "$WORK/stub/pgrep" <<'SH'
#!/bin/sh
exec 9>"$WORK/procs.lock"
flock 9
last=
for arg; do last=$arg; done
printf "pgrep %s\n" "$*" >> "$PIM_CAMERA_CALL_LOG"
grep -Fqx "$last" "$WORK/procs" 2>/dev/null
SH
cat > "$WORK/stub/pkill" <<'SH'
#!/bin/sh
exec 9>"$WORK/procs.lock"
flock 9
last=
for arg; do last=$arg; done
printf "pkill %s\n" "$*" >> "$PIM_CAMERA_CALL_LOG"
grep -Fvx "$last" "$WORK/procs" > "$WORK/procs.next" 2>/dev/null || :
mv "$WORK/procs.next" "$WORK/procs"
case "$last" in *BG_Check_for_pim.sh) rm -f "$PIM_CAMERA_PROCESS_ROOT"/*/cmdline;; esac
SH
cat > "$WORK/stub/lsmod" <<'SH'
#!/bin/sh
printf "lsmod\n" >> "$PIM_CAMERA_CALL_LOG"
printf "%s\n" "${LSMOD_ROWS:-}"
exit 0
SH
cat > "$WORK/stub/systemctl" <<'SH'
#!/bin/sh
exec 9>"$WORK/procs.lock"
flock 9
printf "systemctl %s\n" "$*" >> "$PIM_CAMERA_CALL_LOG"
case "$1" in
  is-active) state=$(cat "$PIM_CAMERA_ORD_STATE_FILE" 2>/dev/null || printf inactive); printf "%s\n" "$state"; [ "$state" = active ] && exit 0 || [ "$state" = inactive ] && exit 3 || exit 4 ;;
  show) [ "$2" = ord-operate.service ] && [ "$3" = --property=InvocationID ] && [ "$4" = --value ] || exit 64; printf "0123456789abcdef0123456789abcdef\n" ;;
  stop) grep -Fvx ord "$WORK/procs" > "$WORK/procs.next" 2>/dev/null || :; mv "$WORK/procs.next" "$WORK/procs"; printf "inactive\n" > "$PIM_CAMERA_ORD_STATE_FILE"; rm -f "$PIM_CAMERA_RUN_DIR/ord-ready" ;;
  restart) grep -Fvx ord "$WORK/procs" > "$WORK/procs.next" 2>/dev/null || :; mv "$WORK/procs.next" "$WORK/procs"; printf "ord\n" >> "$WORK/procs"; mkdir -p "$PIM_CAMERA_RUN_DIR"; printf "active\n" > "$PIM_CAMERA_ORD_STATE_FILE"; printf "0123456789abcdef0123456789abcdef\n" > "$PIM_CAMERA_RUN_DIR/ord-ready" ;;
  *) exit 64 ;;
esac
SH
# What start_cam.sh finally execs.  The app is the runtime's `gstApp`, found
# through PATH (the loop below); the BG checker is exec'd by path with the delay,
# and the BG scan recognises it by a process record whose argv is
# `/bin/bash <checker> <delay>`, so its stub writes that record.
cat > "$PIM_CAMERA_BG_CHECKER" <<'SH'
#!/bin/sh
exec 9>"$WORK/procs.lock"
flock 9
printf "start BG_Check_for_pim.sh %s\n" "$*" >> "$PIM_CAMERA_CALL_LOG"
mkdir -p "$PIM_CAMERA_PROCESS_ROOT/100"
printf "%s" "100 (BG_Check_for_pim) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1000 0" > "$PIM_CAMERA_PROCESS_ROOT/100/stat"
printf "/bin/bash\000%s\000%s\000" "$PIM_CAMERA_BG_CHECKER" "$1" > "$PIM_CAMERA_PROCESS_ROOT/100/cmdline"
SH
for cmd in ord vcm gstApp; do
    cat > "$WORK/stub/$cmd" <<'SH'
#!/bin/sh
exec 9>"$WORK/procs.lock"
flock 9
printf "start %s\n" "$(basename "$0")" >> "$PIM_CAMERA_CALL_LOG"
printf "%s\n" "$(basename "$0")" >> "$WORK/procs"
SH
done
REAL_JQ=$(command -v jq)
# The daemon and the children start_cam.sh and the vcm launch leave behind run
# at the same time, so several processes append here at once.  Each appends one
# 3-byte line with O_APPEND (>>), and a write that small lands whole at the end
# of the file, so lines neither interleave nor overwrite: the count is the number
# of lines.
cat > "$WORK/shim/jq" <<SH
#!/bin/sh
printf 'jq\n' >> "\${JQ_BUDGET_LOG:?}"
exec "$REAL_JQ" "\$@"
SH
chmod +x "$WORK"/stub/* "$WORK/shim/jq" "$PIM_CAMERA_BG_CHECKER"
STUB_PATH="$WORK/stub:$PATH"
SHIM_PATH="$WORK/shim:$STUB_PATH"

# --- every jq on the request path goes through PATH ---------------------------
# The shim sees only a jq found through PATH.  A shipped script that runs jq by
# path, through `command -p`, from a captured path, or after replacing PATH or
# the environment would spawn jq this budget never counts, so such a line fails
# here.  Scanned: every shell and python file under dist/pim/opt/pim, by
# shebang or extension.  Patterns, in order:
#   a path ending in /jq (absolute or relative, shell or python)
#   command -p jq
#   jq's path captured: $(command -v jq), $(which jq), $(type -P jq), hash -t jq
#   a variable assigned the bare name jq
#   a jq-named variable used as the command: $JQ ${JQ} $jq_bin ${JQ_PATH} ...
#   env -i / --ignore-environment
#   python shutil.which("jq")
# plus any PATH= assignment that does not extend $PATH.
# Not seen: a command name built at run time (eval, a value read from a file);
# a PATH set outside these files (the systemd unit, cron, sudo's secure_path -
# the counted processes here get PATH from this test); jq run by compiled
# programs or by anything outside dist/pim/opt/pim; languages other than shell
# and python.
cat > "$WORK/jq-bypass.patterns" <<'RE'
/jq([[:space:]"'`;|&)]|$)
command[[:space:]]+-[A-Za-z]*p[A-Za-z]*[[:space:]]+jq([^A-Za-z0-9_.-]|$)
(\$\(|`)[[:space:]]*(command[[:space:]]+-[A-Za-z]*[vV]|which|type[[:space:]]+-[A-Za-z]*[pP])[[:space:]]+jq([^A-Za-z0-9_.-]|$)
hash[[:space:]]+-t[[:space:]]+jq([^A-Za-z0-9_.-]|$)
(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*=["']?jq["']?([[:space:];)]|$)
\$\{?(JQ|jq)(_?(BIN|bin|PATH|path|CMD|cmd|EXE|exe))?\}?([^A-Za-z0-9_[]|$)
env[[:space:]]+(-[A-Za-z]*i|--ignore-environment)
which\([[:space:]]*["']jq["']
RE
# Prints each offending line as file:line:text; returns 2 if a file could not
# be read, so an unreadable tree is not mistaken for a clean one.
jq_bypass_scan() {
    local rc=0
    grep -nHE -f "$WORK/jq-bypass.patterns" -- "$@" || rc=$?
    [ "$rc" -le 1 ] || return 2
    rc=0
    grep -nHE '(^|[^A-Za-z0-9_])PATH=' -- "$@" > "$WORK/path-assignments" || rc=$?
    [ "$rc" -le 1 ] || return 2
    grep -vE '\$\{?PATH([^A-Za-z0-9_]|$)' "$WORK/path-assignments" || [ $? -eq 1 ]
}
scan_files=()
while IFS= read -r -d '' f; do
    first=
    { IFS= read -r first || :; } < "$f" 2>/dev/null
    case "$f" in
        *.sh|*.py) scan_files+=("$f") ;;
        *) [[ $first =~ ^\#!.*[[:space:]/](sh|bash|dash|ksh|python[0-9.]*)([[:space:]]|$) ]] && scan_files+=("$f") ;;
    esac
done < <(find "$ROOT/dist/pim/opt/pim" -type f -print0)
# The scan must at least cover the request path itself.
for f in lib/cam_recovery.sh lib/cam_recovery_actions.sh lib/cam_operate_control.sh bin/cam-recoveryctl bin/start_cam.sh bin/camera_runtime_config.py; do
    [[ " ${scan_files[*]} " == *" $ROOT/dist/pim/opt/pim/$f "* ]] || fail "jq bypass scan: $f is not among the scanned files"
done
hits=$(jq_bypass_scan "${scan_files[@]}") || die "jq bypass scan: a shipped file could not be read"
[ -z "$hits" ] || fail "a shipped script runs jq outside PATH, which the budget cannot count:"$'\n'"$hits"
# Positive control: each form is flagged on its own.  Negative control: the forms
# the shipped scripts do use are not, so the check is not flagging everything.
mkdir -p "$WORK/scan"
n=0
while IFS= read -r line; do
    n=$((n + 1)); printf '%s\n' "$line" > "$WORK/scan/bypass$n.sh"
    [ -n "$(jq_bypass_scan "$WORK/scan/bypass$n.sh")" ] || fail "jq bypass scan missed: $line"
done <<'EOF'
/usr/bin/jq -n 1
out=$(./tools/jq -n 1)
command -p jq -n 1
JQ=$(command -v jq)
jq_bin=`which jq`
hash -t jq
tool=jq
"$JQ" -n 1
${JQ_BIN} -n 1
env -i jq -n 1
PATH=/usr/bin:/bin jq -n 1
subprocess.run(["/usr/bin/jq", "-n", "1"])
path = shutil.which("jq")
EOF
cat > "$WORK/scan/clean.sh" <<'EOF'
jq -n 1
command -v jq >/dev/null 2>&1 || exit 64
_cr_jq_memo out "$x" -r .a; [ "${#_CR_JQ_MEMO[@]}" -lt 64 ]
dpkg -i /opt/pim/package/jq/*.deb
export PATH="$WORK/bin:$PATH"
EOF
hits=$(jq_bypass_scan "$WORK/scan/clean.sh") || die "jq bypass scan: control file unreadable"
[ -z "$hits" ] || fail "jq bypass scan flagged a plain PATH lookup: $hits"

# A booted board with a running app: owner ACTIVE, the startup's service-state
# and counter state on disk, ORD ready, all four consumers up, ISI children
# auto-bound.  Written by the real producers in a separate process so that the
# counted processes inherit nothing from it.
fresh_board() {
    local d
    rm -rf "${WORK:?}"/{run,state,proc,sys,dev,shm,processes,recordings}
    : > "$PIM_CAMERA_CALL_LOG"; : > "$WORK/procs.lock"
    printf 'boot\n' > "$PIM_CAMERA_BOOT_ID_FILE"
    mkdir -p "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID"
    { printf '%s' "$DAEMON_PID (cam-operate) S"; for _ in $(seq 1 18); do printf ' 0'; done; printf ' 111 0 0\n'; } > "$PIM_CAMERA_PROC_ROOT/$DAEMON_PID/stat"
    for d in mxc-mipi-csi2-sam mxc-isi isi-capture isi-m2m; do
        mkdir -p "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d"
        : > "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d/unbind"; : > "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/$d/bind"
    done
    touch "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/isi-capture/32e00000.isi:cap_device"
    touch "$PIM_CAMERA_SYSFS_ROOT/bus/platform/drivers/isi-m2m/32e00000.isi:m2m_device"
    mkdir -p "$PIM_CAMERA_DEVICE_ROOT" "$PIM_CAMERA_SHM_DIR" "$PIM_CAMERA_CONTROL_WORK_DIR" "$WORK/recordings" "$(dirname "$PIM_CAMERA_RUNTIME_JSON")"
    : > "$PIM_CAMERA_DEVICE_ROOT/video3"; : > "$PIM_CAMERA_DEVICE_ROOT/video4"
    jq -s --arg tmp "$WORK/recordings" '
        .[1] + {VHL_CAM:.[0].VHL_CAM, NETWORK:{ETH1:(.[0].NETWORK.ETH1 | {ping_check_enable, client_ip_addr, ping_max_fail_count})}}
        | .VHL_CAM.tmp_path=$tmp | .VHL_CAM.capture.enable=false
    ' "$EDGE_TEMPLATE" "$ORD_TEMPLATE" > "$PIM_CAMERA_RUNTIME_JSON"
    printf '%s\n' '20260901 12:34:56' > "$PIM_CAMERA_SESSION_TIME_FILE"
    printf 'active\n' > "$PIM_CAMERA_ORD_STATE_FILE"
    printf '0123456789abcdef0123456789abcdef\n' > "$PIM_CAMERA_RUN_DIR/ord-ready"
    printf 'gstApp\n%s\nord\nvcm\n' "$PIM_CAMERA_BG_CHECKER" > "$WORK/procs"
    mkdir -p "$PIM_CAMERA_PROCESS_ROOT/99"
    printf '%s' '99 (BG_Check_for_pim) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999 0' > "$PIM_CAMERA_PROCESS_ROOT/99/stat"
    printf '/bin/bash\000%s\0004\000' "$PIM_CAMERA_BG_CHECKER" > "$PIM_CAMERA_PROCESS_ROOT/99/cmdline"
    # shellcheck disable=SC2016 # expanded by the child shell
    PATH="$STUB_PATH" bash -c '
        set -e
        source "$PIM_LIB/cam_operate_control.sh"
        cam_owner_create "$1"; cam_owner_set_lifecycle ACTIVE
        _cr_state_init
        _coc_persist_success "$(_coc_projection "$PIM_CAMERA_RUNTIME_JSON")"
    ' fresh_board "$DAEMON_PID" || die "fixture: could not set up the board"
    : > "$PIM_CAMERA_CALL_LOG"
}

# Runs one counted process.  flock -s hands the lock to the command and every
# descendant (vcm is launched in the background); the exclusive flock after it
# waits until the last of them has exited, so no late jq escapes the count.
counted() {
    local log=$1 rc=0
    shift
    : > "$log"
    env PATH="$SHIM_PATH" JQ_BUDGET_LOG="$log" flock -s "$WORK/flow.lock" "$@" || rc=$?
    flock -x -w 60 "$WORK/flow.lock" true || die "a counted process left a child running for 60s"
    return "$rc"
}
lines() { wc -l < "$1" | tr -d ' '; }

run_flow() {
    local flow=$1 type daemon_env=() want_rc=0 rc id submit_n daemon_n total
    local result active pending owner_env=()
    case "$flow" in
        module_reload_fails) type=module_reload; daemon_env=(FAIL_MODPROBE=max9296 FAIL_REBOOT_RC=1); want_rc=1 ;;
        *) type=$flow ;;
    esac
    fresh_board
    # The daemon exported its owner context when it created the owner.
    mapfile -t owner_env < <(jq -r '"PIM_CAMERA_OWNER_BOOT_ID=\(.boot_id)", "PIM_CAMERA_OWNER_INVOCATION=\(.invocation_id)", "PIM_CAMERA_OWNER_PID=\(.pid)", "PIM_CAMERA_OWNER_PROC_START_TIME=\(.proc_start_time)", "PIM_CAMERA_OWNER_TOKEN=\(.token)", "PIM_CAMERA_OWNER_CREATED_AT=\(.created_at)"' "$PIM_CAMERA_RUN_DIR/owner.json")

    rc=0
    id=$(counted "$WORK/jq.$flow.submit" bash "$PIM_BIN/cam-recoveryctl" request "$type" --source jq-budget --reason "jq budget $type") || rc=$?
    [ "$rc" -eq 0 ] || { fail "$flow: submit rc=$rc"; return 0; }
    [ "$(jq -r .id "$PIM_CAMERA_RUN_DIR/recovery/pending.json")" = "$id" ] || { fail "$flow: submit did not leave its pending request"; return 0; }

    rc=0
    # shellcheck disable=SC2016 # expanded by the daemon shell
    counted "$WORK/jq.$flow.daemon" env "${owner_env[@]}" "${daemon_env[@]}" \
        bash -c 'enable -n kill; source "$PIM_LIB/cam_operate_control.sh"; cam_poll_pending_request' || rc=$?
    [ "$rc" -eq "$want_rc" ] || fail "$flow: cam_poll_pending_request rc=$rc, expected $want_rc"

    result="$PIM_CAMERA_RUN_DIR/recovery/results/$id.json"
    active="$PIM_CAMERA_RUN_DIR/recovery/active.json"; pending="$PIM_CAMERA_RUN_DIR/recovery/pending.json"
    [ ! -e "$active" ] || fail "$flow: active.json survived the request"
    [ ! -e "$pending" ] || fail "$flow: pending.json survived the request"
    if [ "$want_rc" -eq 0 ]; then
        jq -e --arg id "$id" --arg type "$type" '.id==$id and .type==$type and .status=="SUCCEEDED" and .rc==0' "$result" >/dev/null 2>&1 \
            || fail "$flow: no SUCCEEDED result ($(cat "$result" 2>/dev/null || echo absent))"
        [ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = ACTIVE ] || fail "$flow: owner did not return to ACTIVE"
    else
        assert_escalation_failed "$id" "$result"
    fi

    submit_n=$(lines "$WORK/jq.$flow.submit"); daemon_n=$(lines "$WORK/jq.$flow.daemon"); total=$((submit_n + daemon_n))
    printf 'jq budget: %-20s submit=%-3s daemon=%-4s total=%-4s ceiling=%s\n' "$flow" "$submit_n" "$daemon_n" "$total" "${CEILING[$flow]}"
    # Positive control: a flow that reached a terminal result cannot have spawned
    # no jq at all; zero means the shim was bypassed.
    if [ "$submit_n" -eq 0 ] || [ "$daemon_n" -eq 0 ]; then fail "$flow: the shim counted nothing (submit=$submit_n daemon=$daemon_n)"; fi
    [ "$total" -le "${CEILING[$flow]}" ] || fail "$flow: $total jq spawns, ceiling ${CEILING[$flow]}"
}

# module_reload -> camera_hard_reset -> reboot_fallback, each failing, then the
# request is failed with the last rc and the owner is left DEGRADED and dirty.
assert_escalation_failed() {
    local id=$1 result=$2 history="$PIM_CAMERA_STATE_DIR/recovery/history/$1.json"
    jq -e --arg id "$id" '.id==$id and .type=="module_reload" and .status=="FAILED" and .rc==1' "$result" >/dev/null 2>&1 \
        || fail "module_reload_fails: result is not FAILED/1 ($(cat "$result" 2>/dev/null || echo absent))"
    jq -e '.request.status=="FAILED" and .request.rc==1 and ([.actions[] | [.action,.status,.rc]] == [["module_reload","FAILED",23],["camera_hard_reset","FAILED",23],["reboot_fallback","FAILED",1]])' "$history" >/dev/null 2>&1 \
        || fail "module_reload_fails: history is not the failed escalation ($(jq -c '[.request.status,.request.rc,[.actions[]|[.action,.status,.rc]]]' "$history" 2>/dev/null || echo absent))"
    jq -e --arg id "$id" '[.actions.module_reload, .actions.camera_hard_reset, .actions.reboot_fallback] | map({attempted,succeeded,failed,consecutive_failures,last_request_id,last_status,last_rc})
        == [{attempted:1,succeeded:0,failed:1,consecutive_failures:1,last_request_id:$id,last_status:"FAILED",last_rc:23},
            {attempted:1,succeeded:0,failed:1,consecutive_failures:1,last_request_id:$id,last_status:"FAILED",last_rc:23},
            {attempted:1,succeeded:0,failed:1,consecutive_failures:1,last_request_id:$id,last_status:"FAILED",last_rc:1}]' \
        "$PIM_CAMERA_STATE_DIR/recovery/state.json" >/dev/null 2>&1 || fail "module_reload_fails: counters do not record three failures"
    [ "$(jq -r .lifecycle "$PIM_CAMERA_RUN_DIR/owner.json")" = DEGRADED ] || fail "module_reload_fails: owner is not DEGRADED"
    jq -e '.dirty==true and .degraded_reason=="jq budget module_reload" and .degraded_target=="camera_health"' "$PIM_CAMERA_STATE_DIR/service-state.json" >/dev/null 2>&1 \
        || fail "module_reload_fails: service-state is not dirty/camera_health ($(cat "$PIM_CAMERA_STATE_DIR/service-state.json"))"
    [ "$(grep -c '^reboot ' "$PIM_CAMERA_CALL_LOG" || true)" -eq 1 ] || fail "module_reload_fails: reboot was not requested exactly once"
}

for flow in "${FLOWS[@]}"; do run_flow "$flow"; done

# Positive control: one known jq through the same PATH adds exactly one line.
: > "$WORK/jq.control"
env PATH="$SHIM_PATH" JQ_BUDGET_LOG="$WORK/jq.control" jq -n 1 >/dev/null
[ "$(lines "$WORK/jq.control")" -eq 1 ] || fail "control: one jq -n 1 counted $(lines "$WORK/jq.control") times"

[ "$failures" -eq 0 ] || die "jq budget: $failures failure(s)"
echo "jq budget: PASS"
