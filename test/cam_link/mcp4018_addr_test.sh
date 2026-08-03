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
# 설정이 '안 쓰는 채널'이라고 하면 하드웨어 스캔 결과보다 그쪽이 우선한다.
# 선언된 의도를 스캔으로 뒤집으면 안 된다.
write_conf false false false false
run "전부 disable + 스캔 무응답 → 거절" ""        0 on none 1
run "전부 disable + 스캔 dual 이어도 거절" "11 12" 1 on none 1
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
echo "=== set/get 도 비활성 채널이면 막는다 (on/off 와 같은 정책) ==="
# 단일 구성에는 MCP4018 도 하나뿐이라 `1 set` 이 ch0 의 값을 바꾼다.
write_conf true false false false
run "단일 ch0 · ch1 set → 거절" "" 1 set none 1
run "단일 ch0 · ch1 get → 거절" "" 1 get none 1

echo
echo "=== set/get 은 게이트를 스스로 열고 닫는다 (원자적) ==="
# MCP4018 의 I2C 전원은 ser 의 MFP4(0x02ca)로 게이트되고 기본이 격리다. 두 채널의
# pot 이 0x2F 를 공유하므로, 열기·쓰기·닫기를 한 명령 안에서 끝내지 않으면
# `0 on` 뒤 `1 set` 같은 조합에서 엉뚱한 pot 을 건드린다.
gate_seq() {   # CALLS 에서 MFP4 쓰기만 순서대로 뽑는다
    grep -oE 'w3@0x[0-9a-fA-F]+ 0x02 0xca 0x[0-9a-fA-F]+' "$CALLS"         | sed 's/w3@//; s/ 0x02 0xca / /' | tr '\n' ',' | sed 's/,$//'
}
seq_for() {    # $1=DETECT $2=채널 $3=명령 $4=값
    : > "$CALLS"
    PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="$1" EDGECONF_DIR="$CONF" \
        bash "$SCRIPT" "$2" "$3" ${4:+"$4"} >/dev/null 2>&1
    gate_seq
}

write_conf true true false false
t_eq "듀얼 · ch1 set → 0x60 열고 닫기" "$(seq_for '' 1 set 0x10)" "0x60 0x90,0x60 0x80"
t_eq "듀얼 · ch0 set → 0x40 열고 닫기" "$(seq_for '' 0 set 0x10)" "0x40 0x90,0x40 0x80"
t_eq "듀얼 · ch1 get → 0x60 열고 닫기" "$(seq_for '' 1 get)"      "0x60 0x90,0x60 0x80"
write_conf true false false false
t_eq "단일 ch0 · set → 0x40 열고 닫기" "$(seq_for '' 0 set 0x10)" "0x40 0x90,0x40 0x80"

# 게이트를 연 뒤에 실제 전송이 일어나야 한다 (순서 확인)
: > "$CALLS"
write_conf true true false false
PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="" EDGECONF_DIR="$CONF" \
    bash "$SCRIPT" 1 set 0x10 >/dev/null 2>&1
t_eq "열기 → i2cset → 닫기 순서" \
     "$(grep -nE '0xca 0x90|i2cset|0xca 0x80' "$CALLS" | cut -d: -f1 | tr '\n' ' ')" "1 2 3 "

echo
echo "=== 게이트 주소를 모르면 set/get 도 진행할 수 없다 ==="
# 이전에는 0x2f 로 바로 갔으나, 이제 어느 ser 의 게이트를 열지 알아야 한다.
clear_conf
run "설정 없음 + 스캔 무응답 · set → 중단" "" 1 set none 1
# run() 은 값 인자를 넘기지 않으므로 set 은 직접 부른다.
t_eq "설정 없음 + 스캔 dual · set → 0x60 게이트" "$(seq_for '11 12' 1 set 0x10)" \
     "0x60 0x90,0x60 0x80"

t_summary "mcp4018 주소 해석"
