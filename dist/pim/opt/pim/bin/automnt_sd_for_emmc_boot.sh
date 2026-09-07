#!/bin/bash

TAG=$(basename "$0")
KEY=MNT
mnt_state=0
mnt_cnt=0
fsck_cnt=0
reinsert_fail_cnt=0
ro_wait_cnt=0
ro_fallback=0
REINSERT_FAIL_MAX=5
REINSERT_BACKOFF_SEC=60
TEST_MODE=0
MAX_ITERATIONS=0

if [[ "${PIM_CAMERA_TEST_MODE:-0}" == "1" ]]; then
    TEST_MODE=1
    DEVICE="${PIM_SD_DEVICE:?PIM_SD_DEVICE is required in test mode}"
    DIR="${PIM_SD_MOUNT_DIR:?PIM_SD_MOUNT_DIR is required in test mode}"
    MNT_FLAG="${PIM_SD_MOUNT_FLAG:?PIM_SD_MOUNT_FLAG is required in test mode}"
    PROC_MOUNTS="${PIM_SD_PROC_MOUNTS:?PIM_SD_PROC_MOUNTS is required in test mode}"
    SD_PRESENT_PATH="${PIM_SD_PRESENT_PATH:?PIM_SD_PRESENT_PATH is required in test mode}"
    SD_SYS_RO_PATH="${PIM_SD_SYS_RO_PATH:?PIM_SD_SYS_RO_PATH is required in test mode}"
    RO_RECOVERY_FLAG="${PIM_SD_RO_RECOVERY_FLAG:?PIM_SD_RO_RECOVERY_FLAG is required in test mode}"
    LOCKFILE="${PIM_SD_LOCKFILE:?PIM_SD_LOCKFILE is required in test mode}"
    SESSION_DIR="${PIM_CAMERA_SESSION_DIR:?PIM_CAMERA_SESSION_DIR is required in test mode}"
    MAX_ITERATIONS="${PIM_AUTOMOUNT_MAX_ITERATIONS:?PIM_AUTOMOUNT_MAX_ITERATIONS is required in test mode}"
else
    DEVICE="/dev/mmcblk1p1"
    DIR="/mnt/sd_cam"
    MNT_FLAG="/dev/shm/sd_mount_flag"
    PROC_MOUNTS="/proc/mounts"
    SD_PRESENT_GLOB="/sys/bus/mmc/devices/mmc1:*/block/mmcblk1/mmcblk1p1"
    SD_SYS_RO_PATH="/sys/block/mmcblk1/ro"
    RO_RECOVERY_FLAG="/tmp/sd_ro_recovered"
    LOCKFILE="/tmp/automnt_sd_for_emmc_boot.lock"
    SESSION_DIR="/tmp"
fi

exec 200>"$LOCKFILE"
flock -n 200 || exit 1

publish_available() {
    printf '%s\n' "$1" > "$MNT_FLAG"
}

is_sd_present() {
    if [[ "$TEST_MODE" == "1" ]]; then
        [[ -d "$SD_PRESENT_PATH" ]]
    else
        compgen -G "$SD_PRESENT_GLOB" >/dev/null
    fi
}

is_sd_ro() {
    if [[ "$(cat "$SD_SYS_RO_PATH" 2>/dev/null)" == "1" ]]; then
        return 0
    fi
    awk -v dev="$DEVICE" '$1 == dev && $4 ~ /^ro/ {found=1} END {exit !found}' \
        "$PROC_MOUNTS" 2>/dev/null
}

detect_fstype() {
    FSTYPE=$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null)
    if [[ -z "$FSTYPE" ]]; then
        FSTYPE=$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null)
    fi
}

mount_sd() {
    case "$FSTYPE" in
        vfat|fat|fat32|msdos)
            mount -t vfat -o noatime,nodiratime,flush,dirsync,utf8=1,shortname=mixed \
                "$DEVICE" "$DIR"
            ;;
        ext4)
            mount -t ext4 -o noatime,nodiratime,commit=60,data=ordered,barrier=1,errors=remount-ro \
                "$DEVICE" "$DIR"
            ;;
        exfat)
            mount -t exfat -o noatime,nodiratime "$DEVICE" "$DIR"
            ;;
        *)
            logger -p local0.crit "[$KEY][$TAG:$LINENO] $DEVICE fstype is undefined : $FSTYPE"
            reinsert_fail_cnt=$((reinsert_fail_cnt + 1))
            mount "$DEVICE" "$DIR"
            ;;
    esac
}

cleanup_sd_files() {
    shopt -s nocaseglob
    local fsck_files=("$DIR"/FSCK*)
    if [[ -e "${fsck_files[0]}" ]]; then
        rm -f -- "$DIR"/FSCK*
    fi
    shopt -u nocaseglob

    if [[ ! -d "$DIR/tmp" ]]; then
        mkdir -p "$DIR/tmp"
        logger -p local0.notice "[$KEY][$TAG:$LINENO] created $DIR/tmp"
    fi

    local part_count
    part_count=$(find "$DIR/tmp" -type f -name '*.part' 2>/dev/null | wc -l)
    if [[ "$part_count" -gt 0 ]]; then
        logger -p local0.notice "[$KEY][$TAG:$LINENO] cleaning up $part_count .part files in $DIR/tmp"
        find "$DIR/tmp" -type f -name '*.part' -delete 2>/dev/null
    fi

    rm -f -- "$SESSION_DIR"/session_*.all_done 2>/dev/null
}

start_camera_if_ready() {
    local daemon_name=cam-operate
    local status
    status=$(systemctl is-enabled "$daemon_name" 2>/dev/null)
    if [[ "$status" == "enabled" ]]; then
        status=$(systemctl is-active "$daemon_name" 2>/dev/null)
        if [[ "$status" != "active" ]]; then
            systemctl start "$daemon_name"
        fi
    fi
}

detect_fstype
logger -p local0.notice "[$KEY][$TAG:$LINENO] dev : $DEVICE, dir : $DIR, fstype : $FSTYPE"

iteration=0
while true; do
    case "$mnt_state" in
        0)
            if is_sd_present; then
                logger -p local0.info "[$KEY][$TAG:$LINENO] umount -l $DIR (prep for re-mount)"
                umount -l "$DIR" 2>/dev/null

                mnt_dev=$(awk -v dev="$DEVICE" '$1 == dev {print $1}' "$PROC_MOUNTS")
                if [[ -z "$mnt_dev" ]]; then
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] mount folder clean : $DIR"
                    rm -rf -- "$DIR"
                    mkdir -p "$DIR"

                    detect_fstype
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] $DEVICE fstype : $FSTYPE, mounting to $DIR"
                    mount_sd
                    mount_rc=$?
                    mnt_folder=$(awk -v dev="$DEVICE" '$1 == dev {print $2}' "$PROC_MOUNTS")

                    if [[ "$mount_rc" -eq 0 && "$mnt_folder" == "$DIR" ]]; then
                        if awk -v dev="$DEVICE" '$1 == dev && $4 ~ /^rw/ {found=1} END {exit !found}' \
                            "$PROC_MOUNTS"; then
                            cleanup_sd_files
                            publish_available 1
                            logger -p local0.notice "[$KEY][$TAG:$LINENO] sd_mount_flag set"
                            mnt_state=1
                            mnt_cnt=0
                            fsck_cnt=0
                            reinsert_fail_cnt=0
                            start_camera_if_ready
                        else
                            logger -p local0.crit "[$KEY][$TAG:$LINENO] mounted as read-only"
                            publish_available 0
                            umount -l "$DIR" 2>/dev/null
                            ro_fallback=1
                            mnt_state=2
                        fi
                    else
                        logger -p local0.err "[$KEY][$TAG:$LINENO] sd mount failed"
                        publish_available 0
                        reinsert_fail_cnt=$((reinsert_fail_cnt + 1))
                        mnt_state=2
                    fi
                elif [[ "$mnt_dev" != "$DEVICE" ]]; then
                    logger -p local0.err "[$KEY][$TAG:$LINENO] mnt_dev : $mnt_dev != $DEVICE"
                    publish_available 0
                    mnt_state=1
                elif is_sd_ro; then
                    logger -p local0.crit "[$KEY][$TAG:$LINENO] $DEVICE read-only (pre-mount)"
                    publish_available 0
                    umount -l "$DIR" 2>/dev/null
                    ro_fallback=1
                    mnt_state=2
                else
                    publish_available 1
                    mnt_state=1
                fi
            else
                publish_available 0
                mnt_state=2
            fi
            ;;
        1)
            if ! is_sd_present; then
                mnt_cnt=$((mnt_cnt + 1))
                if [[ "$mnt_cnt" -gt 3 ]]; then
                    publish_available 0
                    logger -p local0.emerg "[$KEY][$TAG:$LINENO] please insert sd card!!"
                    sd_pids=$(fuser -m "$DIR" 2>/dev/null)
                    if [[ -n "$sd_pids" ]]; then
                        logger -p local0.warning "[$KEY][$TAG:$LINENO] processes using $DIR:$sd_pids"
                        fuser -TERM -km "$DIR" 2>/dev/null
                        sleep 1
                    fi
                    umount -l "$DIR" 2>/dev/null
                    mnt_cnt=0
                    mnt_state=2
                fi
            elif is_sd_ro; then
                publish_available 0
                logger -p local0.crit "[$KEY][$TAG:$LINENO] $DEVICE read-only detected"
                umount -l "$DIR" 2>/dev/null
                mnt_cnt=0
                fsck_cnt=0
                ro_fallback=1
                mnt_state=2
            else
                mnt_dev=$(awk -v dir="$DIR" '$2 == dir {print $1}' "$PROC_MOUNTS")
                if [[ "$mnt_dev" != "$DEVICE" ]]; then
                    mnt_cnt=$((mnt_cnt + 1))
                    publish_available 0
                    logger -p local0.err "[$KEY][$TAG:$LINENO] mnt_dev mismatch: $mnt_dev != $DEVICE (mnt_cnt:$mnt_cnt)"
                    if [[ "$mnt_cnt" -gt 3 ]]; then
                        mnt_cnt=0
                        mnt_state=2
                    fi
                else
                    mnt_cnt=0
                fi
            fi
            ;;
        2)
            if is_sd_present; then
                if [[ "$reinsert_fail_cnt" -ge "$REINSERT_FAIL_MAX" ]]; then
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] SD present but mount failed ${reinsert_fail_cnt}x; waiting for physical re-insert"
                elif [[ "$ro_fallback" -eq 1 ]]; then
                    if [[ -f "$RO_RECOVERY_FLAG" ]]; then
                        logger -p local0.notice "[$KEY][$TAG:$LINENO] RO recovery flag detected, attempting mount"
                        rm -f -- "$RO_RECOVERY_FLAG"
                        ro_fallback=0
                        ro_wait_cnt=0
                        mnt_cnt=0
                        fsck_cnt=0
                        mnt_state=0
                    else
                        if [[ $((ro_wait_cnt % 20)) -eq 0 ]]; then
                            logger -p local0.notice "[$KEY][$TAG:$LINENO] SD read-only fallback active, waiting for recovery [$ro_wait_cnt]"
                        fi
                        ro_wait_cnt=$((ro_wait_cnt + 1))
                    fi
                else
                    logger -p local0.notice "[$KEY][$TAG:$LINENO] SD card available and writable, attempting mount"
                    mnt_cnt=0
                    fsck_cnt=0
                    ro_wait_cnt=0
                    mnt_state=0
                fi
            else
                publish_available 0
                if [[ "$reinsert_fail_cnt" -gt 0 ]]; then
                    reinsert_fail_cnt=0
                fi
                if [[ "$ro_fallback" -eq 1 ]]; then
                    ro_fallback=0
                    rm -f -- "$RO_RECOVERY_FLAG"
                fi
                ro_wait_cnt=0
            fi
            ;;
    esac

    iteration=$((iteration + 1))
    if [[ "$TEST_MODE" == "1" && "$iteration" -ge "$MAX_ITERATIONS" ]]; then
        break
    fi
    sleep 3
done

exit 0
