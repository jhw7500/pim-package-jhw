#!/bin/bash
# chk_cam_connect.sh 전체 실행 검증 (i2ctransfer 스텁)
# 사용법: bash test/cam_link/flag_e2e_test.sh
#
# 스크립트 사본의 FLAG_PATH 를 임시 디렉터리로 바꿔 실행하므로 /tmp 의 실제
# err_cam*.log 는 건드리지 않는다. i2ctransfer / logger / sleep 은 PATH 스텁.
#
# 확인 대상:
#  (1) 어느 채널에 err_cam 플래그가 생기는가 — 듀얼 구성에서는 채널을 특정하지 않는다
#  (2) i2c 호출 횟수 — 리셋이 제거됐으므로 쓰기 호출이 0이어야 한다
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
CHK="$WORK/chk.sh"
STUB="$WORK/bin"
trap 'rm -rf "$WORK"' EXIT

sed "s#^FLAG_PATH=\"/tmp\"#FLAG_PATH=\"$WORK\"#" "$PIM_BIN/chk_cam_connect.sh" > "$CHK"
grep -q "^FLAG_PATH=\"$WORK\"$" "$CHK" || { echo "FLAG_PATH 치환 실패" >&2; exit 1; }

# $1=설명 $2=i2c 반환값(비우면 읽기 실패) $3=cam_ch_en 인자 $4=기대 플래그 $5=기대 i2c 호출수
run() {
    rm -f "$WORK"/err_cam* "$WORK/calls"
    t_make_stubs "$STUB" "$2" "$WORK/calls"
    PATH="$STUB:$PATH" bash "$CHK" "$3" >/dev/null 2>&1 || true
    local flags calls
    flags=$(ls "$WORK" | grep '^err_cam' | sed 's/err_cam\([0-9]\)\.log/ch\1/' | sort | paste -sd' ' -)
    if [ -f "$WORK/calls" ]; then calls=$(wc -l < "$WORK/calls"); else calls=0; fi
    t_eq "$1" "[${flags}]/${calls}" "[${4}]/${5}"
}

# 호출 수 계산 근거:
#   스크립트 시작 시 버스별 초기 읽기 1회씩 = 2
#   듀얼 분기에서 verdict 가 ok/errb_only 가 아니면 읽기 재시도 3회 (버스당)
#   이상이 감지되면 log_ctrl3 가 RX3(0x2f) 진단 읽기를 1회 추가 (버스당)
#   쓰기(리셋)는 없다. 단일채널 분기는 재시도가 없다.
echo "=== 채널 인자별 플래그 생성 (i2c 상시 실패 = read_fail) ==="
run "전 채널 활성(15)"   "" 15 "ch0 ch1 ch2 ch3" 10
run "ch0 만 활성(1)"     "" 1  "ch0"             3
run "ch1 만 활성(2)"     "" 2  "ch1"             3
run "ch2+ch3 활성(12)"   "" 12 "ch2 ch3"         6
run "전 채널 비활성(0)"  "" 0  ""                0

echo
echo "=== 판정값별 동작 (전 채널 활성) ==="
run "0xfa 정상 → 플래그 없음, 재시도 없음"   0xfa 15 ""                2
run "0xfe ERRB만 → 플래그 없음, 재시도 없음" 0xfe 15 ""                4
run "0x36 LOCKED=0 → 양쪽"                   0x36 15 "ch0 ch1 ch2 ch3" 10
run "0x32 벤치 관측값 → 양쪽"                0x32 15 "ch0 ch1 ch2 ch3" 10

echo
echo "=== 듀얼 구성에서 채널을 특정하지 않는가 (회귀 방지) ==="
# 과거 0xda→ch0만, 0xea→ch1만 으로 지목했다. 그 지목은 실측 일치율 0/10 이었고
# 값 자체가 스크립트 리셋의 산물이었다. 되살아나면 여기서 실패한다.
run "0xda 구 CAM0_ERR → 한쪽만 지목하면 안 됨" 0xda 15 "ch0 ch1 ch2 ch3" 10
run "0xea 구 CAM1_ERR → 한쪽만 지목하면 안 됨" 0xea 15 "ch0 ch1 ch2 ch3" 10

echo
echo "=== 단일 채널 구성에서 mode_unexpected 가 누락되지 않는가 ==="
# 단일채널 case 에는 mode_unexpected 전용 분기가 없고 캐치올 *) 이 처리한다.
# "분기가 없어 아무 로그·플래그 없이 통과한다"는 오해를 막기 위해 실동작을 못박는다.
# ch0 단독(기대 = CH_EVEN_LINK)에서:
#   0x0a = Dual(00)+LOCKED=1  → swap 도 기대 모드도 아님 → 에러 + 플래그
#   0x1a = Link A(01)+LOCKED=1 → 반대 링크 = swap 케이스 → 경고만(플래그 없음, 기존 동작)
run "ch0 단독 · 0x0a 기대 모드 아님 → 플래그 생성" 0x0a 1 "ch0" 3
run "ch0 단독 · 0xea swap 케이스 → 경고만"         0xea 1 ""    3
run "ch0 단독 · 0x1a Link A = 정상"                0x1a 1 ""    2
# LOCKED=0(실제 링크 단절)도 같은 캐치올을 지난다. swap 조건(locked=1)이 아니므로
# 해당 채널 플래그가 나와야 한다. *) else 분기를 손댈 때의 회귀를 막는다.
run "ch0 단독 · 0x12 LOCKED=0 → 플래그 생성"       0x12 1 "ch0" 3
run "ch1 단독 · 0x32 LOCKED=0 → 플래그 생성"       0x32 2 "ch1" 3

echo
echo "=== 회복 로그가 재시도 횟수를 담는가 ==="
# recovered_by 는 재시도 루프에서 "read retry N" 으로 설정된다. 리뷰에서 이 변수를
# dead 로 보고 "read retry" 하드코딩을 제안받았는데, 그러면 몇 번째에 회복됐는지가
# 사라진다. 실제 값이 유지되는지 못박는다.
rm -f "$WORK"/err_cam* "$WORK/logged" "$WORK/n"
printf '#!/bin/sh\nexit 0\n' > "$STUB/sleep"
cat > "$STUB/logger" <<STUBEOF
#!/bin/sh
echo "\$*" >> "$WORK/logged"
STUBEOF
# 스크립트는 분기 진입 전에 cam01·cam23 를 무조건 한 번씩 읽는다. 전역 카운터를 쓰면
# cam23 초기 읽기가 슬롯을 소비해 "몇 번째 재시도인지"가 그 구조에 결합된다.
# 버스(-a 2)별로 세어 결합을 끊는다. i2c-2 기준:
#   1회차 = cam01 초기 읽기(0x36) → ok 아님 → 재시도 루프 진입
#   2회차 = 재시도 r=1 (0x36)     → 여전히 ok 아님
#   3회차 = 재시도 r=2 (0xfa)     → 회복 → recovered_by="read retry 2"
cat > "$STUB/i2ctransfer" <<STUBEOF
#!/bin/sh
case "\$*" in
  *"-a 2"*)
    n=\$(cat "$WORK/n" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "$WORK/n"
    if [ \$n -le 2 ]; then echo 0x36; else echo 0xfa; fi ;;
  *) echo 0x36 ;;
esac
STUBEOF
chmod +x "$STUB/sleep" "$STUB/logger" "$STUB/i2ctransfer"
echo 0 > "$WORK/n"
PATH="$STUB:$PATH" bash "$CHK" 3 >/dev/null 2>&1 || true
t_eq "recovered 로그에 재시도 횟수 포함" \
     "$(grep -oE 'recovered \(read retry [0-9]+\)' "$WORK/logged" | head -1)" \
     "recovered (read retry 2)"

echo
echo "=== 리셋 write 가 실제로 사라졌는가 ==="
rm -f "$WORK"/err_cam* "$WORK/callargs"
# 인자까지 기록하는 스텁으로 교체
printf '#!/bin/sh\nexit 0\n' > "$STUB/logger"
printf '#!/bin/sh\nexit 0\n' > "$STUB/sleep"
cat > "$STUB/i2ctransfer" <<STUBEOF
#!/bin/sh
echo "\$*" >> "$WORK/callargs"
echo 0x36
STUBEOF
chmod +x "$STUB/logger" "$STUB/sleep" "$STUB/i2ctransfer"
: > "$WORK/callargs"
PATH="$STUB:$PATH" bash "$CHK" 15 >/dev/null 2>&1 || true
# grep -vc 는 빈 파일에서도 0 이라 공허하게 통과한다. 호출이 실제로 있었는지 먼저 단정한다.
t_eq "i2c 호출이 실제로 발생" "$([ -s "$WORK/callargs" ] && echo yes || echo no)" "yes"
t_eq "쓰기(w3@) 호출 횟수"    "$(grep -c 'w3@' "$WORK/callargs" || true)" "0"
t_eq "CTRL0(0x10) 접근 횟수"  "$(grep -c '0x00 0x10' "$WORK/callargs" || true)" "0"
# 진단용 RX3(0x2f) 읽기가 추가됐다. 허용 대상은 CTRL3(0x13)·RX3(0x2f) 읽기뿐이고
# 그 외 트랜잭션은 0 이어야 한다.
t_eq "허용된 읽기 외 호출" \
     "$(grep -vcE 'w2@0x48 0x00 (0x13|0x2f) r1' "$WORK/callargs" || true)" "0"
t_eq "RX3(0x2f) 진단 읽기 발생" \
     "$([ "$(grep -c '0x00 0x2f' "$WORK/callargs")" -gt 0 ] && echo yes || echo no)" "yes"

echo
echo "=== RX3 faillock 디코드 (판정에는 쓰지 않고 로그에만) ==="
# ch0 제거 → FAILLOCK_A(0x01) → faillock=A / ch1 제거 → FAILLOCK_B(0x10) → faillock=B
# CTRL3 는 이상값(0x36)을 주어 log_ctrl3 가 호출되게 한다.
for pair in "0x01:A" "0x10:B" "0x11:AB" "0x00:none"; do
    rx3v="${pair%%:*}"; want="${pair##*:}"
    rm -f "$WORK/logged"
    printf '#!/bin/sh\nexit 0\n' > "$STUB/sleep"
    cat > "$STUB/logger" <<STUBEOF
#!/bin/sh
echo "\$*" >> "$WORK/logged"
STUBEOF
    cat > "$STUB/i2ctransfer" <<STUBEOF
#!/bin/sh
case "\$*" in
  *"0x00 0x2f"*) echo $rx3v ;;
  *) echo 0x36 ;;
esac
STUBEOF
    chmod +x "$STUB/sleep" "$STUB/logger" "$STUB/i2ctransfer"
    PATH="$STUB:$PATH" bash "$CHK" 15 >/dev/null 2>&1 || true
    t_eq "RX3 $rx3v → faillock" \
         "$(grep -oE 'faillock=[A-Za-z]+' "$WORK/logged" | head -1)" "faillock=$want"
done

t_summary "플래그 생성 E2E"
