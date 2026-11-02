#!/usr/bin/env bash
# Offline read-only Owner snapshot; never reads/changes the real PIM board.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d /tmp/qa-owner-observe.XXXXXX)
trap 'rm -rf -- "$WORK"' EXIT
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib"
export PIM_CAMERA_RUN_DIR="$WORK/run"
export PIM_CAMERA_STATE_DIR="$WORK/state"
export PIM_CAMERA_BOOT_ID_FILE="$WORK/boot_id"
export PIM_CAMERA_PROC_ROOT="$WORK/proc"
CLI="$ROOT/dist/pim/opt/pim/bin/cam-recoveryctl"
fail() { echo "FAIL: $*" >&2; exit 1; }
verify_block() {
    local code=$1 json
    json=$("$CLI" owner-observe) || fail "owner observation command failed"
    jq -e --arg code "$code" '
        .schema==1 and .decision=="BLOCK" and .reason_code==$code
        and .owner_process_observed==false and .owner==null
        and .official_lease_verified==false and .eos_verified==false
        and .fsync_verified==false and .writer_fd_closed_verified==false
        and .writer_cannot_reopen==false and .writer_fence_session==null
        and .hardware_execution_authorized==false
    ' <<<"$json" >/dev/null || fail "unexpected denial JSON: $json"
}
verify_block OWNER_RUNTIME_DIRECTORY_UNTRUSTED
mkdir -p "$PIM_CAMERA_RUN_DIR" "$PIM_CAMERA_STATE_DIR" "$PIM_CAMERA_PROC_ROOT/4242"
verify_block OWNER_FILE_UNAVAILABLE
printf 'boot-a\n' > "$PIM_CAMERA_BOOT_ID_FILE"
fake_stat() {
    local start=$1
    { printf '4242 (cam operate) S'
      for _ in $(seq 1 18); do printf ' 0'; done
      printf ' %s 0 0\n' "$start"
    } > "$PIM_CAMERA_PROC_ROOT/4242/stat"
}
fake_stat 555
cat > "$PIM_CAMERA_RUN_DIR/owner.json" <<'OWNER'
{"boot_id":"boot-a","invocation_id":"inv-1","pid":4242,"proc_start_time":"555","token":"PRIVATE-NEVER-RETURN","created_at":101,"lifecycle":"ACTIVE"}
OWNER
before=$(sha256sum "$PIM_CAMERA_RUN_DIR/owner.json" | cut -d' ' -f1)
good=$("$CLI" owner-observe) || fail "live observation command failed"
jq -e '
    .schema==1 and .decision=="BLOCK"
    and .reason_code=="OWNER_PROCESS_OBSERVED_NO_WRITER_FENCE"
    and .owner_process_observed==true
    and .owner=={"boot_id":"boot-a","invocation_id":"inv-1","pid":4242,"proc_start_time":"555","lifecycle":"ACTIVE"}
    and .writer_fence_session==null and .hardware_execution_authorized==false
    and .official_lease_verified==false
    and .writer_cannot_reopen==false and .eos_verified==false
    and .fsync_verified==false and .writer_fd_closed_verified==false
    and (tostring|contains("PRIVATE-NEVER-RETURN")|not)
' <<<"$good" >/dev/null || fail "live observation is not strictly read-only/no-token: $good"
[ "$before" = "$(sha256sum "$PIM_CAMERA_RUN_DIR/owner.json" | cut -d' ' -f1)" ] ||
    fail "owner observation mutated the owner file"
printf 'boot-b\n' > "$PIM_CAMERA_BOOT_ID_FILE"
verify_block OWNER_PROCESS_STALE_OR_UNKNOWN
printf 'boot-a\n' > "$PIM_CAMERA_BOOT_ID_FILE"
fake_stat 777
verify_block OWNER_PROCESS_STALE_OR_UNKNOWN
fake_stat 555
printf '%s\n' '{"boot_id":"boot-b","pid":4242}' >> "$PIM_CAMERA_RUN_DIR/owner.json"
verify_block OWNER_DOCUMENT_UNTRUSTED
sed -i '$d' "$PIM_CAMERA_RUN_DIR/owner.json"
rm "$PIM_CAMERA_RUN_DIR/owner.json"
ln -s "$WORK/missing" "$PIM_CAMERA_RUN_DIR/owner.json"
verify_block OWNER_FILE_UNAVAILABLE
rm "$PIM_CAMERA_RUN_DIR/owner.json"
rm -rf "$PIM_CAMERA_RUN_DIR"
ln -s "$WORK/proc" "$PIM_CAMERA_RUN_DIR"
verify_block OWNER_RUNTIME_DIRECTORY_UNTRUSTED
set +e
"$CLI" owner-observe --json >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 64 ] || fail "owner-observe accepted unexpected arguments: $rc"
echo "qa owner observe: PASS"
