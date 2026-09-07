#!/bin/bash

# Tests may override one file, but consumers never select a source directory.
PIM_CAMERA_RUNTIME_JSON="${PIM_CAMERA_RUNTIME_JSON:-/run/pim-camera/config/pim_runtime.json}"
PIM_CAMERA_RUNTIME_SNAPSHOT=""
PIM_CAMERA_RUNTIME_SNAPSHOT_FD=""
PIM_CAMERA_RUNTIME_CAPTURE_FAILED=0

if [[ -e "$PIM_CAMERA_RUNTIME_JSON" ]]; then
    runtime_snapshot_file=$(mktemp "${TMPDIR:-/tmp}/pim-camera-runtime.XXXXXX") || \
        PIM_CAMERA_RUNTIME_CAPTURE_FAILED=1
    if [[ "$PIM_CAMERA_RUNTIME_CAPTURE_FAILED" -eq 0 ]]; then
        if ! cat -- "$PIM_CAMERA_RUNTIME_JSON" > "$runtime_snapshot_file"; then
            rm -f -- "$runtime_snapshot_file"
            PIM_CAMERA_RUNTIME_CAPTURE_FAILED=1
        else
            chmod 400 "$runtime_snapshot_file"
            if exec {PIM_CAMERA_RUNTIME_SNAPSHOT_FD}<"$runtime_snapshot_file"; then
                PIM_CAMERA_RUNTIME_SNAPSHOT="/proc/$$/fd/$PIM_CAMERA_RUNTIME_SNAPSHOT_FD"
            else
                PIM_CAMERA_RUNTIME_CAPTURE_FAILED=1
            fi
            rm -f -- "$runtime_snapshot_file"
        fi
    fi
    unset runtime_snapshot_file
fi

validate_camera_runtime() {
    local file=$1
    command -v jq >/dev/null 2>&1 || return 1
    [[ -f "$file" ]] || return 1
    jq -e '
        type == "object" and
        (.VHL_CAM | type == "object") and
        (.ORD | type == "object") and
        (.VCM | type == "object")
    ' "$file" >/dev/null 2>&1
}

find_edgeconf_file() {
    [[ "$PIM_CAMERA_RUNTIME_CAPTURE_FAILED" -eq 0 ]] || return 1
    [[ -n "$PIM_CAMERA_RUNTIME_SNAPSHOT" ]] || return 1
    validate_camera_runtime "$PIM_CAMERA_RUNTIME_SNAPSHOT" || return 1
    printf '%s\n' "$PIM_CAMERA_RUNTIME_SNAPSHOT"
}

channel_alias_addr() {
    case "$1" in
        0|2) printf "0x11\n" ;;
        1|3) printf "0x12\n" ;;
        *) return 1 ;;
    esac
}

channel_bus_key() {
    case "$1" in
        0|1) printf "i2c2\n" ;;
        2|3) printf "i2c1\n" ;;
        *) return 1 ;;
    esac
}

detect_mode_from_config() {
    local channel=$1
    local file=$2
    local bus_key first second values

    command -v jq >/dev/null 2>&1 || return 1
    [[ -f "$file" ]] || return 1

    case "$channel" in
        0|1) bus_key=i2c2; first=ch0; second=ch1 ;;
        2|3) bus_key=i2c1; first=ch2; second=ch3 ;;
        *) return 1 ;;
    esac

    values=$(jq -r --arg bus "$bus_key" --arg first "$first" --arg second "$second" \
        '[.VHL_CAM[$bus][$first].enable // false, .VHL_CAM[$bus][$second].enable // false] | @tsv' "$file" 2>/dev/null) || return 1

    case "$values" in
        $'true\ttrue') printf "dual\n" ;;
        $'true\tfalse'|$'false\ttrue') printf "single\n" ;;
        *) return 1 ;;
    esac
}

detect_mode_from_i2cdetect() {
    local bus=$1
    local alias
    local scan

    command -v i2cdetect >/dev/null 2>&1 || return 1
    scan=$(i2cdetect -y "$bus" 0x03 0x3f 2>/dev/null) || return 1

    if printf "%s\n" "$scan" | grep -Eq '(^|[[:space:]])11([[:space:]]|$)' && \
       printf "%s\n" "$scan" | grep -Eq '(^|[[:space:]])12([[:space:]]|$)'; then
        printf "dual\n"
        return 0
    fi

    if printf "%s\n" "$scan" | grep -Eq '(^|[[:space:]])3c([[:space:]]|$)'; then
        printf "single\n"
        return 0
    fi

    alias=$(channel_alias_addr "$CHANNEL") || return 1
    if printf "%s\n" "$scan" | grep -Eiq "(^|[[:space:]])${alias#0x}([[:space:]]|$)"; then
        printf "dual\n"
        return 0
    fi

    return 1
}

resolve_channel_context() {
    CHANNEL=$1
    case "$CHANNEL" in
        0|1) BUS=2 ;;
        2|3) BUS=1 ;;
        *) die "invalid channel: $CHANNEL (expected 0..3)" ;;
    esac

    EDGECONF_FILE=""
    RESOLVE_SOURCE=""
    MODE=""

    if [[ "$PIM_CAMERA_RUNTIME_CAPTURE_FAILED" -ne 0 ]]; then
        die "CONFIG_INVALID: $PIM_CAMERA_RUNTIME_JSON"
    fi
    if [[ -n "$PIM_CAMERA_RUNTIME_SNAPSHOT" ]]; then
        validate_camera_runtime "$PIM_CAMERA_RUNTIME_SNAPSHOT" || \
            die "CONFIG_INVALID: $PIM_CAMERA_RUNTIME_JSON"
        EDGECONF_FILE="$PIM_CAMERA_RUNTIME_SNAPSHOT"
        MODE=$(detect_mode_from_config "$CHANNEL" "$EDGECONF_FILE" 2>/dev/null || true)
        if [[ -n "$MODE" ]]; then
            RESOLVE_SOURCE="edgeconf"
        fi
    fi

    if [[ -z "$MODE" ]]; then
        MODE=$(detect_mode_from_i2cdetect "$BUS" 2>/dev/null || true)
        if [[ -n "$MODE" ]]; then
            RESOLVE_SOURCE="i2cdetect"
        fi
    fi

    [[ -n "$MODE" ]] || die "failed to resolve single/dual mode for channel $CHANNEL"

    if [[ "$MODE" == "dual" ]]; then
        AP_ADDR=$(channel_alias_addr "$CHANNEL") || die "failed to resolve alias for channel $CHANNEL"
    else
        AP_ADDR=0x3c
    fi
}
