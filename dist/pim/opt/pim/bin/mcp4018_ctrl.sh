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

# 헬퍼가 구버전이면 함수가 없을 수 있다. 파일 존재만으로는 부족하다.
command -v resolve_channel_context >/dev/null 2>&1 \
    || die "helper is missing resolve_channel_context: $CHANNEL_HELPER"
command -v channel_bus_key >/dev/null 2>&1 \
    || die "helper is missing channel_bus_key: $CHANNEL_HELPER"

# 요청 채널이 edgeconf 상 '쓰지 않는 채널'이면 막는다.
#
# 단일 구성에는 시리얼라이저도 MCP4018 도 하나씩뿐이라, 어느 채널을 지정해도 그놈이
# 응답한다. 이 확인이 없으면 ch0 단독 장비에서 `1 on` 이나 `1 set` 이 ch0 카메라를
# 건드린다. on/off 만 막고 set/get 을 열어 두면 정책이 어긋난다.
#
# 모드 판정과 분리해 둔다. '판정에 실패했다'와 '이 채널은 안 쓴다가 확인됐다'는
# 다른 사실이다. 전자면 막지 않고(알 수 없으므로), 후자면 막는다. 그래서 여기서는
# resolve_channel_context 를 쓰지 않는다 — 그쪽은 판정 실패 시 die 한다.
#
# // false 는 여기서 안전하다: 키가 없으면 '쓰지 않는 채널'이고, 사용하는 채널만
# true 로 두는 것이 운용 원칙이다.
reject_if_disabled() {
    local cfg bus_key val
    command -v jq >/dev/null 2>&1 || return 0
    cfg=$(find_edgeconf_file 2>/dev/null) || return 0
    [ -n "$cfg" ] && [ -r "$cfg" ] || return 0
    bus_key=$(channel_bus_key "$CHANNEL") || return 0
    val=$(jq -r --arg b "$bus_key" --arg c "ch$CHANNEL" \
          '(.VHL_CAM[$b][$c].enable // false)' "$cfg" 2>/dev/null) || return 0
    [ "$val" = "true" ] && return 0
    die "ch${CHANNEL} is not enabled in edgeconf - not a channel in use."
}

resolve_ser_addr() {
    resolve_channel_context "$CHANNEL"   # MODE / BUS / RESOLVE_SOURCE

    if [ "$MODE" = "dual" ]; then
        case "$CHANNEL" in
            0|2) SER_ADDR=0x40 ;;
            1|3) SER_ADDR=0x60 ;;
        esac
        return 0
    fi

    SER_ADDR=0x40
    if [ "$RESOLVE_SOURCE" != "edgeconf" ]; then
        echo "[$tag] Note: 단일 구성 판정이 ${RESOLVE_SOURCE} 기준이라 요청 채널이" \
             "그 하나인지는 확인할 수 없다." >&2
    fi
    return 0
}

# 명령 종류와 무관하게 먼저 막는다. set/get 도 같은 하드웨어를 건드린다.
reject_if_disabled

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
