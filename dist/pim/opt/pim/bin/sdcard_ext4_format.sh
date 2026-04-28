#!/bin/bash
tag=$(basename "$0")
KEY=SDC

DEVICE="/dev/mmcblk1"
MOUNT_POINT="/mnt/sd_cam"
PART="${DEVICE}p1"

log() {
    echo "[INFO] $*"
    logger -p local0.notice "[$KEY][$tag] $*"
}

warn() {
    echo "[WARN] $*" >&2
    logger -p local0.warning "[$KEY][$tag] $*"
}

err() {
    echo "[ERROR] $*" >&2
    logger -p local0.err "[$KEY][$tag] $*"
}

is_dev_exists() {
    [ -b "$DEVICE" ]
}

is_mounted_on_mnt() {
    awk -v m="$MOUNT_POINT" '$2==m {found=1} END{exit !found}' /proc/mounts
}

mounted_dev_on_mnt() {
    awk -v m="$MOUNT_POINT" '$2==m {print $1; exit}' /proc/mounts
}

is_any_partition_mounted_from_dev() {
    awk -v d="$DEVICE" '$1 ~ ("^" d "p?[0-9]+$") || $1==d {found=1} END{exit !found}' /proc/mounts
}

list_mount_targets_from_dev() {
    awk -v d="$DEVICE" '$1 ~ ("^" d "p?[0-9]+$") || $1==d {print $2}' /proc/mounts
}

umount_strong() {
    TARGET="$1"

    log "try umount: $TARGET"
    if umount "$TARGET" 2>/dev/null; then
        log "umount success"
        return 0
    fi

    warn "normal umount failed, sync and retry"
    sync
    sleep 1

    if umount "$TARGET" 2>/dev/null; then
        log "umount success after sync"
        return 0
    fi

    if command -v fuser >/dev/null 2>&1; then
        warn "try stop processes using $TARGET with SIGTERM"
        fuser -m -k -TERM "$TARGET" 2>/dev/null
        sleep 2

        if umount "$TARGET" 2>/dev/null; then
            log "umount success after SIGTERM"
            return 0
        fi

        warn "still busy, try SIGKILL"
        fuser -m -k -KILL "$TARGET" 2>/dev/null
        sleep 1

        if umount "$TARGET" 2>/dev/null; then
            log "umount success after SIGKILL"
            return 0
        fi
    else
        warn "fuser not found, skip process kill step"
    fi

    warn "try lazy umount"
    if umount -l "$TARGET" 2>/dev/null; then
        log "lazy umount success"
        return 0
    fi

    err "umount failed: $TARGET"
    return 1
}

umount_all_from_dev() {
    if is_mounted_on_mnt; then
        CUR_DEV="$(mounted_dev_on_mnt)"
        log "$MOUNT_POINT is mounted${CUR_DEV:+ with $CUR_DEV}"
        cd / || return 1
        umount_strong "$MOUNT_POINT" || return 1
    fi

    if is_any_partition_mounted_from_dev; then
        warn "some partitions from $DEVICE are still mounted"
        for mp in $(list_mount_targets_from_dev | sort -r); do
            cd / || return 1
            umount_strong "$mp" || return 1
        done
    fi

    return 0
}

wipe_device_signatures() {
    if command -v wipefs >/dev/null 2>&1; then
        log "wipe signatures on $DEVICE"
        wipefs -a "$DEVICE" >/dev/null 2>&1 || {
            err "wipefs failed: $DEVICE"
            return 1
        }
    else
        warn "wipefs not found, skip signature wipe"
    fi
    return 0
}

create_ext4_partition() {
    log "create DOS partition table and one Linux partition on $DEVICE"

    sfdisk --delete "$DEVICE" >/dev/null 2>&1

    echo ',,83' | sfdisk --wipe always "$DEVICE" >/dev/null 2>&1 || {
        err "sfdisk failed: $DEVICE"
        return 1
    }

    sync
    sleep 1

    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$DEVICE" >/dev/null 2>&1
    fi

    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle >/dev/null 2>&1
    fi

    i=0
    while [ $i -lt 10 ]; do
        [ -b "$PART" ] && return 0
        sleep 1
        i=$((i + 1))
    done

    err "partition node not created: $PART"
    return 1
}

format_ext4() {
    log "format $PART to ext4"
    mkfs.ext4 -F "$PART" >/dev/null 2>&1 || {
        err "mkfs.ext4 failed: $PART"
        return 1
    }

    sync
    sleep 1

    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle >/dev/null 2>&1
    fi

    return 0
}

verify_partition_table() {
    if ! sfdisk -d "$DEVICE" >/dev/null 2>&1; then
        err "cannot read partition table from $DEVICE"
        return 1
    fi

    if ! [ -b "$PART" ]; then
        err "partition does not exist: $PART"
        return 1
    fi

    log "partition table verification success"
    return 0
}

verify_ext4() {
    FSTYPE="$(blkid -o value -s TYPE "$PART" 2>/dev/null)"

    if [ "$FSTYPE" != "ext4" ]; then
        err "blkid verification failed: $PART TYPE=$FSTYPE"
        return 1
    fi

    if command -v dumpe2fs >/dev/null 2>&1; then
        dumpe2fs -h "$PART" >/dev/null 2>&1 || {
            err "dumpe2fs verification failed: $PART"
            return 1
        }
    fi

    log "filesystem verification success: $PART is ext4"
    return 0
}


init_sdcard_directory() {
    rm -rf "$MOUNT_POINT"
    mkdir -p $MOUNT_POINT
    mount $PART $MOUNT_POINT
    if ! [ $? -eq 0 ]; then
        echo "SDCARD mount fail"
        return 1
    fi

    mkdir -p $MOUNT_POINT/event
    mkdir -p $MOUNT_POINT/recycle
    mkdir -p $MOUNT_POINT/tmp
    return 0
}

main() {
    if ! is_dev_exists; then
        err "device not found: $DEVICE"
        exit 1
    fi

    log "device exists: $DEVICE"

    log "stop cam-operate"
    systemctl stop cam-operate

    log "stop sd-mount"
    systemctl stop sd-mount
    status=$(systemctl is-active pim-gate 2>/dev/null)
    if [ "$status" = "active" ]; then
        log "stop pim-gate"
        systemctl stop pim-gate
    fi

    umount_all_from_dev || exit 1
    wipe_device_signatures || exit 1
    create_ext4_partition || exit 1
    verify_partition_table || exit 1
    format_ext4 || exit 1
    verify_ext4 || exit 1
    init_sdcard_directory || exit 1

    log "all done"
    exit 0
}

main "$@"