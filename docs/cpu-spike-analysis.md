# 로그 분석: 2026-02-06 09:09:10 이후 CPU 급증 사례

> 참고: 현재 `chk_cam_operate.sh` 기본 임계치는 warn=95%, crit=98% 입니다.
> 아래 로그 예시는 과거 설정(warn=90%, crit=95%) 기준으로 수집된 케이스를 설명합니다.

## 로그 타임스탬프 분석

```
09:09:06.008 [GST][main.c:219] Session complete: 20260206_0908
09:09:06.010 [GST][main.c:1738] filename : /dev/shm/VD3001_20260206_090900-ch1.mp4.part, time : 60000000000
09:09:07.332 [RST][chk_cam_operate.sh:403] processing session: 20260206_0908
09:09:09.718 [RST][chk_cam_operate.sh:442] session 20260206_0908 completed: 5 files
09:09:10.118 [RST][chk_cam_operate.sh:282] retention: disk usage 90% >= 90% (dir=/mnt/sd_cam)
```

**시간 경과**:
- Session complete → Processing 시작: ~1.3초 (09:09:06.008 ~ 09:09:07.332)
- Processing → 완료: ~2.4초 (09:09:07.332 ~ 09:09:09.718)
- 완료 → retention 로그: **~0.4초** (09:09:09.718 ~ 09:09:10.118)

---

## 문제 원인 분석

### 1. `enforce_sd_retention_if_needed` 반복 루프 진입

**코드 위치**: `chk_cam_operate.sh`의 `enforce_sd_retention_if_needed`

**코드 흐름**:
```bash
enforce_sd_retention_if_needed() {
    local target_dir="$1"
    local warn_pct=${WARN_PCT:-$WARN_PCT_DEFAULT}  # 기본: 95
    local crit_pct=${CRIT_PCT:-$CRIT_PCT_DEFAULT}  # 기본: 98

    usage=$(get_df_usage_pct "$target_dir")  # df -P 실행

    if [ "$usage" -lt "$warn_pct" ]; then
        return 0  # warn 미만이면 종료
    fi

    logger "retention: disk usage ${usage}% >= ${warn_pct}%"

    sessions=$(list_sessions_in_dir_sorted "$target_dir")  # 디렉토리 전체 스캔 + sort

    while :; do  # ==== 무한 루프 시작 ====
        usage=$(get_df_usage_pct "$target_dir")  # df -P 실행 (매 루프마다)
        [ "$usage" -ge "$warn_pct" ] || break  # warn 미만이면 루프 종료

        sid=$(printf '%s\n' "$sessions" | head -n 1)  # 가장 오래된 세션
        delete_session_in_dir "$target_dir" "$sid"  # 파일 삭제

        sessions=$(list_sessions_in_dir_sorted "$target_dir")  # ==== 디렉토리 다시 스캔 + sort ====
        [ -n "$sessions" ] || break
    done
}
```

### 2. 무한 루프 실행 빈도 분석

**한 루프 사이클 연산량** (파일 200개 기준):

| 연산 | 예상 시간 | 설명 |
| :--- | :--- | :--- |
| **df -P** | 10-50ms | 파일 시스템 stat |
| **list_sessions_in_dir_sorted** | 50-200ms | 디렉토리 전체 스캔(200개) + sort + uniq |
| **delete_session_in_dir** | 5-10ms | 1세션 4개 파일 삭제 |
| **총 1사이클** | **65-260ms** | |

**초당 루프 수**: 3.8 ~ 15.4회
**1분당 루프 수**: 230 ~ 924회

### 3. df 정밀도 문제

**df -P 출력 예시**:
```
Filesystem     1024-blocks      Used Available Capacity Mounted on
/dev/mmcblk1p1   976752   879076   97676      90% /mnt/sd_cam
```

**문제점**:
- df는 **1% 단위**로만 보고 (정수)
- 1세션 삭제(약 4MB) 후에도 사용량이 **90%에서 그대로**일 가능성 높음
- 결과: **while 루프가 계속 돌며 세션을 계속 삭제**

### 4. 디렉토리 스캔 중복

**list_sessions_in_dir_sorted 함수** (223-243행):
```bash
list_sessions_in_dir_sorted() {
    local dir="$1"
    declare -A _seen
    local f base sid

    [ -d "$dir" ] || return 0

    # ==== 첫 번째 스캔 ====
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        case "$base" in
            *.part) continue;;
        esac
        sid=$(extract_session_id_from_filename "$base")
        [ -n "$sid" ] || continue
        _seen["$sid"]=1
    done

    if [ ${#_seen[@]} -gt 0 ]; then
        printf '%s\n' "${!_seen[@]}" | sort  # ==== 전체 정렬 ====
    fi
}
```

**while 루프 내 호출 횟수**:
- 첫 번째: 291행 이전 (초기 호출)
- 두 번째: 308행 (첫 번째 삭제 후)
- 세 번째: 308행 (두 번째 삭제 후)
- ...

**결과**: 매 삭제마다 **디렉토리 전체 스캔 + sort + uniq** 반복

### 5. 예상 시나리오

**초기 상태**:
- 디스크 사용량: 90%
- 총 세션 수: 200개
- 보호 세션: 2개 (PROTECT_RECENT_SESSIONS=2)

**진행**:
```
루프 1: df=90% → 스캔(200개) + sort → 삭제(세션 1) → df=90% (변화 없음)
루프 2: df=90% → 스캔(199개) + sort → 삭제(세션 2) → df=90% (변화 없음)
루프 3: df=90% → 스캔(198개) + sort → 삭제(세션 3) → df=90% (변화 없음)
...
루프 N: df=90% → 스캔(198개) + sort → 삭제(세션 N) → df=89% (드디어 변화)
```

**CPU 소모량**:
- 디렉토리 스캔 + sort: 매 루프마다 O(n log n)
- df -P 호출: 매 루프마다
- 파일 삭제: 매 루프마다

**결과**: 디스크 사용량이 90% 미만으로 떨어질 때까지 **거의 무한에 가까운 루프 실행**

---

## CPU 급증 원인 결론

### 주요 원인 1: df -P 정밀도 문제
- df는 1% 단위로만 보고하여, 작은 파일 삭제 후에도 사용량 변화를 감지하지 못함
- while 루프가 **불필요하게 계속 실행**되며 세션을 과도하게 삭제

### 주요 원인 2: list_sessions_in_dir_sorted 반복 호출
- 매 루프마다 디렉토리 **전체 스캔 + sort + uniq**
- 파일 수가 200개 이상이면 **O(n log n)** 연산이 매 루프마다 반복

### 주요 원인 3: df -P 빈번한 호출
- while 루프 내에서 매번 df -P 실행
- 초당 4~15회 df 호출 (파일 수에 따라)

---

## 최적화 제안

### 우선순위 1: df -P 호출 횟수 줄이기

**현재**:
```bash
while :; do
    usage=$(get_df_usage_pct "$target_dir")  # 매 루프마다 호출
    [ "$usage" -lt "$warn_pct" ] || break
    # ...
done
```

**개선**: 삭제 N회 후에만 df 체크
```bash
enforce_sd_retention_if_needed() {
    local target_dir="$1"
    local warn_pct=${WARN_PCT:-$WARN_PCT_DEFAULT}
    local crit_pct=${CRIT_PCT:-$CRIT_PCT_DEFAULT}
    local protect_n=${PROTECT_RECENT_SESSIONS:-$PROTECT_RECENT_SESSIONS_DEFAULT}
    local usage sid
    local sessions keep_line
    local df_check_interval=5  # 5회 삭제마다 df 체크
    local delete_count=0

    usage=$(get_df_usage_pct "$target_dir")
    [ -n "$usage" ] || return 0

    if [ "$usage" -lt "$warn_pct" ]; then
        return 0
    fi

    sessions=$(list_sessions_in_dir_sorted "$target_dir")
    [ -n "$sessions" ] || return 0

    keep_line=$(printf '%s\n' "$sessions" | tail -n "$protect_n" | tr '\n' '|' | sed 's/|$//')

    while :; do
        sid=$(printf '%s\n' "$sessions" | head -n 1)
        [ -n "$sid" ] || break

        if [ -n "$keep_line" ] && printf '%s\n' "$sid" | grep -qE "^(${keep_line})$"; then
            logger -p local0.warning "[$KEY][$tag:$LINENO] retention: only protected sessions remain; cannot delete further"
            break
        fi

        logger -p local0.notice "[$KEY][$tag:$LINENO] retention: deleting session $sid"
        delete_session_in_dir "$target_dir" "$sid"
        ((delete_count++))

        sessions=$(list_sessions_in_dir_sorted "$target_dir")
        [ -n "$sessions" ] || break

        # ==== df 체크 횟수 줄이기 ====
        if [ $((delete_count % df_check_interval)) -eq 0 ]; then
            usage=$(get_df_usage_pct "$target_dir")
            [ -n "$usage" ] || break
            [ "$usage" -lt "$warn_pct" ] && break
        fi
    done

    # 최종 df 체크
    usage=$(get_df_usage_pct "$target_dir")
    if [ "$usage" -ge "$warn_pct" ]; then
        logger -p local0.error "[$KEY][$tag:$LINENO] retention: disk usage still ${usage}% after ${delete_count} deletions"
    fi
}
```

**효과**: df 호출 횟수 **80% 감소** (5회마다 1회 체크)

### 우선순위 2: list_sessions_in_dir_sorted 캐싱

**개선**: 세션 목록을 캐싱하여 중복 스캔 제거
```bash
declare -g _SESSIONS_CACHE_DIR=""
declare -g _SESSIONS_CACHE_TIME=0
declare -g _SESSIONS_CACHE_RESULT=""

list_sessions_in_dir_sorted() {
    local dir="$1"
    local now=$(date +%s)
    local cache_ttl=10  # 10초 캐싱

    # ==== 캐시 유효성 체크 ====
    if [ "$dir" = "$_SESSIONS_CACHE_DIR" ] && \
       [ $((now - _SESSIONS_CACHE_TIME)) -lt "$cache_ttl" ]; then
        printf '%s\n' "$_SESSIONS_CACHE_RESULT"
        return
    fi

    # ==== 기존 스캔 로직 ====
    declare -A _seen
    local f base sid

    [ -d "$dir" ] || return 0

    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        case "$base" in
            *.part) continue;;
        esac
        sid=$(extract_session_id_from_filename "$base")
        [ -n "$sid" ] || continue
        _seen["$sid"]=1
    done

    _SESSIONS_CACHE_DIR="$dir"
    _SESSIONS_CACHE_TIME="$now"
    _SESSIONS_CACHE_RESULT=$(printf '%s\n' "${!_seen[@]}" | sort)

    printf '%s\n' "$_SESSIONS_CACHE_RESULT"
}
```

**효과**: 캐시 유효 기간 동안 디렉토리 스캔 및 sort 생략 (O(n log n) → O(1))

### 우선순위 3: 세션 목록 업데이트 최적화

**현재**: 매 삭제마다 `list_sessions_in_dir_sorted` 호출하여 전체 스캔
**개선**: 삭제된 세션을 캐시 결과에서 제거
```bash
# enforce_sd_retention_if_needed 내부
while :; do
    sid=$(printf '%s\n' "$sessions" | head -n 1)
    [ -n "$sid" ] || break

    if [ -n "$keep_line" ] && printf '%s\n' "$sid" | grep -qE "^(${keep_line})$"; then
        logger -p local0.warning "[$KEY][$tag:$LINENO] retention: only protected sessions remain; cannot delete further"
        break
    fi

    logger -p local0.notice "[$KEY][$tag:$LINENO] retention: deleting session $sid"
    delete_session_in_dir "$target_dir" "$sid"

    # ==== 캐시에서 제거 (재스캔 방지) ====
    sessions=$(printf '%s\n' "$sessions" | tail -n +2)  # 첫 번째(삭제된 세션) 제외

    [ -n "$sessions" ] || break
done
```

**효과**: O(n) 스캔을 O(1)으로 감소 (tail로 첫 번째 항목 제거)

### 우선순위 4: df 대신 du 사용하여 정밀도 개선

**개선**: du를 사용하여 MB 단위로 정밀하게 체크
```bash
get_dir_usage_mb() {
    local dir="$1"
    du -sm "$dir" 2>/dev/null | awk 'NR==2 {print $1}'
}

enforce_sd_retention_if_needed() {
    local target_dir="$1"
    local total_mb used_mb
    local warn_pct=${WARN_PCT:-$WARN_PCT_DEFAULT}
    local crit_pct=${CRIT_PCT:-$CRIT_PCT_DEFAULT}

    total_mb=$(df -P "$target_dir" 2>/dev/null | awk 'NR==2 {print $2}')
    used_mb=$(get_dir_usage_mb "$target_dir")
    local usage=$((used_mb * 100 / total_mb))

    if [ "$usage" -lt "$warn_pct" ]; then
        return 0
    fi

    # ...
}
```

**주의**: du 역시 전체 파일 순회하므로 캐싱과 결합 필요

---

## 최적화 효과 예상

| 최적화 | df 호출 횟수 | 스캔 횟수 | 예상 CPU 감소 |
| :--- | :--- | :--- | :--- |
| **현재** | 매 루프 | 매 루프 | - |
| **우선순위 1 (df 간격화)** | **80% 감소** | 그대로 | ~60% |
| **우선순위 2 (캐싱)** | 그대로 | **90% 감소** | ~80% |
| **우선순위 3 (세션 목록 업데이트)** | 그대로 | **99% 감소** | ~95% |
| **모두 적용** | 80% 감소 | 99% 감소 | **~98%** |

---

## 요약

**CPU 급증 원인**:
1. `enforce_sd_retention_if_needed`의 무한 루프가 df의 1% 정밀도 제한으로 **불필요하게 계속 실행**
2. 매 루프마다 `list_sessions_in_dir_sorted` 호출하여 디렉토리 **전체 스캔 + sort + uniq**
3. df -P를 매 루프마다 호출 (초당 4~15회)

**해결 방안**:
1. df 체크 간격화 (5회 삭제마다 1회)
2. 세션 목록 캐싱 (10초 TTL)
3. 삭제된 세션을 캐시에서 제거하여 재스캔 방지

**예상 효과**: CPU 소모량 98% 감소
