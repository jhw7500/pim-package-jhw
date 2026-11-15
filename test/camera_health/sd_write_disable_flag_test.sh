#!/usr/bin/env bash
# shellcheck disable=SC2034  # the names set below are read by the functions evaluated from the daemon script
# update_sd_write_disable_flag (issue #251): SD writes must be re-enabled on a filesystem that does
# not count inodes.
#
# The daemon creates /tmp/sd_write_disabled when the SD is 98% full, when its inodes are 98% used,
# or when the SD went read-only, and recordings then go to RAM only.  The flag is removed only here,
# once usage and inode use are below 95%.  vfat does not count inodes: `df -Pi` prints `-` in the
# IUse% column, every numeric test on it failed with "integer expression expected", and the
# re-enable test was always false, so the flag stayed until a reboot.
#
# The test runs the daemon's own functions with a stubbed `df` and checks the flag on both kinds
# of filesystem.  SD_FLAG_DAEMON=<path> runs the same scenarios against another copy of the daemon
# (the pre-fix function keeps the flag in the vfat scenario):
#   git show origin/master:dist/pim/opt/pim/bin/chk_cam_operate.sh > /tmp/chk_old.sh
#   SD_FLAG_DAEMON=/tmp/chk_old.sh bash <this test>
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DAEMON=${SD_FLAG_DAEMON:-$ROOT/dist/pim/opt/pim/bin/chk_cam_operate.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-sd-flag.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

extract() {  # one top-level function of the daemon script, by name
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) \\{" { p = 1 }
        p { print }
        p && /^}/ { exit }
    ' "$DAEMON"
}
for fn in get_df_usage_pct get_df_inode_pct update_sd_write_disable_flag; do
    body=$(extract "$fn")
    grep -q "^$fn() {" <<<"$body" || fail "could not extract $fn from $DAEMON"
    eval "$body"
done

KEY=RST
tag=sd_write_disable_flag_test
WARN_PCT_DEFAULT=95
CRIT_PCT_DEFAULT=98
SD_WRITE_DISABLE_FILE="$WORK/sd_write_disabled"
FLAG=$SD_WRITE_DISABLE_FILE
ERRLOG="$WORK/stderr"
logger() { :; }

# df -P prints block use and df -Pi inode use, in column 5 of the second line.  vfat prints `-`
# (no %) in the inode column, as `df -Pi /mnt/sd_cam` does on the development board.
USE=0
IUSE=0
df() {
    local inode=0 a
    for a in "$@"; do [ "$a" = "-Pi" ] && inode=1; done
    echo "Filesystem Inodes IUsed IFree IUse% Mounted on"
    if [ "$inode" = 0 ]; then
        echo "/dev/mmcblk1p1 1000 0 0 ${USE}% /mnt/sd_cam"
    elif [ "$IUSE" = "-" ]; then
        echo "/dev/mmcblk1p1 0 0 0 - /mnt/sd_cam"
    else
        echo "/dev/mmcblk1p1 100 0 0 ${IUSE}% /mnt/sd_cam"
    fi
}

step() {  # block use, inode use ("-" for vfat)
    USE=$1
    IUSE=$2
    update_sd_write_disable_flag /mnt/sd_cam 2>>"$ERRLOG" || :
}
flag() { [ -e "$FLAG" ] && echo present || echo absent; }
expect_flag() {
    local got
    got=$(flag)
    [ "$got" = "$1" ] || fail "$name: flag is $got, expected $1"
}
scenario() {
    name=$1
    rm -f "$FLAG"
    : > "$ERRLOG"
}
no_shell_errors() {
    if grep -q 'integer expression' "$ERRLOG"; then
        fail "$name: shell test errors: $(head -1 "$ERRLOG")"
    fi
}

# 1. vfat: the SD fills to 98% and is cleaned back to 90%.  The flag is set and then cleared.
scenario 'vfat, disk full then cleaned'
step 50 -
expect_flag absent
step 98 -
expect_flag present
step 96 -
expect_flag present
step 90 -
expect_flag absent
no_shell_errors

# 2. vfat: the flag was set because the SD went read-only (retention sets it).  Once the SD is
#    writable and below 95%, the flag is cleared.
scenario 'vfat, flag set by the read-only path'
: > "$FLAG"
step 90 -
expect_flag absent
no_shell_errors

# 3. A filesystem that counts inodes keeps today's rules: inodes at 98% set the flag, and it is
#    cleared only when both usage and inode use are below 95%.
scenario 'inode counting, inode exhaustion'
step 50 99
expect_flag present
step 50 96
expect_flag present
step 50 90
expect_flag absent
no_shell_errors

# 4. Same filesystem, block usage over the limit while inodes are fine.
scenario 'inode counting, disk full'
step 98 10
expect_flag present
step 96 10
expect_flag present
step 94 10
expect_flag absent
no_shell_errors

echo "sd write disable flag: PASS"
