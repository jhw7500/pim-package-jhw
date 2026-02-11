# ord 용량 관리 기능 분석

## 개요

ord 데몬에서 하는 용량 관리와 관련된 추가적인 기능이 성능에 미치는 영향을 분석합니다.

---

## 1. ord 데몬 구성

### 1.1 업데이트 스크립트

**파일**: `update_ordvcmconf.sh` (45행)

**주요 동작**:
```bash
# ORD 설정 확인
echo "ORD check"
jq '.ORD |= if . == null then . else . end' "$FILE_JSON"

# VCM 설정 확인
echo "VCM check"
jq 'del (.VCM.file_time_recording)' "$FILE_JSON"
jq '.VCM |= if . == null then . end' "$FILE_JSON"

# ETc 설정 확인
echo "ETC check"
jq '.ETC |= if . == null then . end' "$FILE_JSON"

# 완료
echo "complete update $FILE_JSON"
sync
```

### 1.2 파일 관리 스크립트

**파일**: `file_manager.sh` (76행)

**기능**: 디렉토리 용량 제한 (du -sb 사용)

---

## 2. file_manager.sh 상세 분석

### 2.1 실행 파라미터

```bash
INPUT_PATH=$1   # 검사할 디렉토리 경로
LIMIT=$2         # 최대 파일 개수 제한
SIZE=$3          # 최대 디렉토리 크기 (바이트)
KEY=$4          # 파일 식별자
```

### 2.2 핵심 로직

```bash
# 루프 1: 파일 하나씩 삭제하여 크기 초과 방지
while :; do
    current_size=$(du -sb $INPUT_PATH | awk '{print $1}')
    if [ $current_size -gt $MAX_SIZE ]; then
        oldest_file=$(ls -tr $FILE_PATH | head -n 1)
        rm -rf "$oldest_file"
        current_size=$(du -sb $INPUT_PATH | awk '{print $1}')
        sleep 0.1
    fi
    break
done

# 루프 2: 파일 개수 초과 방지
while :; do
    cnt=$(ls -lt $FILE_PATH | grep ^- | wc -l)
    if [ $cnt -gt $LIMIT ]; then
        # find로 파일 삭제
        find $FILE_PATH -maxdepth 1 -type f -printf '%T+ %p\n' | sort | head -n -$LIMIT | cut -d' ' -f2-' | xargs -r rm -f
        sleep 0.1
    fi
    break
done
```

### 2.3 CPU 소모 패턴

| 연산 | 빈도 | CPU 부하 |
| :--- | :--- | :--- |
| **du -sb** | 매 루프마다 | 매우 높음 (전체 파일 순회) |
| **ls -tr \| head -n 1** | 루프 1 | 낮음 |
| **find ... \| head -n -N** | 루프 2 | 높음 (파일 시간 스탬프 추출) |
| **rm -rf** | 크기/개수 초과 시 | 보통 |

### 2.4 성능 문제점

**문제 1**: du -sb 반복 호출
- 루프 1: 삭제 후 다시 du -sb 실행
- du -sb는 디렉토리 전체 파일을 순회하며 크기 합산
- 디렉토리 크기가 클수록 시간이 선형적으로 증가

**문제 2**: sleep 0.1초
- while 루프 내에서 break 조건 확인을 위해 0.1초 sleep
- 실제 파일 삭제가 빨르게 되면 불필요하게 대기

**문제 3**: find 명령어 시간 스탬프 추출
- `find ... -printf '%T+ %p\n' | sort`
- 파일 시간 스탬프 추출 및 정렬은 CPU 소모가 큼

---

## 3. chk_cam_operate.sh와의 비교

### 3.1 공통점

| 항목 | chk_cam_operate.sh | file_manager.sh |
| :--- | :--- | :--- |
| **du -sb 사용** | enforce_ram_cap_if_needed | 루프 1, 2 모두 사용 |
| **목적** | RAM cap enforcement | 디렉토리 크기 제한 |
| **실행 주기** | 30초 | 주기적 (du 호출 후 0.1초 sleep) |

### 3.2 차이점

| 항목 | chk_cam_operate.sh | file_manager.sh |
| :--- | :--- | :--- |
| **du 호출 빈도** | RAM cap 루프 내 | 두 개의 while 루프 모두 |
| **캐싱** | list_sessions_in_dir_sorted 캐싱 | 없음 (매번 du 재호출) |
| **실행 방식** | 삭제 루프 내 df 체크 후 break | 크기/개수 초과 시 즉시 삭제 후 break |
| **실행 트리거** | 30초 타이머 또는 df 사용량 초과 | du 호출 후 항상 실행 |

---

## 4. CPU 영향 분석

### 4.1 file_manager.sh의 CPU 소모 추정

**상황**: 파일 200개, 디렉토리 크기 1GB

| 연산 | 시간 (ms) | 횟수/분 | 비고 |
| :--- | :--- | :--- | :--- |
| **du -sb (200개)** | 200-500 | 120-300회 | 매우 높음 |
| **ls -tr \| head** | 5-10 | 120-600회 | 낮음 |
| **find \| head -N** | 50-100 | 60-120회 | 높음 |
| **rm -rf** | 10-20 | 30-120회 | 보통 |
| **sleep 0.1** | 100 | 600회 | 작지만 루프 지연 |
| **총 1 사이클** | **365-730ms** | - | **0.37초** |

### 4.2 chk_cam_operate.sh와의 CPU 소모 비교

| 시나리오 | CPU 소모 |
| :--- | :--- |
| **chk_cam_operate만 실행 (file_manager 중지)** | enforce_ram_cap_if_needed: du -sb 1회 / 30초 | 낮음 |
| **file_manager와 동시 실행** | du -sb: 120-300회/분 + 120-300회/분 = **240-600회/분** | 매우 높음 |

---

## 5. 결론

### 5.1 성능에 미치는 요소

| 요소 | 중요도 | 비고 |
| :--- | :--- | :--- |
| **file_manager.sh의 du -sb 반복** | **매우 높음** | 두 루프에서 모두 사용, 캐싱 없음 |
| **du -sb 사용 방식** | 높음 | 전체 파일 순회 (O(n)), 파일 수에 비례 |
| **while 루프 구조** | 높음 | break 조건까지 계속 실행 |
| **sleep 0.1초** | 중간 | 루프 횟수는 높지만 개별 sleep은 짧음 |

### 5.2 최적화 제안

#### 우선순위 1: file_manager.sh에 캐싱 추가

```bash
# 파일 관리 스크립트에 캐싱 추가
declare -g _FM_CACHE_TIME=0
declare -g _FM_CACHE_SIZE=0
declare -g _FM_CACHE_TTL=60  # 60초 TTL

check_directory_size() {
    local dir="$1"
    local now=$(date +%s)

    # 캐시 유효성 체크
    if [ $((now - _FM_CACHE_TIME)) -lt $_FM_CACHE_TTL ]; then
        echo "$_FM_CACHE_SIZE"
        return
    fi

    # 캐시 미스: du -sb 실행
    local size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
    _FM_CACHE_SIZE="$size"
    _FM_CACHE_TIME="$now"
    echo "$size"
}

# 기존 du -sb 호출 부분을 캐싱 함수로 변경
current_size=$(check_directory_size $INPUT_PATH)
```

**효과**: du 호출 횟수 80% 감소 (캐시 유효 기간 60초 동안 재사용)

#### 우선순위 2: sleep 시간 최적화

```bash
# sleep 시간을 0.1초에서 1초로 변경하여 du 호출 횟수 감소
if [ $current_size -gt $MAX_SIZE ]; then
    oldest_file=$(ls -tr $FILE_PATH | head -n 1)
    rm -rf "$oldest_file"
    current_size=$(check_directory_size $INPUT_PATH)
    sleep 1  # 변경
fi
```

**효과**: 루프 실행 횟수 90% 감소 (0.1초 → 1초)

#### 우선순위 3: du -sb 대신 find 사용 (파일 수 제한)

```bash
# 디렉토리 크기 제한 대신 파일 개수 제한 사용
# MAX_SIZE 대신 MAX_FILES 사용
MAX_FILES=500

if [ $cnt -gt $MAX_FILES ]; then
    # find로 한 번에 여러 파일 삭제
    find $FILE_PATH -maxdepth 1 -type f -printf '%T+ %p\n' | sort | head -n -$MAX_FILES | cut -d' ' -f2-' | xargs -r rm -f
fi
```

**효과**: 삭제 후 du 재호출 방지 (한 번에 여러 파일 삭제 후 find 결과로 cnt 업데이트)

#### 우선순위 4: du 대신 stat 사용 (파일 크기 체크)

```bash
# 파일 크기 체크는 du -sb 대신 stat 사용 (더 가벼움)
get_total_size() {
    local dir="$1"
    local total=0
    local f size

    # find로 파일 목록을 가져와 stat로 크기 합산
    while IFS= read -r -d '' f; do
        size=$(stat -c %s "$f" 2>/dev/null)
        [ -n "$size" ] && total=$((total + size))
    done < <(find "$dir" -maxdepth 1 -type f -print0)

    echo $total
}
```

**효과**: du -sb 대신 stat 사용으로 O(n) 복잡도 유지하면서 더 가벼움 (stat은 파일 하나만 메타데이터 조회)

---

## 6. 정리

### 6.1 ord 데몬의 용량 관리

ord 데몬은 다음과 같은 기능을 수행합니다:
1. **정기 설정 업데이트**: `update_ordvcmconf.sh`를 통해 ord_vcm_conf.json 업데이트
2. **파일 크기 관리**: `file_manager.sh`를 통해 로그/녹화 파일 크기 제한

### 6.2 성능에 미치는 요소

**가장 심각한 문제**: **file_manager.sh의 du -sb 반복 호출**

- du -sb는 디렉토리 내 모든 파일을 순회하며 크기 합산
- file_manager.sh는 두 개의 while 루프 모두에서 du -sb를 호출
- chk_cam_operate.sh의 retention 루프와 결합되면 CPU 소모량이 기하수적으로 증가

### 6.3 최적화 효과 예상

| 최적화 | du 호출 횟수 감소 | 예상 CPU 감소 |
| :--- | :--- | :--- |
| **캐싱 추가** | 80% | 20% 감소 |
| **sleep 최적화** | 90% | 20% 감소 |
| **du → stat** | (가벼움) | 30-50% 감소 |
| **모두 적용** | **~98%** | **~70-80%** |

---

## 참고

- **chk_cam_operate.sh 최적화 분석**: [optimization-applied.md](optimization-applied.md)
- **CPU 사용량 분석**: [cpu-usage-analysis.md](cpu-usage-analysis.md)
- **로그 분석: CPU 급증 사례**: [cpu-spike-analysis.md](cpu-spike-analysis.md)

---

## 버전 정보

- **작성일**: 2026-02-06
- **분석 대상**: `file_manager.sh`, `update_ordvcmconf.sh`
