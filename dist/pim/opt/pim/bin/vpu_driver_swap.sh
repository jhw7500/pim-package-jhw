#!/bin/bash
# 부팅 때 VPU 인코더 장치를 커널 내장 드라이버에서 imx-hantro 의 수정 모듈로 옮겨 붙인다 (#194).
#
# 내장 드라이버(mxc_hantro_vc8000e)는 코어 예약을 스레드 id 로 해제해, 예약하지 않은 스레드가
# 마지막 close 를 하면 예약이 영구히 남고 모든 인코딩이 멈춘다(#191). 수정 모듈
# (hantro_vc8000e_ext.ko, 드라이버 mxc_hantro_vc8000e_ext)은 열린 파일로 해제한다.
# 내장이라 .ko 를 두는 것만으로는 대체되지 않으므로 장치를 직접 옮긴다.
#
# cam-operate 보다 먼저(pim-vpu-driver.service) 한 번 돈다. 장치를 열거나 매핑한 프로세스가 있으면
# 건드리지 않는다 — 드라이버 cleanup 이 열린 fd 가 가리키는 메모리를 해제하기 때문이다. 옮기지
# 못하면 내장 드라이버로 남기고 0 으로 끝난다. 내장 드라이버로 되돌리기까지 실패하면 1 로 끝나고,
# 유닛의 ExecStopPost(--recover)가 한 번 더 되돌린다. 시작이 시간 초과로 끊겨도 같은 경로를 탄다(#196).
# cam-operate 는 Before= 순서만 받으므로 어느 경우에도 기동한다.
set -u

KEY=VPU-DRV
tag=$(basename "$0")
SYSFS_ROOT="${PIM_VPU_SYSFS_ROOT:-/sys}"
PROC_ROOT="${PIM_VPU_PROC_ROOT:-/proc}"
MODULE="${PIM_VPU_MODULE:-/opt/pim/driver/hantro_vc8000e_ext.ko}"
INSMOD="${PIM_VPU_INSMOD:-insmod}"
SYSTEMCTL="${PIM_VPU_SYSTEMCTL:-systemctl}"
STAT="${PIM_VPU_STAT:-stat}"
DEV_NODE="${PIM_VPU_DEV_NODE:-/dev/mxc_hantro_vc8000e}"
LOCK="${PIM_VPU_LOCK:-/run/pim-vpu-driver.lock}"
DEVICE=38320000.vpu_vc8000e
BUILTIN=mxc_hantro_vc8000e
EXT=mxc_hantro_vc8000e_ext

dev_dir="$SYSFS_ROOT/bus/platform/devices/$DEVICE"
drv_dir="$SYSFS_ROOT/bus/platform/drivers"

log() {  # log <level> <message>: local0 로그(notice 이상만 local0.log 에 남는다). warning 이상은 journal 에도 남긴다.
    logger -p "local0.$1" "[$KEY][$tag] $2" 2>/dev/null || true
    # <N> 접두는 journald 가 우선순위로 읽는다(SyslogLevelPrefix 기본값). 없으면 info 로 저장된다.
    case "$1" in
        warning) printf '<4>[%s][%s][%s] %s\n' "$KEY" "$tag" "$1" "$2" >&2 ;;
        err) printf '<3>[%s][%s][%s] %s\n' "$KEY" "$tag" "$1" "$2" >&2 ;;
    esac
}

cam_operate_state() {  # cam-operate 의 ActiveState 를 출력한다. 조회에 실패하면 아무것도 출력하지 않는다.
    # 부팅 때는 Before= 순서로 시작 잡이 기다리는 중이라 inactive 다.
    "$SYSTEMCTL" show -p ActiveState --value cam-operate.service 2>/dev/null || true
}

take_lock() {  # 전환이 겹쳐 돌지 않게 하고, --recover 가 아직 끝나지 않은 전환을 알아보게 한다.
    { exec 9>"$LOCK"; } 2>/dev/null && flock -n 9
}

sysfs_write() {  # sysfs_write <file> <value>: 빈 값이면 개행만 써서 driver_override 를 비운다.
    { printf '%s\n' "$2" > "$1"; } 2>/dev/null
}

current_driver() {
    local link
    link=$(readlink "$dev_dir/driver" 2>/dev/null) || return 1
    printf '%s\n' "${link##*/}"
}

dev_rdev() {  # 장치 노드의 major:minor(16진)를 출력한다. 문자 장치가 아니거나 못 읽으면 실패한다.
    [ -c "$DEV_NODE" ] || return 1
    "$STAT" -L -c '%t:%T' "$DEV_NODE" 2>/dev/null
}

holders() {  # holders <rdev>: 장치를 fd 로 열었거나 메모리에 매핑한 프로세스 pid 를 공백으로 구분해 출력한다.
    # 경로가 아니라 장치 번호로 비교한다 — 다른 경로(다른 mount namespace 등)로 받은 장치도 잡는다.
    # fd 를 닫고 매핑만 남긴 프로세스는 map_files 로 잡는다. stat 을 돌리지 못하면 실패한다.
    local rdev=$1 listing rc line pid out=""
    listing=$(printf '%s\0' "$PROC_ROOT"/[0-9]*/fd/* "$PROC_ROOT"/[0-9]*/map_files/* |
        xargs -0 "$STAT" -L -c '%t:%T %n' 2>/dev/null)
    rc=$?
    # 123 은 사이에 사라진 프로세스 등으로 일부 stat 이 실패한 것이다. 그 밖의 값은 stat 을 못 돌린 것이다.
    [ "$rc" -eq 0 ] || [ "$rc" -eq 123 ] || return 1
    # 이 스크립트 자신의 fd 만으로도 목록은 비지 않는다. 비었으면 stat 이 모두 실패한 것이다.
    [ -n "$listing" ] || return 1
    while IFS= read -r line; do
        [ "${line%% *}" = "$rdev" ] || continue
        pid=${line#*" $PROC_ROOT"/}
        pid=${pid%%/*}
        case " $out " in *" $pid "*) ;; *) out="${out:+$out }$pid" ;; esac
    done <<< "$listing"
    printf '%s' "$out"
}

restore_builtin() {  # 되돌리지 못하면(장치에 드라이버가 없으면) 1 을 돌려준다.
    sysfs_write "$dev_dir/driver_override" ""
    if sysfs_write "$drv_dir/$BUILTIN/bind" "$DEVICE" && [ "$(current_driver)" = "$BUILTIN" ]; then
        log warning "restored $DEVICE to $BUILTIN"
        return 0
    fi
    log err "restore of $DEVICE to $BUILTIN failed — VPU encoder is unbound (driver=$(current_driver || echo none))"
    return 1
}

main() {
    local cur owners out state rdev
    [ -d "$dev_dir" ] || { log notice "skip: no device $DEVICE"; return 0; }
    if ! take_lock; then
        log warning "skip: another run holds $LOCK (driver left as is)"
        return 0
    fi
    cur=$(current_driver) || cur=""
    if [ "$cur" = "$EXT" ]; then
        log notice "already bound to $EXT"
        return 0
    fi
    if [ -z "$cur" ]; then
        # 드라이버가 없는 장치(앞선 전환이 끊겼거나 probe 실패)를 성공으로 넘기지 않는다.
        log warning "$DEVICE has no driver — restoring $BUILTIN"
        restore_builtin
        return
    fi
    if [ "$cur" != "$BUILTIN" ]; then
        log warning "skip: $DEVICE bound to '$cur', expected $BUILTIN"
        return 0
    fi
    [ -f "$MODULE" ] || { log warning "skip: module missing $MODULE ($BUILTIN kept)"; return 0; }
    # cam-operate 가 돌거나 오가는 중(activating·deactivating 등)이면 gstApp 이 언제든 장치를 열 수 있어,
    # 보유자 검사와 unbind 사이가 안전하지 않다. 상태를 모르면 같은 이유로 건너뛴다.
    state=$(cam_operate_state)
    case "$state" in
        inactive|failed) ;;
        *)
            log warning "skip: cam-operate is ${state:-unknown} — stop it first, or let the boot run this ($BUILTIN kept)"
            return 0
            ;;
    esac
    if ! rdev=$(dev_rdev); then
        log warning "skip: cannot read the device number of $DEV_NODE ($BUILTIN kept)"
        return 0
    fi
    if ! owners=$(holders "$rdev"); then
        log warning "skip: cannot list processes using $DEV_NODE ($BUILTIN kept)"
        return 0
    fi
    if [ -n "$owners" ]; then
        log warning "skip: $DEV_NODE is open by pid $owners ($BUILTIN kept)"
        return 0
    fi
    if [ ! -d "$drv_dir/$EXT" ]; then
        if ! out=$("$INSMOD" "$MODULE" 2>&1); then
            log warning "skip: insmod $MODULE failed: ${out:-no output} ($BUILTIN kept)"
            return 0
        fi
        if [ ! -d "$drv_dir/$EXT" ]; then
            log warning "skip: driver $EXT not registered after insmod ($BUILTIN kept)"
            return 0
        fi
    fi
    # insmod 동안 누가 장치를 열었을 수 있으니 unbind 바로 앞에서 다시 본다.
    if ! owners=$(holders "$rdev"); then
        log warning "skip: cannot list processes using $DEV_NODE before unbind ($BUILTIN kept)"
        return 0
    fi
    if [ -n "$owners" ]; then
        log warning "skip: $DEV_NODE was opened by pid $owners before unbind ($BUILTIN kept)"
        return 0
    fi
    if ! sysfs_write "$drv_dir/$BUILTIN/unbind" "$DEVICE"; then
        log warning "skip: unbind of $DEVICE from $BUILTIN failed ($BUILTIN kept)"
        return 0
    fi
    if sysfs_write "$dev_dir/driver_override" "$EXT" &&
        sysfs_write "$drv_dir/$EXT/bind" "$DEVICE" &&
        [ "$(current_driver)" = "$EXT" ]; then
        log notice "bound $DEVICE to $EXT"
        return 0
    fi
    log warning "bind of $DEVICE to $EXT failed (driver=$(current_driver || echo none)) — restoring $BUILTIN"
    restore_builtin
}

recover() {  # ExecStopPost 에서 돈다: 전환이 끊기거나 실패해 장치에 드라이버가 없으면 내장 드라이버로 되돌린다.
    # 정상 정지·재시작(SERVICE_RESULT=success)에는 손대지 않는다. 수동으로 돌리면 값이 없다.
    [ "${SERVICE_RESULT:-}" = success ] && return 0
    [ -d "$dev_dir" ] || return 0
    # driver 링크는 probe 가 끝나기 전에 생긴다. 전환이 아직 돌고 있으면(커널에서 막힌 bind 등) 링크만
    # 보고는 판단할 수 없으니 손대지 않고 알린다.
    if ! take_lock; then
        log err "recover: a swap still holds $LOCK (blocked in the kernel?) — $DEVICE driver=$(current_driver || echo none), state unknown; reboot to recover"
        return 1
    fi
    current_driver >/dev/null && return 0
    log warning "recover: $DEVICE has no driver after ${SERVICE_RESULT:-a manual run} — restoring $BUILTIN"
    restore_builtin
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "${1:-}" = --recover ]; then
        recover
    else
        main
    fi
    exit $?
fi
