#!/usr/bin/env bash
# Read-only QA marker status contract. No board, services, or writer commands.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d /tmp/qa-maintenance-status.XXXXXX)
trap 'rm -rf -- "$WORK"' EXIT
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_CAMERA_RUN_DIR="$WORK/run"
export PIM_CAMERA_STATE_DIR="$WORK/state"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot-id"
CLI="$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_status() {
    local reason=$1 present=$2 actual
    actual=$("$CLI" maintenance-status) || fail "status command returned error"
    jq -e --arg code "$reason" --argjson present "$present" '
        .schema==1 and .decision=="BLOCK"
        and .marker_present==$present
        and .reason_code==$code
        and .writer_fence_session==null
        and .writer_closed==false
        and .writer_cannot_reopen==false
        and .hardware_execution_authorized==false
        and (keys|sort)==["decision","hardware_execution_authorized","marker_present","reason_code","schema","writer_cannot_reopen","writer_closed","writer_fence_session"]
    ' <<<"$actual" >/dev/null || fail "invalid status: $actual"
}
assert_status STATE_DIRECTORY_UNTRUSTED null
mkdir -p "$PIM_CAMERA_STATE_DIR"
assert_status NO_OWNER_WRITER_FENCE false
marker="$PIM_CAMERA_STATE_DIR/qa-maintenance.json"
printf '{"phase":"RESTORE_PENDING"}\n' > "$marker"
expected=$(sha256sum "$marker" | cut -d' ' -f1)
assert_status RESTORE_PENDING_UNVERIFIED true
[ "$expected" = "$(sha256sum "$marker" | cut -d' ' -f1)" ] || fail "status modified marker"
printf '{broken\n' > "$marker"
assert_status RESTORE_PENDING_UNVERIFIED true
rm -f -- "$marker"
ln -s "$WORK/missing" "$marker"
assert_status RESTORE_PENDING_UNVERIFIED true
rm -f -- "$marker"
mkdir "$marker"
assert_status RESTORE_PENDING_UNVERIFIED true
rmdir "$marker"
rmdir "$PIM_CAMERA_STATE_DIR"
ln -s "$WORK" "$PIM_CAMERA_STATE_DIR"
assert_status STATE_DIRECTORY_UNTRUSTED null

# Every direct Owner/liveness path uses this same guard, not just systemd.
# A linked state directory must not bypass the durable marker barrier.
source "$PIM_LIB/cam_recovery.sh"
set +e
_cr_qa_maintenance_barrier
guard_rc=$?
set -e
[ "$guard_rc" -eq 70 ] || fail "symlinked StateDirectory accepted by Owner rc=$guard_rc"

set +e
"$CLI" maintenance-status --json >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 64 ] || fail "unexpected argument accepted, rc=$rc"

rm "$PIM_CAMERA_STATE_DIR"
mkdir "$PIM_CAMERA_STATE_DIR"
: > "$PIM_CAMERA_BOOT_ID_FILE"
assert_status NO_OWNER_WRITER_FENCE false

echo 'qa maintenance status: PASS'
