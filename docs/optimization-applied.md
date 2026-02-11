# chk_cam_operate.sh 최적화 적용 보고

## 개요

CPU 급증 문제에 대해 문서화된 최적화 방안을 실제 코드에 적용한 내용입니다.

---

## 적용된 최적화 항목

### 1. df 체크 간격화 (우선순위 1)

**파일**: `chk_cam_operate.sh` (288-345행)
**함수**: `enforce_sd_retention_if_needed`

**변경 내용**:
- `df_check_interval=5` 변수 추가
- `delete_count=0` 변수 추가
- df 체크를 매 루프마다 → 5회 삭제마다 1회로 변경
- 최종 df 체크 추가 (모든 삭제 후)

**예상 효과**: df 호출 횟수 80% 감소 → CPU 소모량 ~60% 감소

**코드 변경**:
```bash
# 변경 전
while :; do
    usage=$(get_df_usage_pct "$target_dir")  # 매 루프마다 df 호출
    [ -n "$usage" ] || break
    [ "$usage" -ge "$warn_pct" ] || break
    # ...
    sessions=$(list_sessions_in_dir_sorted "$target_dir")  # 재스캔
done

# 변경 후
while :; do
    # ...
    sessions=$(printf '%s\n' "$sessions" | tail -n +2)  # 재스캔 방지
    ((delete_count++))

    # 5회 삭제마다만 df 체크
    if [ $((delete_count % df_check_interval)) -eq 0 ]; then
        usage=$(get_df_usage_pct "$target_dir")
        [ -n "$usage" ] || break
        [ "$usage" -lt "$warn_pct" ] && break
    fi
done
```

---

### 2. list_sessions_in_dir_sorted 캐싱 (우선순위 2)

**파일**: `chk_cam_operate.sh` (1-45행, list_sessions_in_dir_sorted 함수)
**함수**: `list_sessions_in_dir_sorted`

**변경 내용**:
- 글로벌 캐시 변수 추가:
  - `_SESSIONS_CACHE_DIR`: 캐시된 디렉토리
  - `_SESSIONS_CACHE_TIME`: 캐시 시간
  - `_SESSIONS_CACHE_RESULT`: 캐시된 세션 목록
  - `_SESSIONS_CACHE_TTL`: 캐시 TTL (기본 10초)
- 캐시 유효성 체크 로직 추가
- 캐시 미스 시 스캔 및 캐시 업데이트 로직 추가

**예상 효과**: 디렉토리 스캔 횟수 90% 감소 → CPU 소모량 ~80% 감소

**코드 변경**:
```bash
# 변경 전
list_sessions_in_dir_sorted() {
    local dir="$1"
    # 매번 전체 스캔 + sort
    for f in "$dir"/*; do
        # ...
    done
    printf '%s\n' "${!_seen[@]}" | sort
}

# 변경 후
# 캐시 변수 전역 선언
_SESSIONS_CACHE_DIR=""
_SESSIONS_CACHE_TIME=0
_SESSIONS_CACHE_RESULT=""
_SESSIONS_CACHE_TTL=${SESSIONS_CACHE_TTL:-10}

list_sessions_in_dir_sorted() {
    local dir="$1"
    local now=$(date +%s)

    # 캐시 유효성 체크
    if [ "$dir" = "$_SESSIONS_CACHE_DIR" ] && \
       [ $((now - _SESSIONS_CACHE_TIME)) -lt "$_SESSIONS_CACHE_TTL" ]; then
        printf '%s\n' "$_SESSIONS_CACHE_RESULT"  # 캐시 반환 (O(1))
        return
    fi

    # 캐시 미스: 스캔 및 업데이트
    # ... 스캔 로직 ...
    _SESSIONS_CACHE_DIR="$dir"
    _SESSIONS_CACHE_TIME="$now"
    _SESSIONS_CACHE_RESULT=$(printf '%s\n' "${!_seen[@]}" | sort)

    printf '%s\n' "$_SESSIONS_CACHE_RESULT"
}
```

---

### 3. 세션 목록 업데이트 최적화 (우선순위 3)

**파일**: `chk_cam_operate.sh` (343-347행)
**함수**: `enforce_sd_retention_if_needed`

**변경 내용**:
- 세션 목록 갱신 로직을 `list_sessions_in_dir_sorted` 호출 → `tail -n +2`로 변경
- 삭제된 세션을 목록에서 제거하여 재스캔 방지

**예상 효과**: 재스캔 횟수 99% 감소 → CPU 소모량 ~95% 감소

**코드 변경**:
```bash
# 변경 전
delete_session_in_dir "$target_dir" "$sid"
((delete_count++))
# refresh list after deletion
sessions=$(list_sessions_in_dir_sorted "$target_dir")  # 재스캔

# 변경 후
delete_session_in_dir "$target_dir" "$sid"
((delete_count++))
# tail -n +2로 첫 번째(삭제된) 항목 제거
sessions=$(printf '%s\n' "$sessions" | tail -n +2)  # 재스캔 방지
```

---

### 4. ProcessCompletedSessions 조건부 호출 (우선순위 4)

**파일**: `chk_cam_operate.sh` (753-758행)
**메인 루프**: 716-944행

**변경 내용**:
- `ProcessCompletedSessions` 무조건 호출 → `compgen -G`로 all_done 파일 존재 체크 후 호출로 변경
- 불필요한 glob 확장 최소화

**예상 효과**: ProcessCompletedSessions 실행 빈도 감소 (all_done 파일이 없는 동안 전체 스캔 생략)

**코드 변경**:
```bash
# 변경 전
# === 이벤트 기반: 완료된 세션 처리 ===
ProcessCompletedSessions  # 무조건 호출

# 변경 후
# === 이벤트 기반: 완료된 세션 처리 (최적화: all_done 파일 존재 시만 호출) ===
if compgen -G '/tmp/session_*.all_done' > /dev/null 2>&1; then
    ProcessCompletedSessions
fi
```

---

## 문법 검사 결과

### bash -n 검사

```bash
$ bash -n /home/jhw/ai/opencode/projects/pim-package/dist/pim/opt/pim/bin/chk_cam_operate.sh
```

**결과**: 통과 (문법 에러 없음)

### shellcheck 검사

```bash
$ shellcheck /home/jhw/ai/opencode/projects/pim-package/dist/pim/opt/pim/bin/chk_cam_operate.sh
```

**결과**: shellcheck가 설치되지 않음

---

## 종합 최적화 효과 예상

| 최적화 항목 | df 호출 횟수 | 스캔 횟수 | 예상 CPU 감소 |
| :--- | :--- | :--- | :--- |
| **우선순위 1** (df 간격화) | **80% 감소** | 그대로 | ~60% |
| **우선순위 2** (캐싱) | 그대로 | **90% 감소** | ~80% |
| **우선순위 3** (tail 업데이트) | 그대로 | **99% 감소** | ~95% |
| **우선순위 4** (조건부 호출) | 그대로 | **최적화됨** | 추가 감소 |
| **모두 적용 시** | 80% 감소 | 99% 감소 | **~98%** |

---

## 테스트 권장 사항

### 1. 기능 테스트

1. **df 간격화**:
   - 디스크 사용량이 90% 이상인 상태에서 로그를 확인
   - df 체크가 5회 삭제마다 1회씩 호출되는지 확인

2. **캐싱**:
   - 10초 TTL 내에 두 번 호출 시 캐시가 사용되는지 확인
   - 세션 목록이 10초 후에 갱신되는지 확인

3. **tail 업데이트**:
   - 세션 삭제 시 재스캔 없이 목록이 갱신되는지 확인

4. **조건부 호출**:
   - all_done 파일이 없을 때 ProcessCompletedSessions가 호출되지 않는지 확인

### 2. 성능 테스트

1. **CPU 사용량 측정**:
   ```bash
   # 최적화 전
   top -b -n 1 | grep chk_cam_operate | awk '{print $9}'

   # 최적화 후
   top -b -n 1 | grep chk_cam_operate | awk '{print $9}'
   ```

2. **df 호출 횟수 측정**:
   ```bash
   # 로그에서 df 호출 로그 추출
   grep "get_df_usage_pct" /var/log/syslog | wc -l
   ```

---

## 롤백 계획

문제 발생 시 다음 명령으로 롤백:

```bash
# git 브랜치 확인
cd /home/jhw/ai/opencode/projects/pim-package
git status

# 롤백
git checkout HEAD -- chk_cam_operate.sh
```

---

## 참고 관련 문서

- [CPU 사용량 분석](cpu-usage-analysis.md)
- [로그 분석: CPU 급증 사례](cpu-spike-analysis.md)
- [세션 라이프사이클](session-lifecycle.md)

---

## 버전 정보

- **작성일**: 2026-02-06
- **기반 버전**: `chk_cam_operate.sh` (최적화 후)
- **적용된 최적화 수**: 4개
