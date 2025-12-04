#!/bin/bash
set -eu
TAG=$(basename "$0")
KEY=MNT

#logger -p local0.notice "[$KEY][$TAG:$LINENO] mount folder clean : rm -rf $1"

usage() {
    echo "Usage: $0 [--force] <block-device>"
    exit 1
}

FORCE=1
DEV=""

while [ $# -gt 0 ]; do
    case "$1" in
        --force)
            FORCE=1
            shift
            ;;
        -*)
            usage
            ;;
        *)
            DEV="$1"
            shift
            ;;
    esac
done

[ -n "$DEV" ] || usage

if [ ! -b "$DEV" ]; then
    echo "Error: $DEV is not a block device."
    logger -p local0.err "[$KEY][$TAG:$LINENO] $DEV is not a block device."
    exit 1
fi

INFO="$(file -s "$DEV" 2>/dev/null || true)"

if ! echo "$INFO" | grep -q "ext4 filesystem data"; then
    echo "Error: $DEV does not appear to contain an ext4 filesystem."
    echo "$INFO"
    logger -p local0.err "[$KEY][$TAG:$LINENO] $DEV does not appear to contain an ext4 filesystem."
    logger -p local0.err "[$KEY][$TAG:$LINENO] $INFO"
    exit 1
fi

echo "Current filesystem info:"
echo "  $INFO"
logger -p local0.notice "[$KEY][$TAG:$LINENO] Current filesystem info:"
logger -p local0.notice "[$KEY][$TAG:$LINENO]   $INFO"

if echo "$INFO" | grep -Eq "(64bit|metadata_csum|sparse_super2|inline_data|encrypt)"; then
    NEED_DOWNGRADE=1
else
    echo "This filesystem already appears to be compatible (old-style)."
    logger -p local0.notice "[$KEY][$TAG:$LINENO] This filesystem already appears to be compatible (old-style)."
    exit 0
fi

if findmnt -rn -S "$DEV" >/dev/null 2>&1; then
    MP="$(findmnt -rn -S "$DEV" -o TARGET)"
    echo "Unmounting $DEV from $MP"
    logger -p local0.notice "[$KEY][$TAG:$LINENO] Unmounting $DEV from $MP"
    umount "$DEV"
fi

if findmnt -rn -S "$DEV" >/dev/null 2>&1; then
    echo "Error: failed to unmount $DEV"
    logger -p local0.err "[$KEY][$TAG:$LINENO] failed to unmount $DEV"
    exit 1
fi

echo "WARNING: This will destroy all data on $DEV."
echo "It will be reformatted into old-style ext4 (no 64bit, no metadata_csum)."
logger -p local0.warn "[$KEY][$TAG:$LINENO] This will destroy all data on $DEV."
logger -p local0.warn "[$KEY][$TAG:$LINENO] It will be reformatted into old-style ext4 (no 64bit, no metadata_csum)."

if [ "$FORCE" -ne 1 ]; then
    printf "Proceed? [yes/NO]: "
    read ans || ans=""
    case "$ans" in
        yes|y|YES|Y)
            ;;
        *)
            echo "Canceled."
            exit 0
            ;;
    esac
fi

echo "Reformatting as old-style ext4:"
echo "  mkfs.ext4 -F -O ^64bit,^metadata_csum \"$DEV\""
logger -p local0.notice "[$KEY][$TAG:$LINENO] Reformatting as old-style ext4:"
logger -p local0.notice "[$KEY][$TAG:$LINENO]   mkfs.ext4 -F -O ^64bit,^metadata_csum \"$DEV\""
mkfs.ext4 -F -O ^64bit,^metadata_csum "$DEV"

echo "Done. New filesystem info:"
logger -p local0.notice "[$KEY][$TAG:$LINENO] Done. New filesystem info:"
file -s "$DEV"
