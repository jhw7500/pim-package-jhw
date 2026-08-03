#!/bin/bash

tag=$(basename "$0")
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHANNEL_HELPER="$SCRIPT_DIR/cam_channel_resolve.sh"

usage() {
    echo "Usage: $tag <channel> <command> [value]"
    echo "  channel: 0, 1, 2, 3"
    echo "  command: on, off, set, get"
    echo ""
    echo "Examples:"
    echo "  $tag 0 on        # Enable channel 0"
    echo "  $tag 0 off       # Disable channel 0"
    echo "  $tag 0 set 0x10  # Set MCP4018 wiper value"
    echo "  $tag 0 get       # Get MCP4018 wiper value"
    exit 1
}

die() {
    echo "[$tag] $*" >&2
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

CHANNEL=$1
COMMAND=$2

MCP4018_ADDR=0x2f

# 버스는 모드와 무관하다. set/get 은 MCP4018(0x2f)로 직접 가므로 듀얼/단일 판정이
# 필요 없고, 판정에 실패했다고 막히면 안 된다. 그래서 여기서 따로 정한다.
case "$CHANNEL" in
    0|1) I2C_BUS=2 ;;
    2|3) I2C_BUS=1 ;;
    *)   die "invalid channel: $CHANNEL (expected 0..3)" ;;
esac

# ── 시리얼라이저 주소 ──────────────────────────────────────────────────
# 0x60 은 홀수 채널의 하드웨어 속성이 아니다. 듀얼 구성 초기화에서만 한쪽
# 시리얼라이저를 0x40 → 0x60 으로 옮기기 때문에 생기는 주소다 — max9296.c 의
# 2ch 테이블에 있는 {0x40, 0x0000, 2, 0xC0} 이 드라이버 전체에서 유일한
# 시리얼라이저 자기주소 쓰기다. 단일채널 테이블에는 그 리맵이 없다.
#
#   실측(단일 ch1 장비): w3@0x60 → NAK / w3@0x40 → ACK
#
# 그래서 듀얼/단일을 먼저 가려야 주소가 정해진다. 판정은 cam_channel_resolve.sh
# 에 맡긴다 — edgeconf 를 먼저 보고 없으면 i2cdetect 로 폴백하며, cam_* 계열
# 스크립트 7개가 이미 같은 근거를 쓴다. 여기서 다시 구현하면 갈라진다.
#
# 시리얼라이저 주소가 필요한 것은 MFP4 게이트(on/off)뿐이다.

[ -f "$CHANNEL_HELPER" ] || die "missing helper: $CHANNEL_HELPER"
# shellcheck source=/dev/null
source "$CHANNEL_HELPER"

# 요청 채널이 실제로 쓰이는 채널인지 확인한다.
#
# 헬퍼의 MODE 는 'single' 이라는 사실만 알려주고 어느 쪽이 활성인지는 알려주지
# 않는다. 단일 구성에는 시리얼라이저가 0x40 하나뿐이라 어느 채널을 지정해도 그놈이
# 응답하므로, 이 확인이 없으면 ch0 단독 장비에서 `1 on` 이 ch0 카메라를 건드린다.
#
# 파일은 헬퍼가 찾아 둔 EDGECONF_FILE 을 그대로 쓴다. // false 는 여기서 안전하다
# — 키가 없으면 '쓰지 않는 채널'이고, 사용하는 채널만 true 로 두는 것이 원칙이다.
ch_enabled() {
    local bus_key val
    command -v jq >/dev/null 2>&1 || return 1
    [ -n "$EDGECONF_FILE" ] && [ -r "$EDGECONF_FILE" ] || return 1
    bus_key=$(channel_bus_key "$1") || return 1
    val=$(jq -r --arg b "$bus_key" --arg c "ch$1" \
          '(.VHL_CAM[$b][$c].enable // false)' "$EDGECONF_FILE" 2>/dev/null) || return 1
    [ "$val" = "true" ]
}

resolve_ser_addr() {
    resolve_channel_context "$CHANNEL"   # MODE / BUS / RESOLVE_SOURCE / EDGECONF_FILE

    if [ "$MODE" = "dual" ]; then
        case "$CHANNEL" in
            0|2) SER_ADDR=0x40 ;;
            1|3) SER_ADDR=0x60 ;;
        esac
        return 0
    fi

    SER_ADDR=0x40
    # 단일 구성에서만 채널 확인이 의미가 있다. 듀얼은 주소로 이미 갈린다.
    # edgeconf 로 판정된 경우에만 확인한다 — i2cdetect 폴백은 어느 채널이
    # 활성인지 알려주지 못하므로 없는 근거로 막지 않는다.
    if [ "$RESOLVE_SOURCE" = "edgeconf" ] && ! ch_enabled "$CHANNEL"; then
        die "ch${CHANNEL} is not enabled in edgeconf - not a channel in use." \
            "단일 구성에서 다른 채널을 지정하면 엉뚱한 카메라를 건드리므로 막는다."
    fi
    if [ "$RESOLVE_SOURCE" != "edgeconf" ]; then
        echo "[$tag] Note: 단일 구성 판정이 ${RESOLVE_SOURCE} 기준이라 요청 채널이" \
             "그 하나인지는 확인할 수 없다." >&2
    fi
    return 0
}

case "$COMMAND" in
    on)
        resolve_ser_addr
        echo "Channel $CHANNEL ON: i2ctransfer -f -y -a $I2C_BUS w3@$SER_ADDR 0x02 0xca 0x90"
        i2ctransfer -f -y -a "$I2C_BUS" w3@"$SER_ADDR" 0x02 0xca 0x90
        ;;
    off)
        resolve_ser_addr
        echo "Channel $CHANNEL OFF: i2ctransfer -f -y -a $I2C_BUS w3@$SER_ADDR 0x02 0xca 0x80"
        i2ctransfer -f -y -a "$I2C_BUS" w3@"$SER_ADDR" 0x02 0xca 0x80
        ;;
    set)
        if [ -z "$3" ]; then
            echo "Error: 'set' command requires a value argument." >&2
            usage
        fi
        VALUE=$3
        echo "Channel $CHANNEL SET: i2cset -y $I2C_BUS $MCP4018_ADDR $VALUE"
        i2cset -y "$I2C_BUS" "$MCP4018_ADDR" "$VALUE"
        ;;
    get)
        echo "Channel $CHANNEL GET: i2cget -y $I2C_BUS $MCP4018_ADDR"
        i2cget -y "$I2C_BUS" "$MCP4018_ADDR"
        ;;
    *)
        echo "Error: Invalid command '$COMMAND'. Must be on, off, set, or get." >&2
        exit 1
        ;;
esac
