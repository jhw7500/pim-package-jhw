#!/bin/bash
# 카메라 링크 판정·복구 로직 테스트 공통 헬퍼
#
# 이 디렉터리의 테스트는 실제 하드웨어 없이 동작한다. 대상 스크립트에서 함수/상수
# 블록만 잘라내 source 하거나, i2ctransfer·modprobe 를 PATH 스텁으로 바꿔치기해
# 판정 결과만 확인한다. /tmp 의 실제 상태 파일은 건드리지 않는다.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIM_BIN="$REPO_ROOT/dist/pim/opt/pim/bin"
PIM_LIB="$REPO_ROOT/dist/pim/opt/pim/lib"
PIM_CFG="$REPO_ROOT/dist/pim/opt/pim/config"

t_pass=0
t_fail=0

t_ok()  { t_pass=$((t_pass + 1)); printf "  OK   %s\n" "$1"; }
t_bad() { t_fail=$((t_fail + 1)); printf "  FAIL %s\n" "$1"; }

# $1=설명  $2=실제값  $3=기대값
t_eq() {
    if [ "$2" = "$3" ]; then
        t_ok "$1 → [$2]"
    else
        t_bad "$1 → [$2]  기대 [$3]"
    fi
}

t_summary() {
    echo
    printf "%s: %d 통과 / %d 실패\n" "${1:-결과}" "$t_pass" "$t_fail"
    [ "$t_fail" -eq 0 ]
}

# 스크립트 앞부분(상수·함수 정의)만 잘라낸다. 본문이 실행되면 i2ctransfer 를
# 호출하므로 정의부만 source 하기 위한 것.
# $1=원본 파일  $2=이 패턴이 나오는 줄 직전까지  $3=출력 파일
t_extract_head() {
    local src="$1" stop="$2" out="$3" n
    n=$(grep -n -- "$stop" "$src" | head -1 | cut -d: -f1)
    [ -n "$n" ] || { echo "정의부 추출 실패: '$stop' 없음 ($src)" >&2; return 1; }
    head -n $((n - 1)) "$src" > "$out"
}

# 함수 하나만 잘라낸다. $1=원본  $2=함수명  $3=출력 파일
# 선언 스타일 변화(fn(){ / fn () { / fn ()  {)에 견디도록 공백을 유연하게 받는다.
t_extract_func() {
    local src="$1" fn="$2" out="$3"
    awk -v f="^${fn}[[:space:]]*\\\\([[:space:]]*\\\\)[[:space:]]*\\\\{" \
        '$0 ~ f {p=1} p {print} p && /^\}/ {exit}' "$src" > "$out"
    [ -s "$out" ] || { echo "함수 추출 실패: $fn ($src)" >&2; return 1; }
}

# i2ctransfer / logger / sleep PATH 스텁 생성
# $1=스텁 디렉터리  $2=i2ctransfer 가 출력할 값(비우면 읽기 실패로 동작)
# $3=호출 횟수를 기록할 파일(선택)
t_make_stubs() {
    local d="$1" val="$2" calls="$3"
    mkdir -p "$d"
    printf '#!/bin/sh\nexit 0\n' > "$d/logger"
    printf '#!/bin/sh\nexit 0\n' > "$d/sleep"
    {
        echo '#!/bin/sh'
        [ -n "$calls" ] && echo "echo x >> '$calls'"
        if [ -n "$val" ]; then
            echo "echo '$val'"
        else
            echo 'echo "Error: Read failed" >&2'
            echo 'exit 1'
        fi
    } > "$d/i2ctransfer"
    chmod +x "$d/logger" "$d/sleep" "$d/i2ctransfer"
}
