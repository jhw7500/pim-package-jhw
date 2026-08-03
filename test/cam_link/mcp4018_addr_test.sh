#!/bin/bash
# mcp4018_ctrl.sh 의 시리얼라이저 주소 해석 검증
# 사용법: bash test/cam_link/mcp4018_addr_test.sh
#
# 0x60 은 듀얼 초기화의 리맵으로만 생기는 주소라 단일 구성에는 없다. 그래서
# 듀얼/단일을 먼저 가려야 주소가 정해진다. 판정은 cam_channel_resolve.sh 가
# 하고(edgeconf → i2cdetect 폴백), 이 스크립트는 그 결과를 주소로 옮긴다.
#
# 단일 구성에서는 시리얼라이저가 0x40 하나뿐이라 어느 채널을 지정해도 응답한다.
# 그래서 요청 채널이 실제 쓰이는 채널인지 확인하지 않으면 ch0 단독 장비에서
# `1 on` 이 ch0 카메라를 건드린다. 그 거절을 못박는 것이 이 테스트의 핵심이다.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
STUB="$WORK/stub"
CONF="$WORK/conf"
CALLS="$WORK/calls"
SCRIPT="$PIM_BIN/mcp4018_ctrl.sh"
mkdir -p "$STUB" "$CONF"
trap 'rm -rf "$WORK"' EXIT

command -v jq >/dev/null 2>&1 || { echo "jq 없음 — 건너뜀" >&2; exit 0; }

# i2ctransfer: 쓰기를 기록만 한다(주소 해석 결과 확인용).
cat > "$STUB/i2ctransfer" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
echo "0x00"
EOF
# i2cdetect: DETECT 에 넣은 주소들이 스캔에 보이는 것처럼 흉내낸다.
cat > "$STUB/i2cdetect" <<'EOF'
#!/bin/bash
[ -n "$DETECT" ] || exit 1
echo "     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f"
echo "00: $DETECT"
EOF
printf '#!/bin/bash\nprintf "i2cset %%s\\n" "$*" >> "$CALLS"\n' > "$STUB/i2cset"
printf '#!/bin/bash\nprintf "i2cget %%s\\n" "$*" >> "$CALLS"\n' > "$STUB/i2cget"
chmod +x "$STUB"/*

# $1..$4 = ch0,ch1,ch2,ch3 의 enable
write_conf() {
    cat > "$CONF/edgeconf_pim.json" <<EOF
{ "VHL_CAM": {
    "i2c2": { "ch0": {"enable": $1}, "ch1": {"enable": $2} },
    "i2c1": { "ch2": {"enable": $3}, "ch3": {"enable": $4} } } }
EOF
}
clear_conf() { rm -f "$CONF"/edgeconf_*.json; }

# $1=설명 $2=DETECT(i2cdetect 흉내) $3=채널 $4=명령 $5=기대 쓰기주소(none) $6=기대 exit
run() {
    : > "$CALLS"
    local out rc w
    out=$(PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="$2" EDGECONF_DIR="$CONF" \
          bash "$SCRIPT" "$3" "$4" 2>&1); rc=$?
    w=$(grep -oE 'w3@0x[0-9a-fA-F]+' "$CALLS" 2>/dev/null | head -1 | sed 's/.*@//')
    t_eq "$1" "write=${w:-none} exit=$rc" "write=$5 exit=$6"
}

echo "=== edgeconf 로 판정 · 듀얼 ==="
write_conf true true false false
run "ch0 on → 0x40"  "" 0 on  0x40 0
run "ch1 on → 0x60"  "" 1 on  0x60 0
run "ch0 off → 0x40" "" 0 off 0x40 0

echo
echo "=== edgeconf 로 판정 · 단일 (핵심: 다른 채널 거절) ==="
write_conf true false false false
run "단일 ch0 · ch0 on → 0x40" "" 0 on 0x40 0
run "단일 ch0 · ch1 on → 거절" "" 1 on none 1
write_conf false true false false
run "단일 ch1 · ch1 on → 0x40" "" 1 on 0x40 0
run "단일 ch1 · ch0 on → 거절" "" 0 on none 1

echo
echo "=== bus 1 (ch2/ch3) 도 같은 규칙 ==="
write_conf false false true true
run "듀얼 · ch3 on → 0x60" "" 3 on 0x60 0
write_conf false false true false
run "단일 ch2 · ch2 on → 0x40" "" 2 on 0x40 0
run "단일 ch2 · ch3 on → 거절" "" 3 on none 1

echo
echo "=== 설정으로 판정 못 하면 i2cdetect 로 폴백 ==="
# 전 채널 disable 은 헬퍼가 판정 실패로 보고 i2cdetect 를 본다
write_conf false false false false
run "전부 disable + 스캔 무응답 → 중단" ""        0 on none 1
run "전부 disable + 스캔 dual → 0x60"   "11 12"   1 on 0x60 0
clear_conf
run "설정 없음 + 스캔 dual → 0x60"      "11 12"   1 on 0x60 0
run "설정 없음 + 스캔 single → 0x40"    "3c"      1 on 0x40 0
run "설정 없음 + 스캔 무응답 → 중단"    ""        1 on none 1

echo
echo "=== 폴백 판정에서는 채널 확인을 하지 않는다 (근거가 없으므로) ==="
clear_conf
out=$(PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="3c" EDGECONF_DIR="$CONF" \
      bash "$SCRIPT" 1 on 2>&1)
# 패턴에 .* 와 공백 섞인 한글을 함께 쓰면 UTF-8 로케일에서 매칭이 어긋난다.
t_eq "단일 폴백 시 Note 로 한계를 알린다" \
     "$(printf '%s' "$out" | grep -c '확인할 수 없다')" 1

echo
echo "=== set/get 은 모드 판정과 무관 ==="
clear_conf
: > "$CALLS"
PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="" EDGECONF_DIR="$CONF" \
    bash "$SCRIPT" 1 set 0x10 >/dev/null 2>&1
t_eq "set → 0x2f 직접 (판정 실패해도 동작)" "$(grep -c 'i2cset .*0x2f 0x10' "$CALLS")" 1
: > "$CALLS"
PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="" EDGECONF_DIR="$CONF" \
    bash "$SCRIPT" 3 get >/dev/null 2>&1
t_eq "get → bus1 의 0x2f"                   "$(grep -c 'i2cget -y 1 0x2f' "$CALLS")" 1

t_summary "mcp4018 주소 해석"
