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

# 채널 번호 → 버스 번호 매핑은 모드와 무관하다. 그래서 듀얼/단일 판정보다 먼저,
# 여기서 정한다. (모드 판정은 어느 시리얼라이저의 게이트를 열지 정할 때 필요하다.)
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
            0|2) SER_ADDR=0x40; PEER_SER_ADDR=0x60 ;;
            1|3) SER_ADDR=0x60; PEER_SER_ADDR=0x40 ;;
        esac
        return 0
    fi

    SER_ADDR=0x40
    PEER_SER_ADDR=""        # 단일에는 시리얼라이저가 하나뿐이라 상대가 없다
    if [ "$RESOLVE_SOURCE" != "edgeconf" ]; then
        echo "[$tag] Note: 단일 구성 판정이 ${RESOLVE_SOURCE} 기준이라 요청 채널이" \
             "그 하나인지는 확인할 수 없다." >&2
    fi
    return 0
}

# MCP4018 의 I2C 전원은 ser 의 MFP4(0x02ca)로 게이트된다. 기본이 LOW(격리)이고
# 통신할 때만 올린다. wiper 값은 게이트가 닫혀도 pot 이 유지한다.
#
# 두 채널의 pot 이 host 주소 0x2F 를 공유한다(리맵 없음). 그래서 한 번에 한쪽
# 게이트만 열어야 한다 — 둘 다 열어 두면 같은 주소로 양쪽에 동시에 쓰게 된다.
# 드라이버도 같은 이유로 열기→쓰기→닫기를 원자적으로 한다(max9296.c).
#
# $1=ser 주소  $2=on|off
mfp4_gate() {
    local v
    case "$2" in
        on)  v=0x90 ;;
        off) v=0x80 ;;
        *)   return 1 ;;
    esac
    # stdout 만 버린다. I2C 오류(NAK/timeout/버스 점유)는 실패 원인을 가리는
    # 유일한 단서라 stderr 까지 삼키면 현장에서 진단이 안 된다.
    i2ctransfer -f -y -a "$I2C_BUS" w3@"$1" 0x02 0xca "$v" >/dev/null
}

# 게이트 상태는 프로세스 밖(ser 의 MFP4 핀)에 있다. 그래서 같은 버스에 두 프로세스가
# 동시에 들어오면, 한쪽이 연 게이트를 다른 쪽이 상대 게이트라며 닫고 자기 것을 열어
# 먼저 들어온 쪽의 0x2F 쓰기가 엉뚱한 pot 에 도달한다. 버스 단위로 직렬화한다.
#
# flock 이 없는 환경에서는 막지 않는다 — 배타성은 잃지만, 진단 도구가 아예 못 도는
# 것보다는 낫다.
acquire_bus_lock() {
    local lock="${MCP4018_LOCK_DIR:-/tmp}/mcp4018_i2c${I2C_BUS}.lock"
    command -v flock >/dev/null 2>&1 || return 0
    # 리다이렉트는 그룹에만 걸어야 한다. `exec 9>f 2>/dev/null` 처럼 붙여 쓰면
    # 명령 없는 exec 이라 2>/dev/null 까지 셸에 영구 적용되어 이후 모든 진단이
    # 사라진다.
    #
    # 락 파일을 못 열면(다른 사용자가 만들어 둬 권한이 없는 경우 등) 배타성을
    # 포기하고 진행하되, 조용히 넘기지는 않는다 — 이 상태에서는 동시 실행이
    # 양쪽 pot 을 건드릴 수 있다는 사실이 드러나야 한다.
    if ! { exec 9>"$lock"; } 2>/dev/null; then
        echo "[$tag] WARNING: cannot open lock $lock - proceeding without bus exclusion" >&2
        return 0
    fi
    local wait="${MCP4018_LOCK_WAIT:-5}"   # 재정의는 테스트가 빨리 끝나게 하기 위함
    flock -w "$wait" 9 || die "another $tag holds i2c-$I2C_BUS (waited ${wait}s)"
}

# 내 게이트만 여는 것으로는 부족하다. 진단용 `on` 은 게이트를 열어 둔 채 끝나므로
# `0 on` 뒤에 `1 set` 을 부르면 0x40·0x60 이 동시에 열려 0x2F 쓰기가 양쪽 pot 에
# 도달한다. 그래서 열기 전에 상대 게이트를 먼저 내린다.
#
# 상대를 못 내리면 진행하지 않는다. 상대 ser 이 응답하지 않는 경우(링크 다운)에도
# 그 MFP4 는 직전 상태를 유지하므로, '응답이 없다'는 '닫혀 있다'가 아니다.
gate_open_exclusive() {
    if [ -n "$PEER_SER_ADDR" ]; then
        mfp4_gate "$PEER_SER_ADDR" off \
            || die "failed to close peer MCP4018 gate (ser $PEER_SER_ADDR) - refusing to write shared $MCP4018_ADDR"
    fi
    mfp4_gate "$SER_ADDR" on || die "failed to open MCP4018 gate (ser $SER_ADDR)"
}

# 닫기 실패를 조용히 넘기면 게이트가 열린 채 남아 다음 명령이 양쪽 pot 을 건드린다.
gate_close() {
    mfp4_gate "$SER_ADDR" off && return 0
    echo "[$tag] WARNING: failed to close MCP4018 gate (ser $SER_ADDR) - it may stay open" >&2
    return 1
}

# 명령 종류와 무관하게 먼저 막는다. set/get 도 같은 하드웨어를 건드린다.
reject_if_disabled

case "$COMMAND" in
    # on/off 는 게이트를 열어 둔 채 끝내는 진단용 명령이다. 락도 잡지 않으므로
    # 동시에 도는 set/get 과 경쟁할 수 있다. 값을 읽고 쓰는 것이 목적이면
    # set/get 을 쓴다 — 그쪽이 열기·쓰기·닫기를 배타적으로 끝낸다.
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
        # 게이트 열기·닫기를 이 명령 안에서 끝낸다. on/set/off 를 사람이 순서대로
        # 부르게 두면 `0 on` 뒤 `1 set` 같은 어긋난 조합에서 엉뚱한 pot 을 건드린다
        # (두 pot 이 0x2F 를 공유하므로 열려 있는 쪽이 맞는다).
        resolve_ser_addr
        acquire_bus_lock            # 락을 못 잡으면 버스를 아예 건드리지 않는다
        trap 'gate_close' EXIT      # die·시그널로 빠져나가는 경로의 안전망
        gate_open_exclusive
        echo "Channel $CHANNEL SET: i2cset -y $I2C_BUS $MCP4018_ADDR $VALUE (gate $SER_ADDR)"
        i2cset -y "$I2C_BUS" "$MCP4018_ADDR" "$VALUE"; rc=$?
        # 정상 경로에서는 직접 닫고 결과를 본다. 닫기 실패는 다음 명령의 배타성을
        # 깨뜨리므로 쓰기가 성공했어도 실패로 보고한다.
        trap - EXIT
        gate_close || rc=1
        exit "$rc"
        ;;
    get)
        resolve_ser_addr
        acquire_bus_lock            # 읽기도 게이트를 조작하므로 set 과 같은 락이 필요하다
        trap 'gate_close' EXIT
        gate_open_exclusive
        echo "Channel $CHANNEL GET: i2cget -y $I2C_BUS $MCP4018_ADDR (gate $SER_ADDR)"
        i2cget -y "$I2C_BUS" "$MCP4018_ADDR"; rc=$?
        trap - EXIT
        gate_close || rc=1
        exit "$rc"
        ;;
    *)
        echo "Error: Invalid command '$COMMAND'. Must be on, off, set, or get." >&2
        exit 1
        ;;
esac
