#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
I2C_READ="$SCRIPT_DIR/i2cread.sh"
I2C_WRITE="$SCRIPT_DIR/i2cwrite.sh"

show_help() {
    echo "Usage: $tag [channel] [sensor_reg] [value_hex] [ap1302_addr] [port]"
    echo "  channel    : default 0"
    echo "  sensor_reg : default 0x3000"
    echo "  value_hex  : optional; if omitted, read only"
    echo "  ap1302_addr: optional override (default: 0x3c)"
    echo "  port       : 0=primary (default), 1=secondary"
    echo
    echo "Reads or writes a downstream sensor register through AP1302 DMA SIP access."
    echo "DMA access defaults to AP1302 main address 0x3c."
    echo "It derives sensor ID / width flags from SENSOR_SIP, then uses DMA for read/write."
    echo
    echo "Examples:"
    echo "  $tag 0 0x3000"
    echo "  $tag 0 0x3070 0x0001"
    echo "  $tag 0 0x3270 0x0103 0x3c"
}

die() {
    echo "[$tag] $*" >&2
    exit 1
}

get_bus_and_ap() {
    case "$1" in
        0) BUS=2; AP_ADDR=0x11 ;;
        1) BUS=2; AP_ADDR=0x12 ;;
        2) BUS=1; AP_ADDR=0x11 ;;
        3) BUS=1; AP_ADDR=0x12 ;;
        *) die "invalid channel: $1 (expected 0..3)" ;;
    esac
}

sleep_us() {
    local delay_us=$1
    if (( delay_us > 0 )); then
        sleep "$(printf '0.%06d' "$delay_us")"
    fi
}

read_reg_bytes() {
    local reg=$1
    local bytes=$2
    "$I2C_READ" "$BUS" "$AP_ADDR" "$reg" "$bytes"
}

parse_bytes_to_u32() {
    local output=$1
    local result=0
    local byte

    for byte in $output; do
        result=$(( (result << 8) | byte ))
    done

    printf "%u\n" "$result"
}

format_hex() {
    local value=$1
    local width=$2
    printf "0x%0*x" "$width" "$value"
}

read_reg_u32() {
    local reg=$1
    local bytes=$2
    local output

    output=$(read_reg_bytes "$reg" "$bytes") || return 1
    parse_bytes_to_u32 "$output"
}

write_reg() {
    local reg=$1
    local value=$2
    local width=$3
    local formatted

    case "$width" in
        2)
            formatted=$(printf "0x%04x" "$(( value & 0xffff ))")
            ;;
        4)
            formatted=$(printf "0x%08x" "$(( value & 0xffffffff ))")
            ;;
        *)
            return 1
            ;;
    esac

    "$I2C_WRITE" "$BUS" "$AP_ADDR" "$reg" "$formatted" 0 >/dev/null || return 1
}

wait_dma_idle() {
    local count=${DMA_POLL_COUNT:-20}
    local delay_us=${DMA_POLL_DELAY_US:-5000}
    local i ctrl

    for ((i = 0; i < count; i++)); do
        ctrl=$(read_reg_u32 0x60ac 2) || return 1
        if (( (ctrl & 0x7) == 0 )); then
            DMA_CTRL_LAST=$ctrl
            return 0
        fi
        sleep_us "$delay_us"
    done

    DMA_CTRL_LAST=$ctrl
    return 1
}

load_sensor_sip() {
    case "$PORT" in
        0)
            SIP_REG=0x604a
            SIP_BYTES=2
            ;;
        1)
            SIP_REG=0x604c
            SIP_BYTES=4
            ;;
        *)
            die "invalid port: $PORT (expected 0 or 1)"
            ;;
    esac

    SIP_RAW=$(read_reg_u32 "$SIP_REG" "$SIP_BYTES") ||
        die "failed to read SENSOR_SIP reg=$SIP_REG"

    SENSOR_ID=$(( (SIP_RAW >> 1) & 0x3f ))
    ADDR_16=$(( (SIP_RAW & 0x0100) ? 1 : 0 ))
    DATA_16=$(( (SIP_RAW & 0x0200) ? 1 : 0 ))
    DATA_SIZE=$(( DATA_16 ? 2 : 1 ))
}

dma_read_sensor_reg() {
    local sensor_reg=$1
    local dma_size_val dma_src_val dma_dst_val dma_ctrl_val dma_dst_raw value

    wait_dma_idle || die "DMA not idle before read ctrl=$(format_hex "$DMA_CTRL_LAST" 4)"

    dma_size_val=$DATA_SIZE
    dma_src_val=$(( (PORT << 26) | (DATA_16 << 25) | (ADDR_16 << 24) | (SENSOR_ID << 17) | (sensor_reg & 0xffff) ))
    dma_dst_val=0x000060a4
    dma_ctrl_val=0x0032

    write_reg 0x60a8 "$dma_size_val" 4 || die "failed to write DMA_SIZE(read)"
    write_reg 0x60a0 "$dma_src_val" 4 || die "failed to write DMA_SRC(read)"
    write_reg 0x60a4 "$dma_dst_val" 4 || die "failed to write DMA_DST(read)"
    write_reg 0x60ac "$dma_ctrl_val" 2 || die "failed to write DMA_CTRL(read)"

    wait_dma_idle || die "DMA read did not return idle ctrl=$(format_hex "$DMA_CTRL_LAST" 4)"
    dma_dst_raw=$(read_reg_u32 0x60a4 4) || die "failed to read DMA_DST(read)"
    value=$(( dma_dst_raw >> (32 - DATA_SIZE * 8) ))

    echo "$dma_dst_raw $value $dma_src_val $dma_ctrl_val"
}

dma_write_sensor_reg() {
    local sensor_reg=$1
    local value=$2
    local dma_size_val dma_src_val dma_dst_val dma_ctrl_val

    wait_dma_idle || die "DMA not idle before write ctrl=$(format_hex "$DMA_CTRL_LAST" 4)"

    dma_size_val=$DATA_SIZE
    dma_src_val=$(( ((value & ((1 << (DATA_SIZE * 8)) - 1)) << 16) | 0x000060a0 ))
    dma_dst_val=$(( (PORT << 26) | (DATA_16 << 25) | (ADDR_16 << 24) | (SENSOR_ID << 17) | (sensor_reg & 0xffff) ))
    dma_ctrl_val=0x0302

    write_reg 0x60a8 "$dma_size_val" 4 || die "failed to write DMA_SIZE(write)"
    write_reg 0x60a0 "$dma_src_val" 4 || die "failed to write DMA_SRC(write)"
    write_reg 0x60a4 "$dma_dst_val" 4 || die "failed to write DMA_DST(write)"
    write_reg 0x60ac "$dma_ctrl_val" 2 || die "failed to write DMA_CTRL(write)"

    echo "$dma_src_val $dma_dst_val $dma_ctrl_val"

    wait_dma_idle || die "DMA write did not return idle ctrl=$(format_hex "$DMA_CTRL_LAST" 4)"
}

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_help
    exit 0
fi

[[ -x "$I2C_READ" ]] || die "missing helper: $I2C_READ"
[[ -x "$I2C_WRITE" ]] || die "missing helper: $I2C_WRITE"

CHANNEL=${1:-0}
SENSOR_REG_RAW=${2:-0x3000}
VALUE_RAW=${3:-}
PORT=${5:-0}

get_bus_and_ap "$CHANNEL"
AP_ADDR=0x3c
if [[ -n "${4:-}" ]]; then
    AP_ADDR=${4,,}
fi

SENSOR_REG=$((SENSOR_REG_RAW)) || die "invalid sensor_reg: $SENSOR_REG_RAW"
if [[ -n "$VALUE_RAW" ]]; then
    VALUE_DEC=$((VALUE_RAW)) || die "invalid value_hex: $VALUE_RAW"
fi

load_sensor_sip

echo "[$tag] channel=$CHANNEL bus=$BUS ap1302=$AP_ADDR port=$PORT sensor_reg=$(format_hex "$SENSOR_REG" 4)"
echo "[$tag] sensor_sip_reg=$(format_hex "$SIP_REG" 4) raw=$(format_hex "$SIP_RAW" 8) sensor_id=$(format_hex "$SENSOR_ID" 2) addr_16=$ADDR_16 data_16=$DATA_16 data_size=$DATA_SIZE"

ERR0=$(read_reg_u32 0x0014 2) || die "failed to read SIPM_ERR_0"
ERR1=$(read_reg_u32 0x0016 2) || die "failed to read SIPM_ERR_1"
echo "[$tag] sipm_err_before err0=$(format_hex "$ERR0" 4) err1=$(format_hex "$ERR1" 4)"

READ_RESULT=$(dma_read_sensor_reg "$SENSOR_REG") || die "DMA read-before failed"
read -r DMA_DST_RAW BEFORE DMA_SRC_VAL DMA_CTRL_VAL <<<"$READ_RESULT"
echo "[$tag] read-before dma_src=$(format_hex "$DMA_SRC_VAL" 8) dma_ctrl=$(format_hex "$DMA_CTRL_VAL" 4) raw_dst=$(format_hex "$DMA_DST_RAW" 8) value=$(format_hex "$BEFORE" $((DATA_SIZE * 2)))"

if [[ -z "$VALUE_RAW" ]]; then
    exit 0
fi

WRITE_RESULT=$(dma_write_sensor_reg "$SENSOR_REG" "$VALUE_DEC") || die "DMA write failed"
read -r DMA_SRC_WRITE DMA_DST_WRITE DMA_CTRL_WRITE <<<"$WRITE_RESULT"
echo "[$tag] write dma_src=$(format_hex "$DMA_SRC_WRITE" 8) dma_dst=$(format_hex "$DMA_DST_WRITE" 8) dma_ctrl=$(format_hex "$DMA_CTRL_WRITE" 4) value=$(format_hex "$VALUE_DEC" $((DATA_SIZE * 2)))"

READ_RESULT=$(dma_read_sensor_reg "$SENSOR_REG") || die "DMA read-after failed"
read -r DMA_DST_RAW AFTER DMA_SRC_VAL DMA_CTRL_VAL <<<"$READ_RESULT"
ERR0=$(read_reg_u32 0x0014 2) || die "failed to read SIPM_ERR_0 after write"
ERR1=$(read_reg_u32 0x0016 2) || die "failed to read SIPM_ERR_1 after write"

echo "[$tag] read-after  dma_src=$(format_hex "$DMA_SRC_VAL" 8) dma_ctrl=$(format_hex "$DMA_CTRL_VAL" 4) raw_dst=$(format_hex "$DMA_DST_RAW" 8) value=$(format_hex "$AFTER" $((DATA_SIZE * 2)))"
echo "[$tag] sipm_err_after err0=$(format_hex "$ERR0" 4) err1=$(format_hex "$ERR1" 4)"

if [[ "$AFTER" -eq "$VALUE_DEC" ]]; then
    echo "[$tag] verify: PASS"
    exit 0
fi

echo "[$tag] verify: FAIL expected=$(format_hex "$VALUE_DEC" $((DATA_SIZE * 2))) actual=$(format_hex "$AFTER" $((DATA_SIZE * 2)))" >&2
exit 1
