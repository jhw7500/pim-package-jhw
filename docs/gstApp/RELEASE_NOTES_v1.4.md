# gstApp v1.4 릴리즈 노트

**릴리즈 날짜**: 2026-02-11
**플랫폼**: i.MX8MP (Linux, GStreamer 1.18.0+)
**기준 커밋**: `79f84b5` (v1.3)
**최신 커밋**: `67ae008`
**변경 규모**: 11개 파일, +164줄 / -265줄 (PR #21 ~ #22)

---

## 주요 변경 사항 요약

v1.4는 **파이프라인 저지연 최적화**, **오브젝트 풀링**, **버스 메시지 필터링**, **그레이스풀 셧다운**을 포함하는 성능 중심 업데이트입니다. main.cpp에서 200줄의 레거시 코드를 제거하고 최적화된 구조로 교체했습니다.

---

## 1. 파이프라인 큐 저지연 튜닝

### 1.1 큐 사이즈 최적화
- `max-size-time`을 300~500ms에서 **100~200ms**로 축소
- `max-size-buffers`를 **3~5 프레임**으로 제한하여 메모리 풋프린트 최소화
- `leaky=downstream` 활성화로 부하 시에도 실시간 응답성 보장

### 1.2 시간 기반 큐 사이징
- FPS에 따라 큐 크기를 자동 계산하여 모든 프레임레이트에서 일관된 지연 보장
- JSON 설정으로 `queue_tune` 파라미터 지원 (main, enc, rec, cap)

### 1.3 적용 범위
- videoBin, encoderBin, recordBin, captureBin 전체 파이프라인에 적용

> **관련 PR**: #22 (`feat/queue-tuning-and-low-latency`)

---

## 2. 오브젝트 풀링 및 버스 메시지 필터링

### 2.1 FragmentClosedEvent 오브젝트 풀
- 힙 할당/해제 반복(heap churn) 제거를 위한 이벤트 오브젝트 풀 도입
- 워커 스레드에서 풀링된 이벤트 오브젝트 재사용

### 2.2 버스 메시지 필터링
- 고빈도 버스 메시지(QOS, TAG 등) 필터링으로 불필요한 처리 제거
- main.cpp에서 **200줄 레거시 코드 제거**, 42줄 최적화 코드로 교체

> **관련 PR**: #21 (`feat/string-and-timestamp-optimization`)

---

## 3. 문자열 연산 안전성 강화

### 3.1 Mutex 범위 최소화
- 무거운 I/O 및 문자열 연산을 Mutex 보호 범위에서 제외

### 3.2 안전한 문자열 복사
- `g_strlcpy` 사용으로 버퍼 오버플로 방지

### 3.3 안전한 파일 쓰기
- `O_TRUNC` 제거, `ftruncate` + 파일 잠금 사용
- 절단된 경로에 대한 폴백 로직 추가

### 3.4 마커 채널 로직
- 임의의 활성 채널 조합을 지원하는 `marker_channel` 로직 추가

> **관련 PR**: #21 (`feat/string-and-timestamp-optimization`)

---

## 4. 그레이스풀 셧다운

- `SIGTERM` 핸들러 추가로 `kill_test.sh` 실행 시 안전한 종료
- 파이프라인 리소스 정리 후 종료 보장

---

## 5. 설정 확장

- `queue_tune` JSON 설정 추가: main, enc, rec, cap 큐 파라미터 독립 제어
- parser.cpp/parser.h에 새로운 파싱 로직 추가

---

## 호환성 정보

| 항목 | 값 |
|------|----|
| GStreamer | 1.18.0 이상 |
| 타겟 플랫폼 | i.MX8MP (NXP BSP) |
| 커널 | Linux 5.10.x |
| GLIBC | 2.31 이상 |

---

## 참고 문서

- [성능 최적화 계획서](PERFORMANCE_OPTIMIZATION_PLAN.md) (완료 상태로 업데이트)
- [v1.3 릴리즈 노트](RELEASE_NOTES_v1.3.md)
