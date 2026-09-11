#!/bin/bash
# Offline tests for the guard-only camera_config_bootstrap.sh.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/dist/pim/opt/pim/bin/camera_config_bootstrap.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/camera-config-guard-test.XXXXXX")
SOURCE="$WORK/shared_v"
DEST="$WORK/runtime"
BOOT_ID_FILE="$WORK/boot_id"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  OK   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1" >&2; }

run_guard() {
    env PIM_CAMERA_CONFIG_SOURCE_DIR="$SOURCE" \
        PIM_CAMERA_CONFIG_DEST_DIR="$DEST" \
        PIM_CAMERA_CONFIG_BOOT_ID_FILE="$BOOT_ID_FILE" \
        "$SCRIPT"
}

echo '=== camera config bootstrap guard ==='
mkdir -p "$SOURCE"
printf 'boot-a\n' > "$BOOT_ID_FILE"
printf '{"ORD":{},"VCM":{}}\n' > "$SOURCE/ord_vcm_conf.json"
printf '{"VHL_CAM":{"vhl_name":"older"}}\n' > "$SOURCE/edgeconf_pim.json"
printf '{"VHL_CAM":{"vhl_name":"newer"}}\n' > "$SOURCE/edgeconf_newer.json"

if run_guard >/dev/null 2>&1; then ok 'available prerequisites pass'; else bad 'available prerequisites pass'; fi
if [ ! -e "$DEST" ]; then ok 'guard creates nothing beneath runtime directory'; else bad 'guard mutated runtime directory'; fi
if [ "$(jq -r '.VHL_CAM.vhl_name' "$SOURCE/edgeconf_newer.json")" = newer ]; then ok 'newer edgeconf remains unselected and unmodified'; else bad 'newer edgeconf changed'; fi
rm "$SOURCE/ord_vcm_conf.json"
if run_guard >/dev/null 2>&1; then bad 'missing ord document rejected'; else ok 'missing ord document rejected'; fi
printf '{"ORD":{},"VCM":{}}\n' > "$SOURCE/ord_vcm_conf.json"
rm "$BOOT_ID_FILE"
if run_guard >/dev/null 2>&1; then bad 'missing boot ID rejected'; else ok 'missing boot ID rejected'; fi

echo
printf 'camera config bootstrap guard: %d passed / %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
