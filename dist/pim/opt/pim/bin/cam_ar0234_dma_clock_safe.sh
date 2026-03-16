#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DUMP_SCRIPT="$SCRIPT_DIR/cam_ar0234_dma_clock_dump.sh"
VERIFY_SCRIPT="$SCRIPT_DIR/cam_ap1302_dma_verify.sh"

DEFAULT_BACKUP_FILE="/tmp/ar0234_clock_regs_backup.txt"
REG_LIST=(0x31ae 0x302a 0x302c 0x302e 0x3030 0x3036 0x3038 0x30ba)

show_help() {
    echo "Usage: $tag <backup|set|restore> [args]"
    echo
    echo "Commands:"
    echo "  backup [channel] [ap1302_addr] [port] [file]"
    echo "  set <reg_hex> <value_hex> [channel] [ap1302_addr] [port] [file]"
    echo "  restore [channel] [ap1302_addr] [port] [file]"
    echo
    echo "Default backup file: $DEFAULT_BACKUP_FILE"
    echo
    echo "Examples:"
    echo "  $tag backup"
    echo "  $tag set 0x3036 0x0008"
    echo "  $tag restore"
    echo "  $tag set 0x31ae 0x0204 0 0x3c 0 /tmp/my_clock_backup.txt"
}

die() {
    echo "[$tag] $*" >&2
    exit 1
}

read_value() {
    local reg=$1
    local output value

    if [[ -n "$AP_ADDR" ]]; then
        output=$("$VERIFY_SCRIPT" "$CHANNEL" "$reg" "" "$AP_ADDR" "$PORT" 2>&1) ||
            die "read failed for reg=$reg"
    else
        output=$("$VERIFY_SCRIPT" "$CHANNEL" "$reg" 2>&1) ||
            die "read failed for reg=$reg"
    fi

    value=$(printf "%s\n" "$output" | grep 'read-before' | sed -E 's/.*value=(0x[0-9a-fA-F]+).*/\1/' | tail -n 1)
    [[ -n "$value" ]] || die "failed to parse value for reg=$reg"
    printf "%s\n" "$value"
}

write_value() {
    local reg=$1
    local value=$2

    if [[ -n "$AP_ADDR" ]]; then
        "$VERIFY_SCRIPT" "$CHANNEL" "$reg" "$value" "$AP_ADDR" "$PORT"
    else
        "$VERIFY_SCRIPT" "$CHANNEL" "$reg" "$value"
    fi
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
        CHANNEL=${2:-0}
        AP_ADDR=${3:-}
        PORT=${4:-0}
        BACKUP_FILE=${5:-$DEFAULT_BACKUP_FILE}

        echo "[$tag] backup channel=$CHANNEL ap1302=${AP_ADDR:-default} port=$PORT file=$BACKUP_FILE"
        backup_regs
        ;;

    set)
        REG=${2:-}
        VALUE=${3:-}
        CHANNEL=${4:-0}
        AP_ADDR=${5:-}
        PORT=${6:-0}
        BACKUP_FILE=${7:-$DEFAULT_BACKUP_FILE}

        [[ -n "$REG" && -n "$VALUE" ]] || die "set requires <reg_hex> <value_hex>"

        echo "[$tag] set reg=$REG value=$VALUE channel=$CHANNEL ap1302=${AP_ADDR:-default} port=$PORT"
        if [[ ! -f "$BACKUP_FILE" ]]; then
            echo "[$tag] backup file missing, creating: $BACKUP_FILE"
            backup_regs
        fi

        write_value "$REG" "$VALUE"
        ;;

    restore)
        CHANNEL=${2:-0}
        AP_ADDR=${3:-}
        PORT=${4:-0}
        BACKUP_FILE=${5:-$DEFAULT_BACKUP_FILE}

        echo "[$tag] restore channel=$CHANNEL ap1302=${AP_ADDR:-default} port=$PORT file=$BACKUP_FILE"
        restore_regs
        ;;

    *)
        die "invalid command: $command"
        ;;
esac
