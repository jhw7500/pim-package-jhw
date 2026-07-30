#!/bin/bash
# chk_cam_connect.sh 전체 실행 검증 (i2ctransfer 스텁)
# 사용법: bash test/cam_link/flag_e2e_test.sh
#
# 스크립트 사본의 FLAG_PATH 를 임시 디렉터리로 바꿔 실행하므로 /tmp 의 실제
# err_cam*.log 는 건드리지 않는다. i2ctransfer / logger / sleep 은 PATH 스텁.
# 확인 대상: (1) 어느 채널에 err_cam 플래그가 생기는가
#            (2) i2c 호출 횟수 — errb_only 는 재시도를 하지 않아야 한다
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

echo "=== 채널 인자별 플래그 생성 (i2c 상시 실패 = read_fail) ==="
# 호출 수는 읽기와 쓰기를 합한 값이다(스텁이 구분하지 않음 — lib.sh 참고).
# read_fail 은 리셋 대상이라 버스당 = 재시도 읽기 3 + 리셋 쓰기 2(w3@0x48, w3@0x40)
# + 재읽기 1 = 6회. 여기에 스크립트 시작 시 버스별 초기 읽기 1회씩(총 2회)이 더해진다.
run "전 채널 활성(15)"      "" 15 "ch0 ch1 ch2 ch3" 14
run "ch0 만 활성(1)"        "" 1  "ch0"             2
run "ch1 만 활성(2)"        "" 2  "ch1"             2
run "ch2+ch3 활성(12)"      "" 12 "ch2 ch3"         8
run "전 채널 비활성(0)"     "" 0  ""                0

echo
echo "=== 판정값별 동작 (전 채널 활성) ==="
run "0xfa 정상 → 플래그 없음, 재시도 없음"        0xfa 15 ""                2
run "0xfe ERRB만 → 플래그 없음, 재시도 없음"      0xfe 15 ""                2
run "0xda Link A 단독 → 짝수 채널만"              0xda 15 "ch0 ch2"        14
run "0xea Link B 단독 → 홀수 채널만"              0xea 15 "ch1 ch3"        14
run "0x36 LOCKED=0 → 양쪽"                        0x36 15 "ch0 ch1 ch2 ch3" 14
# unknown 은 리셋 대상이 아니므로 버스당 재시도 3회만(리셋 2 + 재읽기 1 없음) → 2+3+3=8
run "0x0a 미정의 유효값 → 플래그 없음, 리셋 안 함" 0x0a 15 ""                8

echo
echo "=== 리셋 쓰기(w3@) 실패 시 진단 로그를 남기는가 ==="
# 읽기(w2@...r1)는 0xda 를 주고 쓰기(w3@)만 실패시켜 리셋 write 실패 경로를 만든다.
rm -f "$WORK"/err_cam* "$WORK/logged"
mkdir -p "$STUB"
cat > "$STUB/i2ctransfer" <<'STUBEOF'
#!/bin/sh
for a in "$@"; do
    case "$a" in w3@*) exit 1 ;; esac    # 모든 쓰기는 실패
done
echo 0xda
STUBEOF
# heredoc 구분자를 인용하지 않아 $WORK 는 지금 확장되고(스텁에 경로가 박힌다),
# \$* 는 이스케이프해 스텁 실행 시점의 인자로 남긴다.
cat > "$STUB/logger" <<STUBEOF
#!/bin/sh
echo "\$*" >> "$WORK/logged"
STUBEOF
printf '#!/bin/sh\nexit 0\n' > "$STUB/sleep"
chmod +x "$STUB"/*
PATH="$STUB:$PATH" bash "$CHK" 15 >/dev/null 2>&1 || true

t_eq "CAM01 reset write failed 경고" \
     "$(grep -c 'CAM01 reset write failed (des:1 ser:1)' "$WORK/logged" 2>/dev/null || echo 0)" "1"
t_eq "CAM23 reset write failed 경고" \
     "$(grep -c 'CAM23 reset write failed (des:1 ser:1)' "$WORK/logged" 2>/dev/null || echo 0)" "1"
t_eq "warning 레벨로 기록" \
     "$(grep -c 'local0.warning.*reset write failed' "$WORK/logged" 2>/dev/null || echo 0)" "2"

t_summary "플래그 생성 E2E"
