#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DUMP_SCRIPT="$SCRIPT_DIR/cam_ar0234_dma_clock_dump.sh"
VERIFY_SCRIPT="$SCRIPT_DIR/cam_ap1302_dma_verify.sh"
CHANNEL_HELPER="$SCRIPT_DIR/cam_channel_resolve.sh"

DEFAULT_BACKUP_FILE="/tmp/ar0234_clock_regs_backup.txt"
REG_LIST=(0x31ae 0x302a 0x302c 0x302e 0x3030 0x3036 0x3038 0x30ba)

show_help() {
    echo "Usage: $tag <backup|set|restore> [args]"
    echo
    echo "Commands:"
    echo "  backup <channel> [port] [file]"
    echo "  set <channel> <reg_hex> <value_hex> [port] [file]"
    echo "  restore <channel> [port] [file]"
    echo
    echo "Default backup file: $DEFAULT_BACKUP_FILE"
    echo
    echo "Examples:"
    echo "  $tag backup 0"
    echo "  $tag set 0 0x3036 0x0008"
    echo "  $tag restore 0"
    echo "  $tag set 3 0x31ae 0x0204 0 /tmp/my_clock_backup.txt"
}

die() {
    echo "[$tag] $*" >&2
    exit 1
}

read_value() {
    local reg=$1
    local output value

    output=$("$VERIFY_SCRIPT" "$CHANNEL" "$reg" "" "$PORT" 2>&1) ||
        die "read failed for reg=$reg"

    value=$(printf "%s\n" "$output" | grep 'read-before' | sed -E 's/.*value=(0x[0-9a-fA-F]+).*/\1/' | tail -n 1)
    [[ -n "$value" ]] || die "failed to parse value for reg=$reg"
    printf "%s\n" "$value"
}

write_value() {
    local reg=$1
    local value=$2

    "$VERIFY_SCRIPT" "$CHANNEL" "$reg" "$value" "$PORT"
}

backup_regs() {
    : > "$BACKUP_FILE" || die "cannot write backup file: $BACKUP_FILE"

    {
        echo "# AR0234 clock backup"
        echo "CHANNEL=$CHANNEL"
        echo "AP_ADDR=${AP_ADDR:-default}"
        echo "PORT=$PORT"
        for reg in "${REG_LIST[@]}"; do
            echo "$reg=$(read_value "$reg")"
        done
    } > "$BACKUP_FILE" || die "failed to write backup contents"

    echo "[$tag] backup saved: $BACKUP_FILE"
}

restore_regs() {
    [[ -f "$BACKUP_FILE" ]] || die "backup file not found: $BACKUP_FILE"

    while IFS='=' read -r reg value; do
        [[ -z "$reg" ]] && continue
        [[ "$reg" != 0x* ]] && continue
        [[ -z "$value" ]] && continue

        echo "[$tag] restore $reg -> $value"
        write_value "$reg" "$value" >/dev/null || die "restore failed for $reg"
    done < "$BACKUP_FILE"

    echo "[$tag] restore complete"
}

command=${1:-}
[[ -n "$command" ]] || {
    show_help
    exit 0
}

[[ "$command" == "--help" || "$command" == "-h" ]] && {
    show_help
    exit 0
}

[[ -x "$DUMP_SCRIPT" ]] || die "missing helper: $DUMP_SCRIPT"
[[ -x "$VERIFY_SCRIPT" ]] || die "missing helper: $VERIFY_SCRIPT"

case "$command" in
    backup)
        CHANNEL=${2:-}
        PORT=${3:-0}
        BACKUP_FILE=${4:-$DEFAULT_BACKUP_FILE}

        [[ -n "$CHANNEL" ]] || die "backup requires <channel>"
        resolve_channel_context "$CHANNEL"

        echo "[$tag] backup channel=$CHANNEL i2c_line=$BUS ap1302=$AP_ADDR mode=$MODE source=$RESOLVE_SOURCE port=$PORT file=$BACKUP_FILE"
        backup_regs
        ;;

    set)
        CHANNEL=${2:-}
        REG=${3:-}
        VALUE=${4:-}
        PORT=${5:-0}
        BACKUP_FILE=${6:-$DEFAULT_BACKUP_FILE}

        [[ -n "$CHANNEL" && -n "$REG" && -n "$VALUE" ]] || die "set requires <channel> <reg_hex> <value_hex>"
        resolve_channel_context "$CHANNEL"

        echo "[$tag] set channel=$CHANNEL reg=$REG value=$VALUE i2c_line=$BUS ap1302=$AP_ADDR mode=$MODE source=$RESOLVE_SOURCE port=$PORT"
        if [[ ! -f "$BACKUP_FILE" ]]; then
            echo "[$tag] backup file missing, creating: $BACKUP_FILE"
            backup_regs
        fi

        write_value "$REG" "$VALUE"
        ;;

    restore)
        CHANNEL=${2:-}
        PORT=${3:-0}
        BACKUP_FILE=${4:-$DEFAULT_BACKUP_FILE}

        [[ -n "$CHANNEL" ]] || die "restore requires <channel>"
        resolve_channel_context "$CHANNEL"

        echo "[$tag] restore channel=$CHANNEL i2c_line=$BUS ap1302=$AP_ADDR mode=$MODE source=$RESOLVE_SOURCE port=$PORT file=$BACKUP_FILE"
        restore_regs
        ;;

    *)
        die "invalid command: $command"
        ;;
esac
