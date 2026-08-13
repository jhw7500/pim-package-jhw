#!/bin/bash
# Publish a validated, boot-scoped camera configuration snapshot.
#
# /root/shared_v is read only on the first successful invocation for a boot.
# Consumers are migrated separately; this producer is additive until their
# systemd units gain Requires/After=pim-camera-config.service.

set -Eeu -o pipefail
umask 027

KEY=CAM-CONFIG
tag=$(basename "$0")

SOURCE_DIR=${PIM_CAMERA_CONFIG_SOURCE_DIR:-/root/shared_v}
DEST_DIR=${PIM_CAMERA_CONFIG_DEST_DIR:-/tmp/config}
BOOT_ID_FILE=${PIM_CAMERA_CONFIG_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
LOCK_FILE=${PIM_CAMERA_CONFIG_LOCK_FILE:-/run/lock/pim-camera-config.lock}
TEST_FAILPOINT=${PIM_CAMERA_CONFIG_TEST_FAILPOINT:-}

EDGE_SOURCE="$SOURCE_DIR/edgeconf_pim.json"
ORD_SOURCE="$SOURCE_DIR/ord_vcm_conf.json"
EDGE_DEST="$DEST_DIR/edgeconf_pim.json"
ORD_DEST="$DEST_DIR/ord_vcm_conf.json"
MANIFEST_DEST="$DEST_DIR/boot_manifest.json"
READY_DEST="$DEST_DIR/READY"

STAGING_DIR=""

log_info() {
    logger -p local0.info "[$KEY][$tag:${BASH_LINENO[0]}] $*" 2>/dev/null || true
    echo "[$KEY] $*"
}

log_error() {
    logger -p local0.err "[$KEY][$tag:${BASH_LINENO[0]}] $*" 2>/dev/null || true
    echo "[$KEY][ERROR] $*" >&2
}

cleanup() {
    [ -z "$STAGING_DIR" ] || rm -rf -- "$STAGING_DIR"
}
trap cleanup EXIT

failpoint() {
    [ "$TEST_FAILPOINT" != "$1" ] || {
        log_error "test failpoint triggered: $1"
        exit 97
    }
}

validate_edgeconf() {
    local path=$1
    [ -s "$path" ] &&
        jq -e 'type == "object" and has("VHL_CAM") and (.VHL_CAM | type == "object")' \
            "$path" >/dev/null 2>&1
}

validate_ord_vcm() {
    local path=$1
    [ -s "$path" ] &&
        jq -e 'type == "object" and has("ORD") and has("VCM") and
               (.ORD | type == "object") and (.VCM | type == "object")' \
            "$path" >/dev/null 2>&1
}

validate_runtime_snapshot() {
    local boot_id=$1
    validate_edgeconf "$EDGE_DEST" &&
        validate_ord_vcm "$ORD_DEST" &&
        [ -s "$MANIFEST_DEST" ] &&
        jq -e --arg boot_id "$boot_id" \
            '.schema == 1 and .boot_id == $boot_id and
             (.files.edgeconf_pim.sha256 | strings | test("^[0-9a-f]{64}$")) and
             (.files.ord_vcm_conf.sha256 | strings | test("^[0-9a-f]{64}$"))' \
            "$MANIFEST_DEST" >/dev/null 2>&1
}

sync_path() {
    sync "$1" 2>/dev/null || true
}

main() {
    command -v jq >/dev/null 2>&1 || {
        log_error "jq not found"
        return 1
    }
    command -v sha256sum >/dev/null 2>&1 || {
        log_error "sha256sum not found"
        return 1
    }
    command -v flock >/dev/null 2>&1 || {
        log_error "flock not found"
        return 1
    }

    [ -s "$BOOT_ID_FILE" ] || {
        log_error "boot ID unavailable: $BOOT_ID_FILE"
        return 1
    }

    local boot_id
    boot_id=$(tr -d '\r\n' < "$BOOT_ID_FILE")
    case "$boot_id" in
        ""|*[!A-Za-z0-9._-]*)
            log_error "invalid boot ID"
            return 1
            ;;
    esac

    [ ! -L "$DEST_DIR" ] || {
        log_error "destination must not be a symlink: $DEST_DIR"
        return 1
    }
    mkdir -p -- "$DEST_DIR" "$(dirname "$LOCK_FILE")"
    chmod 0750 "$DEST_DIR"

    exec 9>"$LOCK_FILE"
    flock -x 9

    # A current-boot READY is an idempotency marker, not a permanent hash pin.
    # Engineers may atomically edit /tmp/config during the boot. Never re-import
    # shared_v merely because current file hashes differ from boot_manifest.
    if [ -s "$READY_DEST" ] &&
        jq -e --arg boot_id "$boot_id" \
            '.schema == 1 and .boot_id == $boot_id and
             (.files.edgeconf_pim.sha256 | strings | test("^[0-9a-f]{64}$")) and
             (.files.ord_vcm_conf.sha256 | strings | test("^[0-9a-f]{64}$"))' \
            "$READY_DEST" >/dev/null 2>&1; then
        if validate_runtime_snapshot "$boot_id"; then
            log_info "current boot snapshot already published; no-op"
            return 0
        fi
        log_error "current boot snapshot is missing/invalid; refusing shared_v re-import"
        return 1
    fi

    validate_edgeconf "$EDGE_SOURCE" || {
        log_error "invalid canonical edgeconf: $EDGE_SOURCE"
        return 1
    }
    validate_ord_vcm "$ORD_SOURCE" || {
        log_error "invalid canonical ord_vcm config: $ORD_SOURCE"
        return 1
    }

    STAGING_DIR=$(mktemp -d "$DEST_DIR/.staging-${boot_id}.XXXXXX")
    install -m 0640 "$EDGE_SOURCE" "$STAGING_DIR/edgeconf_pim.json"
    install -m 0640 "$ORD_SOURCE" "$STAGING_DIR/ord_vcm_conf.json"

    # Re-parse staged copies so a concurrent source writer cannot publish a
    # partially copied file. config_guard remains the canonical repair owner.
    validate_edgeconf "$STAGING_DIR/edgeconf_pim.json" || {
        log_error "staged edgeconf validation failed"
        return 1
    }
    validate_ord_vcm "$STAGING_DIR/ord_vcm_conf.json" || {
        log_error "staged ord_vcm validation failed"
        return 1
    }

    local edge_hash ord_hash committed_at
    edge_hash=$(sha256sum "$STAGING_DIR/edgeconf_pim.json" | awk '{print $1}')
    ord_hash=$(sha256sum "$STAGING_DIR/ord_vcm_conf.json" | awk '{print $1}')
    committed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    jq -n \
        --arg boot_id "$boot_id" \
        --arg committed_at "$committed_at" \
        --arg edge_source "$EDGE_SOURCE" \
        --arg edge_hash "$edge_hash" \
        --arg ord_source "$ORD_SOURCE" \
        --arg ord_hash "$ord_hash" \
        '{
          schema: 1,
          boot_id: $boot_id,
          committed_at: $committed_at,
          files: {
            edgeconf_pim: {source: $edge_source, sha256: $edge_hash},
            ord_vcm_conf: {source: $ord_source, sha256: $ord_hash}
          }
        }' > "$STAGING_DIR/boot_manifest.json"

    jq -n \
        --arg boot_id "$boot_id" \
        --arg committed_at "$committed_at" \
        --arg edge_hash "$edge_hash" \
        --arg ord_hash "$ord_hash" \
        '{
          schema: 1,
          boot_id: $boot_id,
          committed_at: $committed_at,
          files: {
            edgeconf_pim: {sha256: $edge_hash},
            ord_vcm_conf: {sha256: $ord_hash}
          }
        }' > "$STAGING_DIR/READY"
    chmod 0640 "$STAGING_DIR/boot_manifest.json" "$STAGING_DIR/READY"

    sync_path "$STAGING_DIR/edgeconf_pim.json"
    sync_path "$STAGING_DIR/ord_vcm_conf.json"
    sync_path "$STAGING_DIR/boot_manifest.json"
    sync_path "$STAGING_DIR/READY"
    failpoint after_stage

    # Invalidate an old boot commit before replacing any member. READY is the
    # transaction commit marker and is always renamed last.
    rm -f -- "$READY_DEST"
    sync_path "$DEST_DIR"
    failpoint after_ready_remove

    mv -f -- "$STAGING_DIR/edgeconf_pim.json" "$EDGE_DEST"
    failpoint after_edge_publish
    mv -f -- "$STAGING_DIR/ord_vcm_conf.json" "$ORD_DEST"
    failpoint after_ord_publish
    mv -f -- "$STAGING_DIR/boot_manifest.json" "$MANIFEST_DEST"
    failpoint before_ready_publish
    mv -f -- "$STAGING_DIR/READY" "$READY_DEST"
    sync_path "$DEST_DIR"

    rmdir -- "$STAGING_DIR"
    STAGING_DIR=""
    log_info "boot snapshot published: boot_id=$boot_id"
}

main "$@"
