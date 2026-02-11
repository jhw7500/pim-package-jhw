# chk_cam_operate.sh CPU 사용량 높은 원인 분석

## 개요

`chk_cam_operate.sh` 데몬이 실행될 때 CPU 소모량이 상당히 높은 원인을 분석하고, 최적화 방안을 제안합니다.

---

## 1. 핵심 문제: 메인 루프에서의 빈번한 파일 시스템 연산

### 1.1 ProcessCompletedSessions (세션 완료 마커가 있을 때만 실행)

**코드 위치**: `chk_cam_operate.sh`의 메인 루프 + `ProcessCompletedSessions`

| 연산 | 라인 | 빈도 | 문제점 |
| :--- | :--- | :--- | :--- |
| **Glob 확장** `for done_file in /tmp/session_*.all_done` |  | 조건부 | 세션 완료 마커가 있을 때만 스캔 |
| **Glob 확장** `"$scan_dir"/*"${timestamp}"*.{part,mp4,ts,srt}` | 409-412 | 세션별 | `timestamp` 파일 4개씩 glob 확장 |
| **compgen -G** | 742, 758, 774, 790, 803 | 파일 생성 체크 시 | 채널별 패턴 매칭 (최대 5번) |
| **sync -f** | 151, 154, 431 | 파일 처리 후 | 디스크 flush는 비싼 연산 |

**특히 심각한 부분**:
```bash
# 742-795행: 파일 생성 체크 - 각 채널별로 compgen -G 실행
if [[ "$cam_ch0" == *"$ENABLE_VAL"* ]]; then
    if [ -f "${tmp_path}/${vhl_name}_${datetime}-ch0.${muxer}" ]; then
        # ... 로깅
    elif compgen -G "${tmp_path}/*${vhl_name}_${datetime_}*ch0*" > /dev/null; then
        # ... 로깅
    fi
fi
# cam_ch1, cam_ch2, cam_ch3, srt에 대해 반복
```

### 1.2 CleanupStalePartFiles (매 30초마다 실행)

**코드 위치**: 932행, 454-581행

| 연산 | 라인 | 빈도 | 문제점 |
| :--- | :--- | :--- | :--- |
| **Glob 확장** `for f in "$scan_dir"/*.part` | 496 | 매 30초 | 모든 .part 파일에 대해 glob |
| **Glob 확장** `for part_file in "$scan_dir"/*.part` | 508 | 매 30초 | 동일한 파일에 대해 또 glob |
| **stat -c %s** | 511 | 각 .part마다 | 파일 메타데이터 조회 (I/O 연산) |
| **state_file 읽기/쓰기** | 485-490, 572-576 | 매 30초 | 파일 I/O + 배열 순회 (573-575) |

**중복 스캔 문제**:
```bash
# 494-502행: recent_sessions 구성 - 첫 번째 스캔
recent_sessions=$(for scan_dir in "${scan_dirs[@]}"; do
    for f in "$scan_dir"/*.part; do
        sid=$(extract_session_id_from_filename "$base")
        printf '%s\n' "$sid"
    done
done | sort -u)

# 506-569행: 실제 Stale 체크 - 두 번째 스캔 (같은 파일들)
for scan_dir in "${scan_dirs[@]}"; do
    for part_file in "$scan_dir"/*.part; do
        size=$(stat -c %s "$part_file" 2>/dev/null)  # 각 파일마다 stat
```

### 1.3 CheckDiskSpace (매 30초마다 실행)

**코드 위치**: 933행, 584-600행

| 연산 | 라인 | 빈도 | 문제점 |
| :--- | :--- | :--- | :--- |
| **df -P** | 261, 592, 272, 292 | 디스크 체크 시 | 파일 시스템 stat |
| **du -sb** | 333, 344, 357 | RAM cap 체크 시 | **모든 파일 순회하며 크기 합산** (매우 비쌈) |
| **Glob 확장** `for f in "$dir"/*` | 229-238 | 세션 목록 작성 | 디렉토리 전체 스캔 |
| **list_sessions_in_dir_sorted** | 285, 308, 352, 372 | 반복적으로 호출 | 매번 디렉토리 전체 스캔 + sort |

**특히 심각한 부분**:
```bash
# 344-358행: RAM cap enforcement - du -sb 실행
size=$(get_dir_size_bytes "$target_dir")  # du -sb "$dir" - 전체 파일 순회
sessions=$(list_sessions_in_dir_sorted "$target_dir")  # 디렉토리 스캔 + sort
while :; do
    size=$(get_dir_size_bytes "$target_dir")  # 또 du -sb 실행
    # ...
    sessions=$(list_sessions_in_dir_sorted "$target_dir")  # 또 스캔 + sort
done
```

### 1.4 메인 루프 (매 2초마다 실행)

**코드 위치**: 684-938행

| 연산 | 라인 | 빈도 | 문제점 |
| :--- | :--- | :--- | :--- |
| **cat** 파일 읽기 | 609, 722 | 매 2초 | `/tmp/start_video_time_chk` 읽기 |
| **date** 명령 | 727-728 | 매 2초 (파일 체크 시) | epoch 변환, 날짜 포맷팅 |
| **date -d** | 735-736 | 파일 생성 체크 시 | 날짜 변환 (2번 호출) |
| **sync** | 830 | 파일 체크 후 | 전체 파일 시스템 flush |

---

## 2. 구조적 문제 요약

### 문제 1: 불필요한 빈도의 glob 확장
- **ProcessCompletedSessions**: 매 2초마다 실행
- **CleanupStalePartFiles**: 30초마다 실행되지만, 동일한 `.part` 파일에 대해 **두 번 glob 확장** (496행, 508행)

### 문제 2: 중복된 디렉토리 스캔
- `list_sessions_in_dir_sorted` 함수가 `enforce_sd_retention_if_needed`, `enforce_ram_cap_if_needed` 내에서 반복 호출
- 각 호출마다 디렉토리 전체 스캔 + sort + uniq

### 문제 3: du -sb 사용 (가장 심각)
- `get_dir_size_bytes` 함수가 `du -sb "$dir"`를 호출
- 디렉토리 내 **모든 파일을 순회**하며 크기 합산
- `enforce_ram_cap_if_needed`의 while 루프 내에서 **반복 호출**

### 문제 4: stat 호출 빈도
- `CleanupStalePartFiles`에서 각 `.part` 파일마다 `stat -c %s` 실행
- 상태 파일의 모든 파일에 대해 매번 stat

### 문제 5: ProcessCompletedSessions 무조건 실행 (과거 버전)
- 과거에는 `ProcessCompletedSessions`가 루프 조건 없이 매번 호출되어 `/tmp` 스캔이 불필요하게 반복될 수 있었습니다.
- 현재는 `session_*.all_done` 파일이 존재할 때만 호출하도록 조건이 추가되어, 불필요한 스캔 빈도가 감소합니다.

---

## 3. 파일 수에 따른 CPU 부하 예측

| 파일 수 | ProcessCompletedSessions (2초) | CleanupStalePartFiles (30초) | CheckDiskSpace (30초) |
| :--- | :--- | :--- | :--- |
| **10개** | 매우 낮음 | stat 10회 + du 1회 | du 1회 + 디렉토리 스캔 |
| **50개** | 낮음 | stat 50회 + du 1회 | du 1회 + 디렉토리 스캔 |
| **200개** | 보통 | stat 200회 + du 1회 | du 1회 + 디렉토리 스캔 |
| **500개** | 높음 | stat 500회 + du 1회 | du 1회 + 디렉토리 스캔 |

**du -sb는 파일 수에 비례하여 선형적으로 CPU 소모**

---

## 4. 최적화 제안

### 우선순위 1: du -sb 대체
- **현재**: `du -sb "$dir"` - 매번 전체 파일 순회
- **개선**: 파일 삭제 시 디렉토리 크기 변수 업데이트
  - 삭제 전: `current_size -= deleted_file_size`
  - 파일 생성 시: `current_size += new_file_size`
- **효과**: O(n) → O(1)로 감소
- **코드 변경**: `get_dir_size_bytes` 대신 추적 변수 사용

### 우선순위 2: ProcessCompletedSessions 호출 조건 추가
- **현재**: 매 2초마다 무조건 호출
- **개선**: `/tmp/session_*.all_done` 파일이 존재하는지 먼저 체크
  ```bash
  if compgen -G '/tmp/session_*.all_done' > /dev/null; then
      ProcessCompletedSessions
  fi
  ```
- **효과**: 불필요한 glob 확장 최소화

### 우선순위 3: CleanupStalePartFiles 중복 스캔 제거
- **현재**: `recent_sessions` 구성(496행) + 실제 처리(508행)에서 동일한 `.part` 파일 스캔
- **개선**: 첫 번째 스캔에서 파일 목록을 배열에 저장 후 재사용
  ```bash
  local part_files=()
  for scan_dir in "${scan_dirs[@]}"; do
      while IFS= read -r -d '' f; do
          part_files+=("$f")
      done < <(find "$scan_dir" -maxdepth 1 -name "*.part" -print0)
  done
  # part_files 배열 재사용
  ```
- **효과**: glob 확장 횟수 절반으로 감소

### 우선순위 4: list_sessions_in_dir_sorted 캐싱
- **현재**: 호출될 때마다 디렉토리 전체 스캔
- **개선**: 30초 캐싱 (함수 내부에서 마지막 스캔 시간 기록)
  ```bash
  declare -g _SESSIONS_CACHE_TIME=0
  declare -g _SESSIONS_CACHE_RESULT=""

  list_sessions_in_dir_sorted() {
      local dir="$1"
      local now=$(date +%s)
      if [ $((now - _SESSIONS_CACHE_TIME)) -lt 30 ]; then
          printf '%s' "$_SESSIONS_CACHE_RESULT"
          return
      fi
      # ... 스캔 및 캐시 업데이트
  }
  ```
- **효과**: CheckDiskSpace 루프 내 중복 스캔 제거

### 우선순위 5: stat 호출 줄이기
- **현재**: 각 `.part`마다 stat 실행
- **개선**: `find` + `stat` 한 번에 메타데이터 조회
  ```bash
  find "$scan_dir" -maxdepth 1 -name "*.part" -printf '%s\t%p\n'
  ```
- **효과**: 시스템 콜 횟수 감소

### 우선순위 6: 메인 루프 주기 조정
- **현재**: 매 2초마다 ProcessCompletedSessions 호출
- **개선**: 주기를 5초로 조정 (경험치)
  ```bash
  sleep 5
  ((timer+=5))
  ```
- **효과**: 파일 시스템 연산 빈도 60% 감소

---

## 5. 최적화 우선순위 요약

| 순위 | 항목 | 예상 효과 | 구현 난이도 |
| :--- | :--- | :--- | :--- |
| **1** | du -sb 대체 | O(n) → O(1) 감소, 파일 수에 비례한 CPU 감소 | 낮음 |
| **2** | ProcessCompletedSessions 조건부 호출 | 불필요한 glob 확장 제거 | 매우 낮음 |
| **3** | CleanupStalePartFiles 중복 제거 | 스캔 횟수 50% 감소 | 보통 |
| **4** | 세션 목록 캐싱 | 중복 스캔 제거 | 보통 |
| **5** | stat 호출 줄이기 | 시스템 콜 감소 | 낮음 |
| **6** | 루프 주기 조정 | 연산 빈도 60% 감소 | 매우 낮음 |

---

## 6. 구현 예시

### 예시 1: du -sb 대체 (우선순위 1)

```bash
# 디렉토리 크기 추적 변수 추가
declare -g _RAM_ONLY_DIR_SIZE=0

# 파일 삭제/이동 시 크기 업데이트
delete_session_in_dir() {
    local dir="$1"
    local sid="$2"
    local file_size

    [ -d "$dir" ] || return 0

    # 파일 삭제 전에 크기 계산
    for f in "$dir"/*"${sid}"??-ch*.mp4 \
              "$dir"/*"${sid}"??-ch*.ts \
              "$dir"/*"${sid}"*.srt; do
        [ -f "$f" ] || continue
        file_size=$(stat -c %s "$f" 2>/dev/null)
        [ -n "$file_size" ] && _RAM_ONLY_DIR_SIZE=$((_RAM_ONLY_DIR_SIZE - file_size))
    done

    # 파일 삭제
    rm -f "$dir"/*"${sid}"??-ch*.mp4 2>/dev/null
    rm -f "$dir"/*"${sid}"??-ch*.ts 2>/dev/null
    rm -f "$dir"/*"${sid}"*.srt 2>/dev/null
}

enforce_ram_cap_if_needed() {
    local target_dir="$final_path"
    local cap_bytes=${RAM_CAP_BYTES:-$RAM_CAP_BYTES_DEFAULT}

    # du 대신 추적 변수 사용
    if [ "$_RAM_ONLY_DIR_SIZE" -le "$cap_bytes" ]; then
        return 0
    fi

    # ... 세션 삭제 로직 (delete_session_in_dir 호출)
}

# MovePartFile에서 크기 업데이트
MovePartFile() {
    # ... 기존 로직

    if [ "$scan_dir" = "$tmp_dir" ] && [ "$part_dir" = "$tmp_dir" ]; then
        # Stage 1 복사
        file_size=$(stat -c %s "$part_file" 2>/dev/null)
        [ "$final_dir" = "$RAM_ONLY_FINAL_PATH_DEFAULT" ] && \
            _RAM_ONLY_DIR_SIZE=$((_RAM_ONLY_DIR_SIZE + file_size))
    fi

    # ...
}
```

### 예시 2: ProcessCompletedSessions 조건부 호출 (우선순위 2)

```bash
while :
do
    # ... 기존 로직

    # === 완료된 세션 처리 (조건부) ===
    if compgen -G '/tmp/session_*.all_done' > /dev/null 2>&1; then
        ProcessCompletedSessions
    fi

    # ... 나머지 로직

    sleep 2
    ((timer+=2))
done
```

---

## 7. 참고 파일 경로 및 라인 번호

| 기능 | 파일 | 라인 |
| :--- | :--- | :--- |
| **메인 루프** | `chk_cam_operate.sh` | 684-938 |
| **ProcessCompletedSessions** | `chk_cam_operate.sh` | 377-450 |
| **CleanupStalePartFiles** | `chk_cam_operate.sh` | 454-581 |
| **CheckDiskSpace** | `chk_cam_operate.sh` | 584-600 |
| **MovePartFile** | `chk_cam_operate.sh` | 115-175 |
| **get_dir_size_bytes** | `chk_cam_operate.sh` | 332-335 |
| **list_sessions_in_dir_sorted** | `chk_cam_operate.sh` | 223-243 |
| **delete_session_in_dir** | `chk_cam_operate.sh` | 245-257 |
| **enforce_sd_retention_if_needed** | `chk_cam_operate.sh` | 264-310 |
| **enforce_ram_cap_if_needed** | `chk_cam_operate.sh` | 337-375 |

---

## 8. 버전 정보

- **작성일**: 2026-02-06
- **기반 버전**: `chk_cam_operate.sh` (943 lines)
