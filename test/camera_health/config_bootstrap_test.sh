#!/bin/bash
# Offline tests for camera_config_bootstrap.sh. No board or root paths used.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/dist/pim/opt/pim/bin/camera_config_bootstrap.sh"
UNIT="$ROOT/dist/pim/etc/systemd/system/pim-camera-config.service"
POSTINST="$ROOT/dist/pim/DEBIAN/postinst"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/camera-config-test.XXXXXX")
SOURCE="$WORK/shared_v"
DEST="$WORK/config"
BOOT_ID_FILE="$WORK/boot_id"
LOCK_FILE="$WORK/lock/pim-camera-config.lock"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
skipped=0

ok() { pass=$((pass + 1)); printf '  OK   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1" >&2; }
# 건너뛴 항목은 pass 로 세지 않는다. 아무것도 검사하지 않았는데 합계가 늘면
# 요약만 보는 사람에게 실행된 것처럼 보인다.
skip() { skipped=$((skipped + 1)); printf '  SKIP %s\n' "$1"; }

assert_eq() {
    local label=$1 actual=$2 expected=$3
    if [ "$actual" = "$expected" ]; then
        ok "$label"
    else
        bad "$label: actual=[$actual] expected=[$expected]"
    fi
}

assert_file() {
    if [ -f "$2" ]; then ok "$1"; else bad "$1: missing $2"; fi
}

assert_no_file() {
    if [ ! -e "$2" ]; then ok "$1"; else bad "$1: unexpected $2"; fi
}

write_source() {
    local name=$1
    mkdir -p "$SOURCE"
    cat > "$SOURCE/edgeconf_pim.json" <<EOF
{"VHL_CAM":{"vhl_name":"$name","capture":{"enable":true}}}
EOF
    cat > "$SOURCE/ord_vcm_conf.json" <<'EOF'
{"ORD":{"port_num":10007},"VCM":{"srt_enable":true}}
EOF
}

reset_dest() {
    rm -rf "$DEST" "$WORK/lock"
}

run_bootstrap() {
    env \
        PIM_CAMERA_CONFIG_SOURCE_DIR="$SOURCE" \
        PIM_CAMERA_CONFIG_DEST_DIR="$DEST" \
        PIM_CAMERA_CONFIG_BOOT_ID_FILE="$BOOT_ID_FILE" \
        PIM_CAMERA_CONFIG_LOCK_FILE="$LOCK_FILE" \
        PIM_CAMERA_CONFIG_TEST_FAILPOINT="${1:-}" \
        "$SCRIPT"
}

echo '=== camera config bootstrap ==='

# 1. Initial publish uses canonical names, READY last, and correct hashes.
write_source boot-a
echo boot-a > "$BOOT_ID_FILE"
cat > "$SOURCE/edgeconf_newer.json" <<'EOF'
{"VHL_CAM":{"vhl_name":"must-not-be-selected"}}
EOF
run_bootstrap >/dev/null
assert_file 'edgeconf published' "$DEST/edgeconf_pim.json"
assert_file 'ord_vcm published' "$DEST/ord_vcm_conf.json"
assert_file 'manifest published' "$DEST/boot_manifest.json"
assert_file 'READY published' "$DEST/READY"
assert_eq 'canonical edgeconf selected' \
    "$(jq -r '.VHL_CAM.vhl_name' "$DEST/edgeconf_pim.json")" 'boot-a'
assert_eq 'READY boot ID' "$(jq -r '.boot_id' "$DEST/READY")" 'boot-a'
assert_eq 'edge hash committed' \
    "$(jq -r '.files.edgeconf_pim.sha256' "$DEST/READY")" \
    "$(sha256sum "$DEST/edgeconf_pim.json" | awk '{print $1}')"

# 2. Same-boot direct runtime override remains authoritative. READY hash is an
# import record, not a hash pin.
cat > "$DEST/.edgeconf.runtime" <<'EOF'
{"VHL_CAM":{"vhl_name":"runtime-override","capture":{"enable":false}}}
EOF
mv "$DEST/.edgeconf.runtime" "$DEST/edgeconf_pim.json"
run_bootstrap >/dev/null
assert_eq 'same-boot runtime override preserved' \
    "$(jq -r '.VHL_CAM.vhl_name' "$DEST/edgeconf_pim.json")" 'runtime-override'
if [ "$(jq -r '.files.edgeconf_pim.sha256' "$DEST/READY")" != \
     "$(sha256sum "$DEST/edgeconf_pim.json" | awk '{print $1}')" ]; then
    ok 'READY hash mismatch does not republish shared_v'
else
    bad 'READY hash unexpectedly followed runtime override'
fi

# 3. Invalid current-boot runtime edit fails closed without silently restoring
# shared_v.
printf '{invalid\n' > "$DEST/edgeconf_pim.json"
if run_bootstrap >/dev/null 2>&1; then
    bad 'invalid runtime snapshot was accepted'
else
    ok 'invalid runtime snapshot rejected'
fi
assert_eq 'invalid runtime file not overwritten from shared_v' \
    "$(head -n 1 "$DEST/edgeconf_pim.json")" '{invalid'

# A current READY without its import manifest is incomplete and must not
# silently republish shared_v in the same boot.
write_source boot-a
cat > "$DEST/.edgeconf.runtime" <<'EOF'
{"VHL_CAM":{"vhl_name":"runtime-restored-for-manifest-test"}}
EOF
mv "$DEST/.edgeconf.runtime" "$DEST/edgeconf_pim.json"
rm -f "$DEST/boot_manifest.json"
if run_bootstrap >/dev/null 2>&1; then
    bad 'missing current-boot manifest was accepted'
else
    ok 'missing current-boot manifest rejected without re-import'
fi
assert_eq 'manifest failure preserves runtime override' \
    "$(jq -r '.VHL_CAM.vhl_name' "$DEST/edgeconf_pim.json")" \
    'runtime-restored-for-manifest-test'

# 4. Invalid canonical source cannot publish READY.
reset_dest
printf '{invalid\n' > "$SOURCE/edgeconf_pim.json"
echo boot-b > "$BOOT_ID_FILE"
if run_bootstrap >/dev/null 2>&1; then
    bad 'invalid canonical source was accepted'
else
    ok 'invalid canonical source rejected'
fi
assert_no_file 'READY absent after source validation failure' "$DEST/READY"

# Destination symlinks are rejected because the service runs as root on target.
reset_dest
write_source boot-b-safe
mkdir -p "$WORK/symlink-target"
ln -s "$WORK/symlink-target" "$DEST"
if run_bootstrap >/dev/null 2>&1; then
    bad 'symlink destination was accepted'
else
    ok 'symlink destination rejected'
fi
assert_no_file 'symlink target was not populated' "$WORK/symlink-target/READY"

# 5. A crash after the first member publish leaves READY absent. The next run
# reconciles both members and commits one generation.
reset_dest
write_source boot-c
echo boot-c > "$BOOT_ID_FILE"
if run_bootstrap after_edge_publish >/dev/null 2>&1; then
    bad 'publish failpoint did not fail'
else
    ok 'publish failpoint injected'
fi
assert_no_file 'READY absent after partial publish' "$DEST/READY"
run_bootstrap >/dev/null
assert_eq 'partial publish reconciled edge' \
    "$(jq -r '.VHL_CAM.vhl_name' "$DEST/edgeconf_pim.json")" 'boot-c'
assert_eq 'partial publish reconciled ord' \
    "$(jq -r '.ORD.port_num' "$DEST/ord_vcm_conf.json")" '10007'
assert_eq 'reconciled READY boot ID' "$(jq -r '.boot_id' "$DEST/READY")" 'boot-c'

# 6. A new boot imports the new canonical source exactly once.
write_source boot-d
echo boot-d > "$BOOT_ID_FILE"
run_bootstrap >/dev/null
assert_eq 'new boot imports shared_v' \
    "$(jq -r '.VHL_CAM.vhl_name' "$DEST/edgeconf_pim.json")" 'boot-d'

# 7. Concurrent invocations serialize through flock and produce one valid
# current-boot snapshot.
reset_dest
write_source boot-e
echo boot-e > "$BOOT_ID_FILE"
run_bootstrap >"$WORK/concurrent-1.log" 2>&1 & p1=$!
run_bootstrap >"$WORK/concurrent-2.log" 2>&1 & p2=$!
r1=0; r2=0
wait "$p1" || r1=$?
wait "$p2" || r2=$?
assert_eq 'concurrent publisher 1 exit' "$r1" '0'
assert_eq 'concurrent publisher 2 exit' "$r2" '0'
assert_eq 'concurrent READY generation' "$(jq -r '.boot_id' "$DEST/READY")" 'boot-e'
assert_eq 'no staging directory leaked' \
    "$(find "$DEST" -maxdepth 1 -type d -name '.staging-*' | wc -l)" '0'

# 8. Unit/package integration is additive: boot ordering and enablement are
# present, while consumers gain Requires only in their later migration phase.
if grep -q '^Requires=pim-config-guard.service$' "$UNIT"; then
    ok 'unit requires config guard'
else
    bad 'unit config guard dependency missing'
fi
if grep -q '^Before=cam-operate.service ord-operate.service vsd-operate.service$' "$UNIT"; then
    ok 'unit boot ordering declared'
else
    bad 'unit boot ordering missing'
fi
if grep -q '^Type=oneshot$' "$UNIT" && grep -q '^RemainAfterExit=yes$' "$UNIT"; then
    ok 'unit remains active per boot'
else
    bad 'unit oneshot shape invalid'
fi
if grep -q 'customctl enable pim-camera-config' "$POSTINST"; then
    ok 'package enables bootstrap service'
else
    bad 'postinst enable missing'
fi

# procfs boot ID. 이 스크립트의 기본 BOOT_ID_FILE 은 /proc/sys/kernel/random/boot_id
# 인데, procfs 는 stat 크기를 0 으로 보고한다. 예전 코드가 쓰던 `[ -s ]` 는 내용이
# 멀쩡해도 항상 거짓이라 실제 보드에서 매 boot 마다 실패했다. 위 케이스들이 전부
# 일반 임시 파일을 주입해서 이 경로를 한 번도 밟지 않았다.
PROC_BOOT_ID=/proc/sys/kernel/random/boot_id
if [ -r "$PROC_BOOT_ID" ]; then
    reset_dest
    write_source boot-proc
    real_boot_id=$(tr -d '\r\n' < "$PROC_BOOT_ID")
    if env \
        PIM_CAMERA_CONFIG_SOURCE_DIR="$SOURCE" \
        PIM_CAMERA_CONFIG_DEST_DIR="$DEST" \
        PIM_CAMERA_CONFIG_BOOT_ID_FILE="$PROC_BOOT_ID" \
        PIM_CAMERA_CONFIG_LOCK_FILE="$LOCK_FILE" \
        "$SCRIPT" >/dev/null 2>&1
    then
        ok 'procfs boot ID is accepted'
    else
        bad 'procfs boot ID rejected (stat size is 0 on procfs)'
    fi
    assert_eq 'procfs READY boot ID' "$(jq -r '.boot_id' "$DEST/READY" 2>/dev/null)" "$real_boot_id"
else
    skip 'procfs boot ID: 이 호스트에 /proc/sys/kernel/random/boot_id 가 없다'
fi

echo
printf 'camera config bootstrap: %d passed / %d failed / %d skipped\n' \
    "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
