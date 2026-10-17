#!/bin/bash
# 부팅 때 VPU 인코더 장치를 커널 내장 드라이버에서 imx-hantro 의 수정 모듈로 옮겨 붙인다 (#194).
#
# 내장 드라이버(mxc_hantro_vc8000e)는 코어 예약을 스레드 id 로 해제해, 예약하지 않은 스레드가
# 마지막 close 를 하면 예약이 영구히 남고 모든 인코딩이 멈춘다(#191). 수정 모듈
# (hantro_vc8000e_ext.ko, 드라이버 mxc_hantro_vc8000e_ext)은 열린 파일로 해제한다.
# 내장이라 .ko 를 두는 것만으로는 대체되지 않으므로 장치를 직접 옮긴다.
#
# cam-operate 보다 먼저(pim-vpu-driver.service) 한 번 돈다. 장치를 연 프로세스가 있으면 건드리지
# 않는다 — 드라이버 cleanup 이 열린 fd 가 가리키는 메모리를 해제하기 때문이다. 어떤 경우에도 0 으로
# 끝나 cam-operate 기동을 막지 않고, 옮기지 못하면 내장 드라이버로 남긴다.
set -u

KEY=VPU-DRV
tag=$(basename "$0")
SYSFS_ROOT="${PIM_VPU_SYSFS_ROOT:-/sys}"
PROC_ROOT="${PIM_VPU_PROC_ROOT:-/proc}"
MODULE="${PIM_VPU_MODULE:-/opt/pim/driver/hantro_vc8000e_ext.ko}"
INSMOD="${PIM_VPU_INSMOD:-insmod}"
SYSTEMCTL="${PIM_VPU_SYSTEMCTL:-systemctl}"
DEVICE=38320000.vpu_vc8000e
DEV_NODE=/dev/mxc_hantro_vc8000e
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

cam_operate_active() {  # 부팅 때는 Before= 순서로 아직 기동 전이다. 수동 재실행만 여기에 걸린다.
    "$SYSTEMCTL" is-active --quiet cam-operate.service 2>/dev/null
}

sysfs_write() {  # sysfs_write <file> <value>: 빈 값이면 개행만 써서 driver_override 를 비운다.
    { printf '%s\n' "$2" > "$1"; } 2>/dev/null
}

current_driver() {
    local link
    link=$(readlink "$dev_dir/driver" 2>/dev/null) || return 1
    printf '%s\n' "${link##*/}"
}

holders() {  # 장치 노드를 연 프로세스 pid 를 공백으로 구분해 출력한다.
    local fd target pid out=""
    for fd in "$PROC_ROOT"/[0-9]*/fd/*; do
        target=$(readlink "$fd" 2>/dev/null) || continue
        [ "$target" = "$DEV_NODE" ] || continue
        pid=${fd#"$PROC_ROOT"/}
        pid=${pid%%/*}
        case " $out " in *" $pid "*) ;; *) out="${out:+$out }$pid" ;; esac
    done
    printf '%s' "$out"
}

restore_builtin() {
    sysfs_write "$dev_dir/driver_override" ""
    if sysfs_write "$drv_dir/$BUILTIN/bind" "$DEVICE" && [ "$(current_driver)" = "$BUILTIN" ]; then
        log warning "restored $DEVICE to $BUILTIN"
    else
        log err "restore of $DEVICE to $BUILTIN failed — VPU encoder is unbound (driver=$(current_driver || echo none))"
    fi
}

main() {
    local cur owners out
    [ -d "$dev_dir" ] || { log notice "skip: no device $DEVICE"; return 0; }
    cur=$(current_driver) || cur=""
    if [ "$cur" = "$EXT" ]; then
        log notice "already bound to $EXT"
        return 0
    fi
    if [ "$cur" != "$BUILTIN" ]; then
        log warning "skip: $DEVICE bound to '${cur:-none}', expected $BUILTIN"
        return 0
    fi
    [ -f "$MODULE" ] || { log warning "skip: module missing $MODULE ($BUILTIN kept)"; return 0; }
    # cam-operate 가 돌면 gstApp 이 언제든 장치를 열 수 있어, 보유자 검사와 unbind 사이가 안전하지 않다.
    if cam_operate_active; then
        log warning "skip: cam-operate is active — stop it first, or let the boot run this ($BUILTIN kept)"
        return 0
    fi
    owners=$(holders)
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
    owners=$(holders)
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
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
    exit 0
fi
