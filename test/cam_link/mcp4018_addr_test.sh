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
# $7=값(set 전용, 선택)
run() {
    : > "$CALLS"
    local out rc w
    out=$(PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="$2" EDGECONF_DIR="$CONF" \
          MCP4018_LOCK_DIR="${MCP4018_LOCK_DIR:-$WORK}" \
          bash "$SCRIPT" "$3" "$4" ${7:+"$7"} 2>&1); rc=$?
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
# 거절만 검증하면 정상 경로가 깨져도 통과한다. 게이트 순서 테스트들은 종료 코드를
# 버리므로 exit 0 을 못 박는 것은 이 케이스뿐이다.
run "단일 ch0 · ch0 get → 통과(exit 0)" "" 0 get 0x40 0
run "단일 ch0 · ch0 set → 통과(exit 0)" "" 0 set 0x40 0 0x10

echo
echo "=== set/get 은 게이트를 스스로 열고 닫는다 (원자적) ==="
# MCP4018 의 I2C 전원은 ser 의 MFP4(0x02ca)로 게이트되고 기본이 격리다. 두 채널의
# pot 이 0x2F 를 공유하므로, 열기·쓰기·닫기를 한 명령 안에서 끝내지 않으면
# `0 on` 뒤 `1 set` 같은 조합에서 엉뚱한 pot 을 건드린다.
gate_seq() {   # CALLS 에서 MFP4 쓰기만 순서대로 뽑는다
    grep -oE 'w3@0x[0-9a-fA-F]+ 0x02 0xca 0x[0-9a-fA-F]+' "$CALLS" \
        | sed 's/w3@//; s/ 0x02 0xca / /' | tr '\n' ',' | sed 's/,$//'
}
seq_for() {    # $1=DETECT $2=채널 $3=명령 $4=값
    : > "$CALLS"
    PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="$1" EDGECONF_DIR="$CONF" \
        MCP4018_LOCK_DIR="${MCP4018_LOCK_DIR:-$WORK}" \
        bash "$SCRIPT" "$2" "$3" ${4:+"$4"} >/dev/null 2>&1
    gate_seq
}

# 듀얼에서는 내 게이트를 열기 전에 상대 게이트를 먼저 내려야 한다. 진단용 `on` 은
# 게이트를 열어 둔 채 끝나므로, `0 on` 뒤 `1 set` 이면 0x40·0x60 이 동시에 열려
# 0x2F 쓰기가 양쪽 pot 에 도달한다.
write_conf true true false false
t_eq "듀얼 · ch1 set → 0x40 내리고 0x60 열고 닫기" "$(seq_for '' 1 set 0x10)" \
     "0x40 0x80,0x60 0x90,0x60 0x80"
t_eq "듀얼 · ch0 set → 0x60 내리고 0x40 열고 닫기" "$(seq_for '' 0 set 0x10)" \
     "0x60 0x80,0x40 0x90,0x40 0x80"
t_eq "듀얼 · ch1 get → 0x40 내리고 0x60 열고 닫기" "$(seq_for '' 1 get)" \
     "0x40 0x80,0x60 0x90,0x60 0x80"
write_conf false false true true
t_eq "듀얼 · ch3 set → bus1 도 같은 규칙"        "$(seq_for '' 3 set 0x10)" \
     "0x40 0x80,0x60 0x90,0x60 0x80"
write_conf true false false false
t_eq "단일 ch0 · set → 상대가 없으므로 열고 닫기만" "$(seq_for '' 0 set 0x10)" \
     "0x40 0x90,0x40 0x80"

# 게이트를 연 뒤에 실제 전송이 일어나야 한다 (순서 확인)
: > "$CALLS"
write_conf true true false false
PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="" EDGECONF_DIR="$CONF" MCP4018_LOCK_DIR="$WORK" \
    bash "$SCRIPT" 1 set 0x10 >/dev/null 2>&1
t_eq "상대 내리기 → 열기 → i2cset → 닫기 순서" \
     "$(grep -nE '0xca 0x90|i2cset|0xca 0x80' "$CALLS" | cut -d: -f1 | tr '\n' ' ')" "1 2 3 4 "

echo
echo "=== 게이트 주소를 모르면 set/get 도 진행할 수 없다 ==="
# 이전에는 0x2f 로 바로 갔으나, 이제 어느 ser 의 게이트를 열지 알아야 한다.
clear_conf
run "설정 없음 + 스캔 무응답 · set → 중단" "" 1 set none 1
# run() 은 값 인자를 넘기지 않으므로 set 은 직접 부른다.
t_eq "설정 없음 + 스캔 dual · set → 0x60 게이트" "$(seq_for '11 12' 1 set 0x10)" \
     "0x40 0x80,0x60 0x90,0x60 0x80"

echo
echo "=== 게이트 조작이 실패하면 진행하지 않는다 ==="
# 상대 게이트를 못 내리면 0x2F 쓰기가 양쪽에 도달할 수 있으므로 중단해야 한다.
# 닫기 실패는 쓰기가 성공했어도 실패로 보고한다 — 게이트가 열린 채 남기 때문이다.
gate_fail_stub() {   # $1=실패시킬 MFP4 값(0x90=열기, 0x80=닫기)
    cat > "$STUB/i2ctransfer" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\$CALLS"
case "\$*" in *"$1") echo "i2ctransfer: NAK" >&2; exit 1 ;; esac
echo "0x00"
EOF
    chmod +x "$STUB/i2ctransfer"
}
restore_stub() {
    cat > "$STUB/i2ctransfer" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
echo "0x00"
EOF
    chmod +x "$STUB/i2ctransfer"
}

write_conf true true false false
gate_fail_stub 0x80          # 상대 내리기(및 닫기)가 실패
: > "$CALLS"
out=$(PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="" EDGECONF_DIR="$CONF" MCP4018_LOCK_DIR="$WORK" \
      bash "$SCRIPT" 1 set 0x10 2>&1); rc=$?
t_eq "상대 게이트 못 내리면 중단"        "exit=$rc set=$(grep -c i2cset "$CALLS")" "exit=1 set=0"
t_eq "중단 사유를 stderr 로 알린다"      "$(printf '%s' "$out" | grep -c 'peer MCP4018 gate')" 1
t_eq "i2ctransfer stderr 를 삼키지 않는다" \
     "$([ "$(printf '%s' "$out" | grep -c 'NAK')" -ge 1 ] && echo yes || echo no)" yes
# 상대 내리기에서 멈추면 내 게이트는 건드린 적이 없다. 안전망 trap 이 열지도 않은
# 게이트에 닫기를 보내면 불필요한 I2C 트래픽과 거짓 "may stay open" 경고가 난다.
t_eq "열지 않은 게이트는 닫지 않는다"    "$(gate_seq)" "0x40 0x80"
t_eq "거짓 경고를 내지 않는다"           "$(printf '%s' "$out" | grep -c 'may stay open')" 0

restore_stub
write_conf true false false false   # 단일 — 상대가 없어 닫기만 실패시킬 수 있다
gate_fail_stub 0x80
: > "$CALLS"
out=$(PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="" EDGECONF_DIR="$CONF" MCP4018_LOCK_DIR="$WORK" \
      bash "$SCRIPT" 0 set 0x10 2>&1); rc=$?
t_eq "쓰기 성공 + 닫기 실패 → 실패로 보고" "exit=$rc set=$(grep -c i2cset "$CALLS")" "exit=1 set=1"
t_eq "닫기 실패를 경고로 알린다"           "$(printf '%s' "$out" | grep -c 'may stay open')" 1
restore_stub

echo
echo "=== 같은 버스는 한 번에 한 프로세스만 (게이트 상태가 프로세스 밖에 있으므로) ==="
if command -v flock >/dev/null 2>&1; then
    LOCKDIR="$WORK/lock"; mkdir -p "$LOCKDIR"
    export MCP4018_LOCK_WAIT=1     # 기본 5s 를 기다리면 스위트가 느려진다
    write_conf true true false false

    # 락을 잡아 두는 보조 프로세스. `flock -c 'sleep N'` 은 sleep 이 자식이라
    # kill 로 fd 가 안 닫혀 락이 남는다. 파일 신호로 스스로 빠져나오게 한다.
    RELEASE="$WORK/release"
    hold_lock() {
        rm -f "$RELEASE"
        # 프로덕션과 같이 fd 를 동적 할당한다. 고정 fd 는 테스트 환경에서 이미
        # 열려 있는 fd 를 조용히 덮어쓸 수 있다.
        ( exec {hfd}>"$LOCKDIR/mcp4018_i2c2.lock"
          flock "$hfd"
          while [ ! -f "$RELEASE" ]; do sleep 0.05; done ) &
        holder=$!
        sleep 0.5
    }
    release_lock() { touch "$RELEASE"; wait "$holder" 2>/dev/null; }

    # 먼저 락을 잡고 있으면 진입하지 못한다 (대기 후 포기).
    hold_lock
    : > "$CALLS"
    out=$(PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="" EDGECONF_DIR="$CONF" \
          MCP4018_LOCK_DIR="$LOCKDIR" bash "$SCRIPT" 1 set 0x10 2>&1); rc=$?
    t_eq "set: 락이 잡혀 있으면 게이트를 건드리지 않는다" \
         "exit=$rc gate=$(grep -c 0xca "$CALLS")" "exit=1 gate=0"
    t_eq "대기 실패를 알린다" "$(printf '%s' "$out" | grep -c 'holds i2c-2')" 1

    # get 도 게이트를 조작하므로 같은 락을 잡아야 한다. set 만 검증하면 get 쪽
    # 누락이 그대로 통과한다(실제로 그렇게 빠뜨렸다).
    : > "$CALLS"
    out=$(PATH="$STUB:$PATH" CALLS="$CALLS" DETECT="" EDGECONF_DIR="$CONF" \
          MCP4018_LOCK_DIR="$LOCKDIR" bash "$SCRIPT" 1 get 2>&1); rc=$?
    t_eq "get: 락이 잡혀 있으면 게이트를 건드리지 않는다" \
         "exit=$rc gate=$(grep -c 0xca "$CALLS")" "exit=1 gate=0"
    release_lock

    # 락이 풀리면 정상 동작하고, 끝난 뒤 다음 호출도 막히지 않는다.
    t_eq "락 해제 후 정상 동작"  "$(MCP4018_LOCK_DIR=$LOCKDIR seq_for '' 1 set 0x10)" \
         "0x40 0x80,0x60 0x90,0x60 0x80"
    t_eq "락을 물고 있지 않는다" "$(MCP4018_LOCK_DIR=$LOCKDIR seq_for '' 0 set 0x10)" \
         "0x60 0x80,0x40 0x90,0x40 0x80"

    # 다른 버스는 서로 막지 않는다.
    hold_lock
    write_conf false false true true
    t_eq "bus1 은 bus2 락에 걸리지 않는다" "$(MCP4018_LOCK_DIR=$LOCKDIR seq_for '' 3 set 0x10)" \
         "0x40 0x80,0x60 0x90,0x60 0x80"
    release_lock
else
    echo "  SKIP flock 없음"
fi

t_summary "mcp4018 주소 해석"
