#!/bin/bash
# Check that the camera runtime-config transaction has the prerequisites it needs.
# Publication belongs exclusively to camera_runtime_config.py and its consumer.

set -Eeu -o pipefail

KEY=CAM-CONFIG
tag=$(basename "$0")
SOURCE_DIR=${PIM_CAMERA_CONFIG_SOURCE_DIR:-/root/shared_v}
BOOT_ID_FILE=${PIM_CAMERA_CONFIG_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}

fail() {
    printf '[%s][%s][ERROR] %s\n' "$KEY" "$tag" "$*" >&2
    return 1
}

main() {
    [ -d "$SOURCE_DIR" ] && [ -r "$SOURCE_DIR" ] || fail "source root unavailable: $SOURCE_DIR"
    [ -f "$SOURCE_DIR/ord_vcm_conf.json" ] && [ ! -L "$SOURCE_DIR/ord_vcm_conf.json" ] && [ -r "$SOURCE_DIR/ord_vcm_conf.json" ] || \
        fail "ord_vcm_conf.json unavailable: $SOURCE_DIR/ord_vcm_conf.json"
    [ -r "$BOOT_ID_FILE" ] || fail "boot ID unavailable: $BOOT_ID_FILE"
    for command in python3 jq flock logger; do
        command -v "$command" >/dev/null 2>&1 || fail "$command not found"
    done
    logger -p local0.info "[$KEY][$tag] runtime config prerequisites available" 2>/dev/null || true
}

main "$@"
