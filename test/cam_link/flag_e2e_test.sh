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

# 호출 수 계산 근거 (리셋 제거 후):
#   스크립트 시작 시 버스별 초기 읽기 1회씩 = 2
#   듀얼 분기에서 verdict 가 ok/errb_only 가 아니면 읽기 재시도 3회 (버스당)
#   쓰기(리셋)는 없다. 단일채널 분기는 재시도가 없다.
echo "=== 채널 인자별 플래그 생성 (i2c 상시 실패 = read_fail) ==="
run "전 채널 활성(15)"   "" 15 "ch0 ch1 ch2 ch3" 8
run "ch0 만 활성(1)"     "" 1  "ch0"             2
run "ch1 만 활성(2)"     "" 2  "ch1"             2
run "ch2+ch3 활성(12)"   "" 12 "ch2 ch3"         5
run "전 채널 비활성(0)"  "" 0  ""                0

echo
echo "=== 판정값별 동작 (전 채널 활성) ==="
run "0xfa 정상 → 플래그 없음, 재시도 없음"   0xfa 15 ""                2
run "0xfe ERRB만 → 플래그 없음, 재시도 없음" 0xfe 15 ""                2
run "0x36 LOCKED=0 → 양쪽"                   0x36 15 "ch0 ch1 ch2 ch3" 8
run "0x32 벤치 관측값 → 양쪽"                0x32 15 "ch0 ch1 ch2 ch3" 8

echo
echo "=== 듀얼 구성에서 채널을 특정하지 않는가 (회귀 방지) ==="
# 과거 0xda→ch0만, 0xea→ch1만 으로 지목했다. 그 지목은 실측 일치율 0/10 이었고
# 값 자체가 스크립트 리셋의 산물이었다. 되살아나면 여기서 실패한다.
run "0xda 구 CAM0_ERR → 한쪽만 지목하면 안 됨" 0xda 15 "ch0 ch1 ch2 ch3" 8
run "0xea 구 CAM1_ERR → 한쪽만 지목하면 안 됨" 0xea 15 "ch0 ch1 ch2 ch3" 8

echo
echo "=== 리셋 write 가 실제로 사라졌는가 ==="
rm -f "$WORK"/err_cam* "$WORK/calls"
t_make_stubs "$STUB" 0x36 "$WORK/callargs"
# 인자까지 기록하는 스텁으로 교체
cat > "$STUB/i2ctransfer" <<STUBEOF
#!/bin/sh
echo "\$*" >> "$WORK/callargs"
echo 0x36
STUBEOF
chmod +x "$STUB/i2ctransfer"
: > "$WORK/callargs"
PATH="$STUB:$PATH" bash "$CHK" 15 >/dev/null 2>&1 || true
t_eq "쓰기(w3@) 호출 횟수" "$(grep -c 'w3@' "$WORK/callargs" || true)" "0"
t_eq "CTRL0(0x10) 접근 횟수" "$(grep -c '0x00 0x10' "$WORK/callargs" || true)" "0"
t_eq "읽기(w2@…r1)만 사용"  "$(grep -vc 'w2@0x48 0x00 0x13 r1' "$WORK/callargs" || true)" "0"

t_summary "플래그 생성 E2E"
