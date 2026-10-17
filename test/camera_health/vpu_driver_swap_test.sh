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
esac
d="$CASE/sys/bus/platform/drivers/mxc_hantro_vc8000e_ext"
mkdir -p "$d"; : > "$d/bind"; : > "$d/unbind"
EOF
chmod +x "$WORK/bin/logger" "$WORK/bin/fake_insmod"

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
            [ "${FAIL_UNBIND:-0}" = 1 ] && return 1
            drv=${file%/unbind}; drv=${drv##*/}
            [ "$(link_of)" = "$drv" ] || return 1
            rm -f "$devdir/driver" ;;
        */bind)
            drv=${file%/bind}; drv=${drv##*/}
            local var="FAIL_BIND_$drv"
            [ "${!var:-0}" = 1 ] && return 1
            local ovr; ovr=$(cat "$devdir/driver_override")
            [ -z "$ovr" ] || [ "$ovr" = "(null)" ] || [ "$ovr" = "$drv" ] || return 1
            ln -s "../../../bus/platform/drivers/$drv" "$devdir/driver" ;;
    esac
}

run_sourced() {  # 스크립트를 source 하고 sysfs_write 를 가짜 커널로 바꿔 main 을 돈다
    (
        set +e   # 운영 실행처럼 set -u 만 둔 채로 돈다(스크립트가 set -u 를 다시 켠다)
        export PATH="$WORK/bin:$PATH" PIM_VPU_SYSFS_ROOT="$CASE/sys" PIM_VPU_PROC_ROOT="$CASE/proc" \
            PIM_VPU_MODULE="$CASE/hantro_vc8000e_ext.ko" PIM_VPU_INSMOD="$WORK/bin/fake_insmod"
        # shellcheck source=/dev/null
        . "$SCRIPT"
        sysfs_write() { fake_kernel_write "$@"; }
        main
    ) 2> "$CASE/stderr"
}

run_exec() {  # 스크립트를 그대로 실행한다(실제 sysfs_write, 종료 코드)
    env PATH="$WORK/bin:$PATH" PIM_VPU_SYSFS_ROOT="$CASE/sys" PIM_VPU_PROC_ROOT="$CASE/proc" \
        PIM_VPU_MODULE="$CASE/hantro_vc8000e_ext.ko" PIM_VPU_INSMOD="$WORK/bin/fake_insmod" \
        "$SCRIPT" 2> "$CASE/stderr"
}

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
expect "already bound: logged" logged "already bound to $EXT"

setup nodevice
rm -rf "$CASE/sys/bus/platform/devices/$DEVICE"
run_sourced
expect "no device: nothing is touched" no_calls
expect "no device: logged" logged "skip: no device $DEVICE"

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
ln -s /dev/mxc_hantro_vc8000e "$CASE/proc/4321/fd/7"
run_sourced
expect "device open: no insmod, no unbind" no_calls
expect "device open: builtin still bound" [ "$(link_of)" = "$BUILTIN" ]
expect "device open: holder pid is logged" logged "is open by pid 4321"

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
expect "both binds fail: the failure is logged loudly" logged "VPU encoder is unbound"
expect "both binds fail: the failure also reaches the journal" grep -qF "VPU encoder is unbound" "$CASE/stderr"

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

echo '=== packaging contract ==='
UNIT="$ROOT/dist/pim/etc/systemd/system/pim-vpu-driver.service"
CAM_UNIT="$ROOT/dist/pim/etc/systemd/system/cam-operate.service"
POSTINST="$ROOT/dist/pim/DEBIAN/postinst"
expect "unit: ordered before cam-operate" grep -qx 'Before=cam-operate.service' "$UNIT"
expect "unit: oneshot that stays active" sh -c 'grep -qx "Type=oneshot" "$1" && grep -qx "RemainAfterExit=yes" "$1"' _ "$UNIT"
expect "unit: runs the swap script" grep -qx 'ExecStart=/opt/pim/bin/vpu_driver_swap.sh' "$UNIT"
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
