#!/bin/bash
# mcp4018_ctrl.sh 의 시리얼라이저 주소 해석 검증
# 사용법: bash test/cam_link/mcp4018_addr_test.sh
#
# 0x60 은 듀얼 초기화의 리맵으로만 생기는 주소라 단일 구성에는 없다. 그래서
# 듀얼/단일을 먼저 가려야 주소가 정해진다. 근거는 edgeconf 의 chx.enable 이다
# (사용하는 채널만 true 로 두는 것이 운용 원칙).
#
# 응답 탐색만으로는 안 되는 이유를 못박는다: 단일 구성에서는 요청 채널이 무엇이든
# 0x40 이 응답하므로, ch0 단독 장비에서 `1 on` 이 ch0 카메라를 건드리게 된다.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
STUB="$WORK/stub"
CONF="$WORK/conf"
CALLS="$WORK/calls"
SCRIPT="$PIM_BIN/mcp4018_ctrl.sh"
mkdir -p "$STUB" "$CONF"
trap 'rm -rf "$WORK"' EXIT

command -v jq >/dev/null 2>&1 || { echo "jq 없음 — 건너뜀" >&2; exit 0; }

# i2ctransfer 스텁: RESPOND 목록의 주소만 ACK. 쓰기는 CALLS 에 기록.
cat > "$STUB/i2ctransfer" <<'EOF'
#!/bin/bash
args="$*"
addr=$(printf '%s' "$args" | grep -oE 'w[23]@0x[0-9a-fA-F]+' | head -1 | sed 's/.*@//')
case " $RESPOND " in *" $addr "*) ;; *) echo "Error: Sending failed" >&2; exit 1 ;; esac
printf '%s\n' "$args" >> "$CALLS"
echo "0x00"
EOF
printf '#!/bin/bash\nprintf "i2cset %%s\\n" "$*" >> "$CALLS"\n' > "$STUB/i2cset"
printf '#!/bin/bash\nprintf "i2cget %%s\\n" "$*" >> "$CALLS"\n' > "$STUB/i2cget"
chmod +x "$STUB"/*

# $1..$4 = ch0,ch1,ch2,ch3 의 enable (true/false)
write_conf() {
    cat > "$CONF/edgeconf_test.json" <<EOF
{ "VHL_CAM": {
    "i2c2": { "ch0": {"enable": $1}, "ch1": {"enable": $2} },
    "i2c1": { "ch2": {"enable": $3}, "ch3": {"enable": $4} } } }
EOF
}

# $1=설명 $2=RESPOND $3=채널 $4=명령 $5=기대 쓰기주소(none=쓰기없음) $6=기대 exit
run() {
    : > "$CALLS"
    local out rc w
    out=$(PATH="$STUB:$PATH" CALLS="$CALLS" RESPOND="$2" EDGECONF_DIR="$CONF" \
          bash "$SCRIPT" "$3" "$4" 2>&1); rc=$?
    w=$(grep -oE 'w3@0x[0-9a-fA-F]+' "$CALLS" 2>/dev/null | head -1 | sed 's/.*@//')
    t_eq "$1" "write=${w:-none} exit=$rc" "write=$5 exit=$6"
}

echo "=== 듀얼 구성 (ch0/ch1 둘 다 enable) ==="
write_conf true true false false
run "ch0 on → 0x40"  "0x40 0x60" 0 on 0x40 0
run "ch1 on → 0x60"  "0x40 0x60" 1 on 0x60 0
run "ch0 off → 0x40" "0x40 0x60" 0 off 0x40 0

echo
echo "=== 단일 구성 ch0 (ch1 disable) ==="
write_conf true false false false
run "ch0 on → 0x40"                    "0x40" 0 on 0x40 0
run "ch1 on → 거절 (엉뚱한 카메라 방지)" "0x40" 1 on none 1

echo
echo "=== 단일 구성 ch1 (ch0 disable) ==="
write_conf false true false false
run "ch1 on → 0x40"    "0x40" 1 on 0x40 0
run "ch0 on → 거절"    "0x40" 0 on none 1

echo
echo "=== bus 1 (ch2/ch3) 도 같은 규칙 ==="
write_conf false false true true
run "듀얼 · ch3 on → 0x60" "0x40 0x60" 3 on 0x60 0
write_conf false false true false
run "단일 ch2 · ch2 on → 0x40" "0x40" 2 on 0x40 0
run "단일 ch2 · ch3 on → 거절" "0x40" 3 on none 1

echo
echo "=== 설정과 하드웨어가 어긋나면 ==="
write_conf true true false false
run "듀얼인데 0x60 무응답 → 에러" "0x40" 1 on none 1
write_conf false false false false
run "해당 채널 disable → 거절"    "0x40 0x60" 0 on none 1

echo
echo "=== edgeconf 를 못 읽으면 응답 탐색으로 폴백 ==="
rm -f "$CONF"/edgeconf_*.json
run "설정 없음 · 듀얼 응답 → 0x60" "0x40 0x60" 1 on 0x60 0
run "설정 없음 · 0x40 만 응답 → 0x40" "0x40" 1 on 0x40 0
run "설정 없음 · 무응답 → 에러"      ""      1 on none 1

echo
echo "=== set/get 은 주소 해석과 무관 (설정 없어도 동작) ==="
: > "$CALLS"
PATH="$STUB:$PATH" CALLS="$CALLS" RESPOND="" EDGECONF_DIR="$CONF" \
    bash "$SCRIPT" 1 set 0x10 >/dev/null 2>&1
t_eq "set → 0x2f 직접" "$(grep -c 'i2cset .*0x2f 0x10' "$CALLS")" 1
: > "$CALLS"
PATH="$STUB:$PATH" CALLS="$CALLS" RESPOND="" EDGECONF_DIR="$CONF" \
    bash "$SCRIPT" 1 get >/dev/null 2>&1
t_eq "get → 0x2f 직접" "$(grep -c 'i2cget .*0x2f' "$CALLS")" 1

t_summary "mcp4018 주소 해석"
