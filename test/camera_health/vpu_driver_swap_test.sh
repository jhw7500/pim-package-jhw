#!/bin/bash
# Offline tests for vpu_driver_swap.sh (#194): moving the VC8000E encoder device from the built-in
# driver to the imx-hantro fixed module, and every path that must leave the built-in driver in place.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/dist/pim/opt/pim/bin/vpu_driver_swap.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vpu-driver-swap-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

DEVICE=38320000.vpu_vc8000e
BUILTIN=mxc_hantro_vc8000e
EXT=mxc_hantro_vc8000e_ext

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  OK   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1" >&2; }
expect() {  # expect <description> <command...>
    local what=$1; shift
    if "$@"; then ok "$what"; else bad "$what"; fi
}

# 보유자 판정은 장치 번호로 비교하므로 VPU 장치 노드 대신 /dev/zero 를 쓴다. /dev/null 은 다른 장치다.
VPU_NODE=/dev/zero

# 외부 명령 스텁: logger 는 기록만, insmod 는 FAKE_INSMOD 로 동작을 고른다.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/logger" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/logger.log"
EOF
cat > "$WORK/bin/fake_insmod" <<'EOF'
#!/bin/bash
printf 'insmod %s\n' "$1" >> "$CASE/calls"
case "${FAKE_INSMOD:-ok}" in
    fail) echo "insmod: ERROR: could not insert module: Invalid module format" >&2; exit 1 ;;
    noreg) exit 0 ;;
    open) mkdir -p "$CASE/proc/999/fd"; ln -s /dev/zero "$CASE/proc/999/fd/3" ;;
esac
d="$CASE/sys/bus/platform/drivers/mxc_hantro_vc8000e_ext"
mkdir -p "$d"; : > "$d/bind"; : > "$d/unbind"
EOF
cat > "$WORK/bin/fake_systemctl" <<'EOF'
#!/bin/bash
# show -p ActiveState --value cam-operate.service: FAKE_CAM_STATE 를 출력한다(기본 inactive).
# queryfail 이면 조회가 실패하고, empty 면 아무것도 출력하지 않는다.
# is-active 는 그 값이 active 일 때만 성공한다(#194 판정과 같은 상태를 보인다).
state=${FAKE_CAM_STATE:-inactive}
case "$1" in
    show) [ "$state" = queryfail ] && exit 1; [ "$state" = empty ] || printf '%s\n' "$state" ;;
    is-active) [ "$state" = active ] ;;
    *) exit 1 ;;
esac
EOF
cat > "$WORK/bin/fake_stat" <<'EOF'
#!/bin/bash
# 여러 파일을 한 번에 묻는 호출(보유자 목록)만 바꾼다. 나머지는 진짜 stat 이다.
# FAKE_STAT=broken 이면 255 로 끝나고(xargs 가 멈춘다), silent 면 출력 없이 1 로 끝난다(모든 stat 실패).
if [ "$#" -gt 4 ]; then
    case "${FAKE_STAT:-}" in
        broken) exit 255 ;;
        silent) exit 1 ;;
    esac
fi
exec stat "$@"
EOF
chmod +x "$WORK/bin/logger" "$WORK/bin/fake_insmod" "$WORK/bin/fake_systemctl" "$WORK/bin/fake_stat"

setup() {  # setup <name>: 내장 드라이버에 붙은 장치, 모듈 파일, 빈 /proc
    CASE="$WORK/$1"
    export CASE
    local devdir="$CASE/sys/bus/platform/devices/$DEVICE"
    mkdir -p "$devdir" "$CASE/sys/bus/platform/drivers/$BUILTIN" "$CASE/proc/1/fd"
    : > "$CASE/sys/bus/platform/drivers/$BUILTIN/bind"
    : > "$CASE/sys/bus/platform/drivers/$BUILTIN/unbind"
    printf '(null)\n' > "$devdir/driver_override"
    ln -s "../../../bus/platform/drivers/$BUILTIN" "$devdir/driver"
    ln -s /dev/null "$CASE/proc/1/fd/0"   # 다른 장치를 연 프로세스는 막지 않아야 한다
    : > "$CASE/hantro_vc8000e_ext.ko"
    : > "$CASE/calls"
    : > "$CASE/logger.log"
}

link_of() { local l; l=$(readlink "$CASE/sys/bus/platform/devices/$DEVICE/driver" 2>/dev/null) || { echo none; return; }; echo "${l##*/}"; }
rc_is() { [ "$(cat "$CASE/rc")" = "$1" ]; }
unbind_now() { rm -f "$CASE/sys/bus/platform/devices/$DEVICE/driver"; }
calls_are() { [ "$(cat "$CASE/calls")" = "$1" ]; }
no_calls() { [ ! -s "$CASE/calls" ]; }
logged() { grep -qF -- "$1" "$CASE/logger.log"; }

# 가짜 커널: unbind/bind 가 드라이버 링크를 바꾼다. FAIL_BIND_<드라이버>=1 이면 그 bind 가 실패한다.
fake_kernel_write() {
    local file=$1 value=$2 drv devdir="$CASE/sys/bus/platform/devices/$DEVICE"
    printf 'sysfs %s %s\n' "${file#"$CASE"/sys/}" "$value" >> "$CASE/calls"
    case "$file" in
        */driver_override) printf '%s\n' "$value" > "$file" ;;
        */unbind)
            [ -e "$file" ] || return 1
            [ "${FAIL_UNBIND:-0}" = 1 ] && return 1
            drv=${file%/unbind}; drv=${drv##*/}
            [ "$(link_of)" = "$drv" ] || return 1
            rm -f "$devdir/driver" ;;
        */bind)
            [ -e "$file" ] || return 1
            drv=${file%/bind}; drv=${drv##*/}
            local var="FAIL_BIND_$drv"
            [ "${!var:-0}" = 1 ] && return 1
            local ovr; ovr=$(cat "$devdir/driver_override")
            [ -z "$ovr" ] || [ "$ovr" = "(null)" ] || [ "$ovr" = "$drv" ] || return 1
            ln -s "../../../bus/platform/drivers/$drv" "$devdir/driver" ;;
    esac
}

run_sourced() {  # run_sourced [main|recover]: 스크립트를 source 하고 sysfs_write 를 가짜 커널로 바꿔 돈다.
    # 반환값은 $CASE/rc 에 남긴다(rc_is 로 본다). TEST_DEV_NODE·TEST_STAT 로 장치 노드와 stat 을 바꾼다.
    local fn=${1:-main} rc=0
    (
        set +e   # 운영 실행처럼 set -u 만 둔 채로 돈다(스크립트가 set -u 를 다시 켠다)
        export PATH="$WORK/bin:$PATH" PIM_VPU_SYSFS_ROOT="$CASE/sys" PIM_VPU_PROC_ROOT="$CASE/proc" \
            PIM_VPU_MODULE="$CASE/hantro_vc8000e_ext.ko" PIM_VPU_INSMOD="$WORK/bin/fake_insmod" \
            PIM_VPU_SYSTEMCTL="$WORK/bin/fake_systemctl" PIM_VPU_DEV_NODE="${TEST_DEV_NODE:-$VPU_NODE}" \
            PIM_VPU_STAT="${TEST_STAT:-stat}" PIM_VPU_LOCK="$CASE/lock"
        # shellcheck source=/dev/null
        . "$SCRIPT"
        sysfs_write() { fake_kernel_write "$@"; }
        "$fn"
    ) 2> "$CASE/stderr" || rc=$?
    echo "$rc" > "$CASE/rc"
}

run_exec() {  # run_exec [args...]: 스크립트를 그대로 실행한다(실제 sysfs_write, 종료 코드)
    env PATH="$WORK/bin:$PATH" PIM_VPU_SYSFS_ROOT="$CASE/sys" PIM_VPU_PROC_ROOT="$CASE/proc" \
        PIM_VPU_MODULE="$CASE/hantro_vc8000e_ext.ko" PIM_VPU_INSMOD="$WORK/bin/fake_insmod" \
        PIM_VPU_SYSTEMCTL="$WORK/bin/fake_systemctl" PIM_VPU_DEV_NODE="$VPU_NODE" \
        PIM_VPU_LOCK="$CASE/lock" "$SCRIPT" "$@" 2> "$CASE/stderr"
}

hold_lock() { exec 8>"$CASE/lock"; flock -n 8; }   # 다른 전환이 잠금을 쥔 상태를 만든다
drop_lock() { exec 8>&-; }

echo '=== vpu driver swap ==='

setup swap
run_sourced
expect "swap: device ends on $EXT" [ "$(link_of)" = "$EXT" ]
expect "swap: insmod -> unbind builtin -> override -> bind ext, in that order" calls_are "insmod $CASE/hantro_vc8000e_ext.ko
sysfs bus/platform/drivers/$BUILTIN/unbind $DEVICE
sysfs bus/platform/devices/$DEVICE/driver_override $EXT
sysfs bus/platform/drivers/$EXT/bind $DEVICE"
expect "swap: success is logged" logged "bound $DEVICE to $EXT"

setup already
rm "$CASE/sys/bus/platform/devices/$DEVICE/driver"
mkdir -p "$CASE/sys/bus/platform/drivers/$EXT"
ln -s "../../../bus/platform/drivers/$EXT" "$CASE/sys/bus/platform/devices/$DEVICE/driver"
run_sourced
expect "already bound: nothing is touched" no_calls
expect "already bound: logged at notice (reaches local0.log)" grep -qE "^-p local0\.notice \[VPU-DRV\]\[[^]]+\] already bound to $EXT$" "$CASE/logger.log"

setup nodevice
rm -rf "$CASE/sys/bus/platform/devices/$DEVICE"
run_sourced
expect "no device: nothing is touched" no_calls
expect "no device: logged" logged "skip: no device $DEVICE"

# 드라이버가 없는 장치는 성공으로 넘기지 않고 내장 드라이버로 되돌린다(#196)
setup nodriver
unbind_now
run_sourced
expect "no driver at start: device goes back to $BUILTIN" [ "$(link_of)" = "$BUILTIN" ]
expect "no driver at start: no insmod, no unbind" sh -c '! grep -qE "^insmod|/unbind " "$CASE/calls"'
expect "no driver at start: returns 0 once restored" rc_is 0

setup nodriverfail
unbind_now
FAIL_BIND_mxc_hantro_vc8000e=1 run_sourced
expect "no driver at start, restore fails: returns 1" rc_is 1
expect "no driver at start, restore fails: err logged" logged "VPU encoder is unbound"

setup otherdrv
rm "$CASE/sys/bus/platform/devices/$DEVICE/driver"
ln -s "../../../bus/platform/drivers/somebody" "$CASE/sys/bus/platform/devices/$DEVICE/driver"
run_sourced
expect "unexpected driver: nothing is touched" no_calls
expect "unexpected driver: logged" logged "bound to 'somebody', expected $BUILTIN"

setup nomodule
rm "$CASE/hantro_vc8000e_ext.ko"
run_sourced
expect "module missing: no insmod, builtin kept" no_calls
expect "module missing: builtin still bound" [ "$(link_of)" = "$BUILTIN" ]

setup holder
mkdir -p "$CASE/proc/4321/fd"
ln -s "$VPU_NODE" "$CASE/proc/4321/fd/7"
run_sourced
expect "device open: no insmod, no unbind" no_calls
expect "device open: builtin still bound" [ "$(link_of)" = "$BUILTIN" ]
expect "device open: holder pid is logged" logged "is open by pid 4321"

# 다른 mount namespace 처럼 다른 경로로 받은 같은 장치: 경로가 아니라 장치 번호로 잡아야 한다(#196)
setup holderotherpath
ln -s "$VPU_NODE" "$CASE/vpu-in-container"
mkdir -p "$CASE/proc/4322/fd"
ln -s "$CASE/vpu-in-container" "$CASE/proc/4322/fd/5"
run_sourced
expect "device open under another path: no insmod, no unbind" no_calls
expect "device open under another path: holder pid is logged" logged "is open by pid 4322"

# fd 를 닫고 매핑만 남긴 프로세스(#196)
setup mmaponly
mkdir -p "$CASE/proc/5555/map_files"
ln -s "$VPU_NODE" "$CASE/proc/5555/map_files/ffff8000-ffff9000"
run_sourced
expect "device only mapped: no insmod, no unbind" no_calls
expect "device only mapped: holder pid is logged" logged "is open by pid 5555"

setup nodevnode
TEST_DEV_NODE="$CASE/no-such-node" run_sourced
expect "device node unreadable: no insmod, no unbind" no_calls
expect "device node unreadable: logged" logged "cannot read the device number of $CASE/no-such-node"

setup holderlistfail
FAKE_STAT=broken TEST_STAT="$WORK/bin/fake_stat" run_sourced
expect "holder listing fails: no insmod, no unbind" no_calls
expect "holder listing fails: logged" logged "cannot list processes using $VPU_NODE"

setup holderlistempty
FAKE_STAT=silent TEST_STAT="$WORK/bin/fake_stat" run_sourced
expect "holder listing empty (every stat failed): no insmod, no unbind" no_calls
expect "holder listing empty (every stat failed): logged" logged "cannot list processes using $VPU_NODE"

setup camactive
FAKE_CAM_STATE=active run_sourced
expect "cam-operate active: no insmod, no unbind" no_calls
expect "cam-operate active: builtin still bound" [ "$(link_of)" = "$BUILTIN" ]
expect "cam-operate active: logged" logged "skip: cam-operate is active"

# 시작 중(ExecStartPost 대기 등)이나 정지 중에도 gstApp 이 장치를 열 수 있다(#196)
for state in activating deactivating reloading; do
    setup "cam$state"
    FAKE_CAM_STATE=$state run_sourced
    expect "cam-operate $state: no insmod, no unbind" no_calls
    expect "cam-operate $state: logged" logged "skip: cam-operate is $state"
done

setup camqueryfail
FAKE_CAM_STATE=queryfail run_sourced
expect "cam-operate state unknown (query fails): no insmod, no unbind" no_calls
expect "cam-operate state unknown (query fails): logged" logged "skip: cam-operate is unknown"

setup camempty
FAKE_CAM_STATE=empty run_sourced
expect "cam-operate state unknown (empty): no insmod, no unbind" no_calls

setup camfailed
FAKE_CAM_STATE=failed run_sourced
expect "cam-operate failed (not running): device still moved" [ "$(link_of)" = "$EXT" ]

setup locked
hold_lock
run_sourced
drop_lock
expect "another run holds the lock: nothing is touched" no_calls
expect "another run holds the lock: logged" logged "skip: another run holds $CASE/lock"

setup openedduringinsmod
FAKE_INSMOD=open run_sourced
expect "opened during insmod: rechecked before unbind, no unbind" calls_are "insmod $CASE/hantro_vc8000e_ext.ko"
expect "opened during insmod: builtin still bound" [ "$(link_of)" = "$BUILTIN" ]
expect "opened during insmod: logged with pid" logged "was opened by pid 999 before unbind"

setup insmodfail
FAKE_INSMOD=fail run_sourced
expect "insmod fails: only the insmod call, no unbind" calls_are "insmod $CASE/hantro_vc8000e_ext.ko"
expect "insmod fails: builtin still bound" [ "$(link_of)" = "$BUILTIN" ]
expect "insmod fails: error text is logged" logged "Invalid module format"

setup noreg
FAKE_INSMOD=noreg run_sourced
expect "driver not registered: no unbind" calls_are "insmod $CASE/hantro_vc8000e_ext.ko"
expect "driver not registered: builtin still bound" [ "$(link_of)" = "$BUILTIN" ]

setup loaded
mkdir -p "$CASE/sys/bus/platform/drivers/$EXT"
: > "$CASE/sys/bus/platform/drivers/$EXT/bind"; : > "$CASE/sys/bus/platform/drivers/$EXT/unbind"
run_sourced
expect "module already loaded: no second insmod" sh -c '! grep -q "^insmod" "$CASE/calls"'
expect "module already loaded: device still moved" [ "$(link_of)" = "$EXT" ]

setup unbindfail
FAIL_UNBIND=1 run_sourced
expect "unbind fails: override is not written" sh -c '! grep -q driver_override "$CASE/calls"'
expect "unbind fails: builtin still bound" [ "$(link_of)" = "$BUILTIN" ]

setup bindfail
FAIL_BIND_mxc_hantro_vc8000e_ext=1 run_sourced
expect "ext bind fails: device goes back to $BUILTIN" [ "$(link_of)" = "$BUILTIN" ]
expect "ext bind fails: override cleared before rebinding builtin" sh -c 'tail -2 "$CASE/calls" | head -1 | grep -qx "sysfs bus/platform/devices/'"$DEVICE"'/driver_override "'
expect "ext bind fails: restore is logged" logged "restored $DEVICE to $BUILTIN"

setup bothfail
FAIL_BIND_mxc_hantro_vc8000e_ext=1 FAIL_BIND_mxc_hantro_vc8000e=1 run_sourced
expect "both binds fail: device is left unbound" [ "$(link_of)" = none ]
expect "both binds fail: main returns 1 so the unit fails and ExecStopPost retries (#196)" rc_is 1
expect "both binds fail: the failure is logged loudly" logged "VPU encoder is unbound"
expect "both binds fail: the failure also reaches the journal" grep -qF "VPU encoder is unbound" "$CASE/stderr"
expect "both binds fail: journal line carries err priority <3>" grep -qE "^<3>\[VPU-DRV\].*VPU encoder is unbound" "$CASE/stderr"

echo '=== recover (ExecStopPost) ==='

# 시간 초과로 override 를 쓴 뒤 bind 전에 끊긴 상태
setup recovertimeout
unbind_now
printf '%s\n' "$EXT" > "$CASE/sys/bus/platform/devices/$DEVICE/driver_override"
SERVICE_RESULT=timeout run_sourced recover
expect "recover after timeout: device goes back to $BUILTIN" [ "$(link_of)" = "$BUILTIN" ]
expect "recover after timeout: override cleared, then builtin bound" calls_are \
    "$(printf 'sysfs bus/platform/devices/%s/driver_override \nsysfs bus/platform/drivers/%s/bind %s' "$DEVICE" "$BUILTIN" "$DEVICE")"
expect "recover after timeout: returns 0" rc_is 0
expect "recover after timeout: logged with the service result" logged "recover: $DEVICE has no driver after timeout"

setup recoverbound
SERVICE_RESULT=exit-code run_sourced recover
expect "recover with a driver bound: nothing is touched" no_calls
expect "recover with a driver bound: returns 0" rc_is 0

setup recoversuccess
unbind_now
SERVICE_RESULT=success run_sourced recover
expect "recover on a normal stop (success): nothing is touched even if unbound" no_calls

setup recovermanual
unbind_now
run_sourced recover
expect "recover run by hand: device goes back to $BUILTIN" [ "$(link_of)" = "$BUILTIN" ]
expect "recover run by hand: logged" logged "no driver after a manual run"

setup recoverfails
unbind_now
FAIL_BIND_mxc_hantro_vc8000e=1 SERVICE_RESULT=exit-code run_sourced recover
expect "recover fails: returns 1" rc_is 1
expect "recover fails: err reaches the journal" grep -qE "^<3>\[VPU-DRV\].*VPU encoder is unbound" "$CASE/stderr"

# 전환이 커널에서 막혀 아직 잠금을 쥔 상태: driver 링크는 probe 전에 생기므로 링크만 보고 판단하면 안 된다
setup recoverlocked
unbind_now
hold_lock
SERVICE_RESULT=timeout run_sourced recover
drop_lock
expect "recover while a swap still runs: nothing is touched even though unbound" no_calls
expect "recover while a swap still runs: device left as found" [ "$(link_of)" = none ]
expect "recover while a swap still runs: returns 1" rc_is 1
expect "recover while a swap still runs: err reaches the journal" grep -qE "^<3>\[VPU-DRV\].*recover: a swap still holds" "$CASE/stderr"

# 실제 실행: 진짜 sysfs_write 가 무엇을 쓰는지와 종료 코드. 보통 파일이라 링크가 바뀌지 않으므로
# bind 확인에서 실패해 복구 경로까지 탄다.
setup exec
rc=0; run_exec || rc=$?
expect "executed: exit code is 0 even when the swap fails" [ "$rc" -eq 0 ]
expect "executed: unbind file received the device name" [ "$(cat "$CASE/sys/bus/platform/drivers/$BUILTIN/unbind")" = "$DEVICE" ]
expect "executed: ext bind file received the device name" [ "$(cat "$CASE/sys/bus/platform/drivers/$EXT/bind")" = "$DEVICE" ]
expect "executed: driver_override ends cleared" [ -z "$(cat "$CASE/sys/bus/platform/devices/$DEVICE/driver_override")" ]
expect "executed: builtin bind file received the device name" [ "$(cat "$CASE/sys/bus/platform/drivers/$BUILTIN/bind")" = "$DEVICE" ]

setup execfail
rc=0; FAKE_INSMOD=fail run_exec || rc=$?
expect "executed insmod failure: exit code is 0" [ "$rc" -eq 0 ]
expect "executed insmod failure: warning reaches the journal" grep -qF "insmod" "$CASE/stderr"
expect "executed insmod failure: journal line carries warning priority <4>" grep -qE "^<4>\[VPU-DRV\].*insmod" "$CASE/stderr"

# 실제 쓰기 실패: unbind 파일이 /dev/full 이면 printf 가 실패한다 → 감지하고 override 를 쓰지 않아야 한다
setup execwritefail
rm "$CASE/sys/bus/platform/drivers/$BUILTIN/unbind"
ln -s /dev/full "$CASE/sys/bus/platform/drivers/$BUILTIN/unbind"
rc=0; run_exec || rc=$?
expect "executed write failure: exit code is 0" [ "$rc" -eq 0 ]
expect "executed write failure: unbind failure detected and logged" logged "unbind of $DEVICE from $BUILTIN failed"
expect "executed write failure: driver_override untouched" [ "$(cat "$CASE/sys/bus/platform/devices/$DEVICE/driver_override")" = "(null)" ]

# 실제 실행에서 되돌리기 쓰기까지 실패: 장치에 드라이버가 없을 수 있으니 1 로 끝나 유닛이 실패해야 한다(#196)
setup execbothfail
rm "$CASE/sys/bus/platform/drivers/$BUILTIN/bind"
ln -s /dev/full "$CASE/sys/bus/platform/drivers/$BUILTIN/bind"
rc=0; run_exec || rc=$?
expect "executed restore failure: exit code is 1" [ "$rc" -eq 1 ]
expect "executed restore failure: err reaches the journal" grep -qE "^<3>\[VPU-DRV\].*restore of $DEVICE to $BUILTIN failed" "$CASE/stderr"

setup execrecover
unbind_now
rc=0; SERVICE_RESULT=exit-code run_exec --recover || rc=$?
expect "executed --recover: builtin bind file received the device name" [ "$(cat "$CASE/sys/bus/platform/drivers/$BUILTIN/bind")" = "$DEVICE" ]
expect "executed --recover: driver_override cleared" [ -z "$(cat "$CASE/sys/bus/platform/devices/$DEVICE/driver_override")" ]
expect "executed --recover: exit code is 1 when the device still has no driver" [ "$rc" -eq 1 ]
expect "executed --recover: does not run the swap (no unbind written)" [ ! -s "$CASE/sys/bus/platform/drivers/$BUILTIN/unbind" ]

echo '=== packaging contract ==='
UNIT="$ROOT/dist/pim/etc/systemd/system/pim-vpu-driver.service"
CAM_UNIT="$ROOT/dist/pim/etc/systemd/system/cam-operate.service"
POSTINST="$ROOT/dist/pim/DEBIAN/postinst"
expect "unit: ordered before cam-operate" grep -qx 'Before=cam-operate.service' "$UNIT"
expect "unit: oneshot that stays active" sh -c 'grep -qx "Type=oneshot" "$1" && grep -qx "RemainAfterExit=yes" "$1"' _ "$UNIT"
expect "unit: runs the swap script" grep -qx 'ExecStart=/opt/pim/bin/vpu_driver_swap.sh' "$UNIT"
expect "unit: recovers an unbound device after a timeout or failure (#196)" \
    grep -qx 'ExecStopPost=/opt/pim/bin/vpu_driver_swap.sh --recover' "$UNIT"
expect "unit: short stop timeout so a hung swap does not hold cam-operate for minutes" grep -qx 'TimeoutStopSec=10s' "$UNIT"
expect "unit: installed into multi-user.target" grep -qx 'WantedBy=multi-user.target' "$UNIT"
expect "cam-operate does not require the swap unit (a failed swap must not block it)" \
    sh -c '! grep -E "^(Requires|BindsTo|Requisite)=.*pim-vpu-driver" "$1"' _ "$CAM_UNIT"
expect "postinst enables the swap unit" grep -qE '^[[:space:]]*customctl enable pim-vpu-driver$' "$POSTINST"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mode=$(git -C "$ROOT" ls-files -s dist/pim/opt/pim/bin/vpu_driver_swap.sh | cut -d' ' -f1)
    expect "swap script is committed executable (100755)" [ "$mode" = 100755 ]
else
    echo '  SKIP swap script git mode (not a git checkout)'
fi

echo "vpu_driver_swap_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
