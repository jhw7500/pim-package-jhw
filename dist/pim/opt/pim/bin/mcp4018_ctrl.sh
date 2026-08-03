#!/bin/bash

SCRIPT_NAME=$(basename "$0")

usage() {
    echo "Usage: $SCRIPT_NAME <channel> <command> [value]"
    echo "  channel: 0, 1, 2, 3"
    echo "  command: on, off, set, get"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME 0 on        # Enable channel 0"
    echo "  $SCRIPT_NAME 0 off       # Disable channel 0"
    echo "  $SCRIPT_NAME 0 set 0x10  # Set MCP4018 wiper value"
    echo "  $SCRIPT_NAME 0 get       # Get MCP4018 wiper value"
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

CHANNEL=$1
COMMAND=$2

# 채널 → I2C 버스, 같은 버스의 짝 채널, 듀얼 구성에서의 시리얼라이저 주소.
case "$CHANNEL" in
    0) I2C_BUS=2; PEER_CH=1; SER_IF_DUAL=0x40 ;;
    1) I2C_BUS=2; PEER_CH=0; SER_IF_DUAL=0x60 ;;
    2) I2C_BUS=1; PEER_CH=3; SER_IF_DUAL=0x40 ;;
    3) I2C_BUS=1; PEER_CH=2; SER_IF_DUAL=0x60 ;;
    *)
        echo "Error: Invalid channel '$CHANNEL'. Must be 0, 1, 2, or 3." >&2
        exit 1
        ;;
esac

MCP4018_ADDR=0x2f
SER_DEFAULT=0x40    # MAX9295 파워온 기본 I2C 주소
EDGECONF_DIR="${EDGECONF_DIR:-/root/shared_v}"

# ── 시리얼라이저 주소 해석 ─────────────────────────────────────────────
# 0x60 은 홀수 채널의 하드웨어 속성이 아니다. 듀얼 구성 초기화에서만 한쪽
# 시리얼라이저를 0x40 → 0x60 으로 옮기기 때문에 생기는 주소다 — max9296.c 의
# 2ch 테이블에 있는 {0x40, 0x0000, 2, 0xC0} 이 드라이버 전체에서 유일한
# 시리얼라이저 자기주소 쓰기다. 단일채널 테이블(_720p_30fps_L/_R)에는 그 리맵이
# 없고 시리얼라이저를 0x40 으로만 접근한다.
#
# 실측(단일 ch1 장비):
#   i2ctransfer -f -y -a 2 w3@0x60 0x02 0xca 0x90   → NAK
#   i2ctransfer -f -y -a 2 w3@0x40 0x02 0xca 0x90   → ACK
#
# 따라서 듀얼/단일을 먼저 가려야 주소가 정해진다. 판단 근거는 edgeconf 의
# chx.enable 이다 — 사용하는 채널만 true 로 두는 것이 운용 원칙이고,
# BG_Check_for_pim.sh 등 나머지 스크립트도 같은 근거를 쓴다.
#
# 응답 여부만으로는 판별할 수 없다. 단일 구성에서는 요청한 채널이 무엇이든
# 0x40 이 응답하므로, ch0 단독 장비에서 `1 on` 을 해도 ch0 카메라를 건드리게
# 된다. 설정을 봐야 그런 요청을 거절할 수 있다.
#
# 시리얼라이저 주소가 필요한 것은 MFP4 게이트(on/off)뿐이다. wiper(set/get)는
# MCP4018 로 직접 가므로 이 해석과 무관하다.

ser_responds() {   # $1=bus  $2=addr — MAX9295 DEV_ADDR(0x0000) 1바이트 읽기
    i2ctransfer -f -y -a "$1" w2@"$2" 0x00 0x00 r1 >/dev/null 2>&1
}

# edgeconf 에서 채널 enable 을 읽는다. 파일 선택은 BG_Check_for_pim.sh 와 동일
# (가장 최근 edgeconf_*.json). 출력: 1(enable) / 0(disable). 못 읽으면 return 1.
read_ch_enable() {
    local ch="$1" cfg key val
    command -v jq >/dev/null 2>&1 || return 1
    cfg=$(ls -ptr "${EDGECONF_DIR}"/edgeconf_*.json 2>/dev/null \
          | grep -v '/$' | tail -1 | tr -d '\r\n')
    [ -n "$cfg" ] && [ -r "$cfg" ] || return 1
    case "$ch" in
        0|1) key=".VHL_CAM.i2c2.ch${ch}.enable" ;;
        2|3) key=".VHL_CAM.i2c1.ch${ch}.enable" ;;
        *)   return 1 ;;
    esac
    # jq 의 // 는 false 도 '비어있음'으로 쳐서 기본값으로 바꿔 버린다. enable=false
    # 가 그대로 사라지므로 여기서는 쓰지 않는다. 키가 없으면 null 이 나온다.
    val=$(jq -r "${key}" "$cfg" 2>/dev/null) || return 1
    case "$val" in
        true)  echo 1 ;;
        false) echo 0 ;;
        *)     return 1 ;;    # null 등 — 설정을 신뢰하지 않는다
    esac
}

# 설정을 읽을 수 없을 때의 폴백. 주소를 확정할 수 없으므로 추정임을 밝힌다.
resolve_by_probe() {
    if ser_responds "$I2C_BUS" "$SER_IF_DUAL"; then
        SER_ADDR=$SER_IF_DUAL
        return 0
    fi
    if [ "$SER_IF_DUAL" != "$SER_DEFAULT" ] && ser_responds "$I2C_BUS" "$SER_DEFAULT"; then
        SER_ADDR=$SER_DEFAULT
        echo "Note: $SER_IF_DUAL 무응답 → 단일 구성으로 추정하고 $SER_DEFAULT 를 쓴다." >&2
        echo "      단일 구성에는 시리얼라이저가 하나뿐이라 이 주소가 ch${CHANNEL} 의" >&2
        echo "      것인지는 확인할 수 없다. edgeconf 를 읽을 수 있으면 확정된다." >&2
        return 0
    fi
    echo "Error: bus $I2C_BUS 에서 시리얼라이저를 찾지 못했다 ($SER_IF_DUAL, $SER_DEFAULT 모두 무응답)." >&2
    echo "       카메라 연결과 드라이버 로드 상태를 확인하라." >&2
    return 1
}

resolve_ser_addr() {
    local me peer

    me=$(read_ch_enable "$CHANNEL") || {
        echo "Note: edgeconf 를 읽지 못해 응답 탐색으로 대체한다 (${EDGECONF_DIR})." >&2
        resolve_by_probe
        return
    }
    peer=$(read_ch_enable "$PEER_CH") || {
        echo "Note: edgeconf 를 읽지 못해 응답 탐색으로 대체한다 (${EDGECONF_DIR})." >&2
        resolve_by_probe
        return
    }

    if [ "$me" != "1" ]; then
        echo "Error: ch${CHANNEL} 은 edgeconf 에서 enable 이 아니다 — 사용 중인 채널이 아니다." >&2
        echo "       단일 구성에서 다른 채널을 지정하면 엉뚱한 카메라를 건드리므로 막는다." >&2
        return 1
    fi

    if [ "$peer" = "1" ]; then
        SER_ADDR=$SER_IF_DUAL        # 듀얼 — 한쪽이 0x60 으로 리맵돼 있다
    else
        SER_ADDR=$SER_DEFAULT        # 단일 — 리맵이 없어 0x40 하나뿐이다
    fi

    if ! ser_responds "$I2C_BUS" "$SER_ADDR"; then
        echo "Error: 설정상 ch${CHANNEL} 의 시리얼라이저는 $SER_ADDR 인데 응답이 없다." >&2
        echo "       카메라 연결과 드라이버 로드 상태를 확인하라." >&2
        return 1
    fi
    return 0
}

case "$COMMAND" in
    on)
        resolve_ser_addr || exit 1
        echo "Channel $CHANNEL ON: i2ctransfer -f -y -a $I2C_BUS w3@$SER_ADDR 0x02 0xca 0x90"
        i2ctransfer -f -y -a "$I2C_BUS" w3@"$SER_ADDR" 0x02 0xca 0x90
        ;;
    off)
        resolve_ser_addr || exit 1
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
