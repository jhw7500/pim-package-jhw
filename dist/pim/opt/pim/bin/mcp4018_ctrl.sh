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

# 채널 → I2C 버스, 그리고 '듀얼 구성에서의' MAX9295 시리얼라이저 주소.
case "$CHANNEL" in
    0) I2C_BUS=2; SER_DUAL=0x40 ;;
    1) I2C_BUS=2; SER_DUAL=0x60 ;;
    2) I2C_BUS=1; SER_DUAL=0x40 ;;
    3) I2C_BUS=1; SER_DUAL=0x60 ;;
    *)
        echo "Error: Invalid channel '$CHANNEL'. Must be 0, 1, 2, or 3."
        exit 1
        ;;
esac

MCP4018_ADDR=0x2f
SER_DEFAULT=0x40    # MAX9295 파워온 기본 I2C 주소

# ── 시리얼라이저 주소 해석 ─────────────────────────────────────────────
# 0x60 은 홀수 채널의 하드웨어 속성이 아니다. 듀얼 구성 초기화에서만 한쪽
# 시리얼라이저를 0x40 → 0x60 으로 옮기기 때문에 생기는 주소다 — max9296.c 의
# 2ch 테이블에 있는 {0x40, 0x0000, 2, 0xC0} 이 드라이버 전체에서 유일한
# 시리얼라이저 자기주소 쓰기다. 단일채널 테이블(_720p_30fps_L/_R)에는 그 리맵이
# 없고 시리얼라이저를 0x40 으로만 접근한다. 즉 단일채널 장비에서는 ch0/ch1 어느
# 쪽이든 시리얼라이저가 0x40 에 응답한다.
#
# 실측(단일 ch1 장비):
#   i2ctransfer -f -y -a 2 w3@0x60 0x02 0xca 0x90   → NAK
#   i2ctransfer -f -y -a 2 w3@0x40 0x02 0xca 0x90   → ACK
#
# 구성을 알려주는 믿을 만한 입력이 없다 — 드라이버의 enable sysfs 는 probe 에서
# 초기화되지 않아 기본값이 0 이고 이 패키지 어디서도 쓰지 않는다. 그래서 주소를
# 가정하지 않고 실제 응답으로 정한다.
#
# 시리얼라이저 주소가 필요한 것은 MFP4 게이트(on/off)뿐이다. wiper(set/get)는
# MCP4018 로 직접 가므로 이 해석과 무관하다.
ser_responds() {   # $1=bus  $2=addr — MAX9295 DEV_ADDR(0x0000) 1바이트 읽기
    i2ctransfer -f -y -a "$1" w2@"$2" 0x00 0x00 r1 >/dev/null 2>&1
}

resolve_ser_addr() {
    if ser_responds "$I2C_BUS" "$SER_DUAL"; then
        SER_ADDR=$SER_DUAL
        return 0
    fi
    if [ "$SER_DUAL" != "$SER_DEFAULT" ] && ser_responds "$I2C_BUS" "$SER_DEFAULT"; then
        SER_ADDR=$SER_DEFAULT
        echo "Note: bus $I2C_BUS 에 $SER_DUAL 무응답 → 단일채널 구성. 이 구성에는"
        echo "      시리얼라이저가 $SER_DEFAULT 하나뿐이라 채널 인자로 카메라를 고를 수 없다."
        return 0
    fi
    echo "Error: bus $I2C_BUS 에서 시리얼라이저를 찾지 못했다 ($SER_DUAL, $SER_DEFAULT 모두 무응답)."
    echo "       카메라 연결과 드라이버 로드 상태를 확인하라."
    return 1
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
            echo "Error: 'set' command requires a value argument."
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
        echo "Error: Invalid command '$COMMAND'. Must be on, off, set, or get."
        exit 1
        ;;
esac
