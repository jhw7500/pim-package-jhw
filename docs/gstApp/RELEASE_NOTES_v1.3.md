# gstApp v1.3 릴리즈 노트

**릴리즈 날짜**: 2026-02-10
**플랫폼**: i.MX8MP (Linux, GStreamer 1.18.0+)
**기준 커밋**: `c0ac8df` (PR #3, request-queue-architecture)
**최신 커밋**: `79f84b5`
**변경 규모**: 23개 파일, +6,237줄 / -4,521줄 (PR #5 ~ #20)

---

## 주요 변경 사항 요약

v1.3은 **보안 취약점 전면 패치**, **녹화 동기화 시스템 재설계**, **V4L2 직접 제어 통합**, **CI/CD 자동화 구축**을 포함하는 대규모 업데이트입니다.

---

## 1. 보안 강화

### 1.1 커맨드 인젝션 제거 (Critical)
- `system()` 호출을 전량 제거하고 `execvp()`/`g_spawn_sync()` 등 안전한 대안으로 교체
- `popen()` 호출 제거
- i2c 명령 실행 및 mkdir 경로 검증 로직 추가

### 1.2 하드코딩된 AES 키 제거 (Critical)
- 소스 코드에 하드코딩되어 있던 AES 암호화 키를 외부 설정으로 분리

### 1.3 리소스 누수 수정
- tcpServer 소켓 자원 정리 로직 개선
- main.cpp, videoBin.cpp의 메모리 누수 및 null 체크 보완
- 16개 파일에 걸친 리소스 누수 전수 점검 및 수정

### 1.4 플랫폼 호환성
- `stat()` → `g_stat()` 교체로 GLIBC_2.33 의존성 제거 (구 버전 라이브러리 호환)

> **관련 PR**: #5 (`security/replace-system-calls`), #13 (`fix/security-patches`)

---

## 2. 녹화 동기화 시스템 재설계

### 2.1 세션 기반 녹화 구현
- GStreamer 1.18.0 호환 세션 기반 녹화 아키텍처 도입
- splitmuxsink의 fragment-closed 처리를 **별도 워커 스레드**로 오프로드하여 파이프라인 블로킹 방지

### 2.2 정각 정렬 및 분할 동기화
- 정확한 시간 일치(`==`) 방식에서 **목표 시간 도달 확인(`>=`)** 방식으로 전환
- 타이머 주기를 1초 → 500ms로 단축하여 정밀도 향상
- 59분→00분 전환 시 시간 역전 보정 로직 추가
- 다양한 녹화 주기(1, 2, 3, 5분)에 자동 대응

### 2.3 스마트 분할 보호
- 세션 시간 기반 스마트 분할 보호 메커니즘 구현
- 최소 분할 간격(`MIN_SPLIT_INTERVAL_SEC: 5초`) 보호
- 최대 드리프트 허용치(`MAX_SNAPBACK_DRIFT_MS: 30초`) 설정

### 2.4 분할 복구 (Snap-back)
- 00초 정각으로의 snap-back 복구 로직 구현
- 유예 기간(`SNAP_BACK_GRACE_PERIOD_MS: 58초`) 내 자동 복구

### 2.5 키프레임 동기화
- encoderBin에 키프레임 강제 삽입 기능 추가
- 분할 시점의 키프레임 정렬로 재생 호환성 보장
- 키프레임 동기화 과정에서 발생하던 Segfault 수정

### 2.6 녹화 통계 및 로깅
- fragment-opened 시점에 이전 녹화 세션의 통계 정보(파일명, 크기, 지속시간) 출력
- 조기 분할 정규화 및 드리프트 계산 개선

> **관련 PR**: #15 ~ #19 (`recording-sync-improvement`, `integrated-recording-logs`, `smart-split-protection`, `sync-stability-and-final-logic`, `early-split-normalization`)

---

## 3. V4L2 직접 제어 통합

### 3.1 GStreamer extra-controls → V4L2 ioctl 전환
- GStreamer의 extra-controls 속성 대신 **V4L2 subdev ioctl을 직접 호출**하는 방식으로 전환
- 카메라 컨트롤의 응답성 및 안정성 향상

### 3.2 듀얼 채널 per-channel 제어
- 듀얼 채널 모드에서 **채널별 독립적인** V4L2 컨트롤 적용
- subdev 매핑 오류 수정

### 3.3 새로운 V4L2 컨트롤
- `ae_on`: 자동 노출 on/off 제어
- `ext_time`: 외부 타임스탬프 제어

### 3.4 설정 파서 확장
- `v4l_map`: V4L2 subdev 매핑 설정
- `rtsp_tune`: RTSP 튜닝 파라미터 설정
- RTSP latency를 설정 파일에서 직접 제어 가능

> **관련 PR**: #12 (`feature/v4l2-controls-integration`)

---

## 4. PNG 캡처 시스템 개선

### 4.1 PNG 캡처 인코더
- 새로운 PNG 인코딩 파이프라인 추가
- 캡처 타이밍 안정화 (captureBin 대폭 확장)

### 4.2 버퍼드 캡처 강화
- 버퍼 기반 캡처 및 파일 쓰기의 안전성 강화
- 캡처 타임아웃 계산 로직 간소화

### 4.3 캡처 디렉토리 설정
- IPC를 통한 캡처 저장 경로 동적 설정 기능 추가

### 4.4 타임스탬프 디버깅
- RTSP/캡처 타임스탬프 로깅 추가
- CLI 타임스탬프 디버그 옵션 추가

> **관련 PR**: #10 (`feat/gstapp-updates`), #11 (`refactor/capture-timeout-cleanup`)

---

## 5. 성능 최적화

### 5.1 문자열 연산 최적화
- muxSinkBin의 `g_date_time_format` 호출을 **타임스탬프 캐싱**으로 대체
- 동일 초(Second) 내 멀티 채널 호출 시 캐시된 결과 재사용 (호출 횟수 1/4 절감)
- `g_strdup_printf` → `snprintf` + 정적 버퍼 전환

### 5.2 빌드 시스템
- Makefile 크로스 컴파일 안전성 개선
- 빌드 최적화 플래그 정비

> **관련 PR**: #20 (`feat/performance-plan-and-makefile-opt`)

---

## 6. 버그 수정

| 버그 | 설명 | PR |
|------|------|----|
| `search_file` 로직 오류 | 가장 최근 수정된 파일을 정확히 반환하도록 수정 (3회 반복 수정 후 확정) | #14 |
| gstApp 출력 충돌 | 동일 이름 바이너리 출력 파일 충돌 방지 | - |
| subdev 매핑 오류 | V4L2 subdev 노드 매핑 수정 | #12 |
| Segfault | 키프레임 동기화 중 발생하던 세그폴트 수정 | #17 |
| 메모리 누수 | main.cpp, videoBin.cpp 할당 해제 누락 수정 | #5 |
| 소켓 클린업 | tcpServer 소켓 자원 누수 수정 | #13 |

---

## 7. CI/CD 및 자동화

### 7.1 중앙집중 워크플로우 설정
- `workflow-config.yml` 기반 **토글 게이트 시스템** 도입
- 모든 워크플로우를 개별 on/off 제어 가능

### 7.2 AI 코드 리뷰 통합
- Claude Code Review 자동 리뷰 워크플로우
- Gemini 자동 리뷰/트리거/디스패치 워크플로우
- OpenCode 자동 PR 리뷰 워크플로우
- 자동 재리뷰 요청 워크플로우

### 7.3 보안 강화
- comment-driven 봇을 **조직 멤버 전용**으로 제한
- 외부 사용자의 워크플로우 트리거 차단

### 7.4 빌드 자동화
- ChatOps `/build` 명령으로 이슈 코멘트에서 빌드 트리거 가능
- gstApp 전용 빌드 테스트 워크플로우

### 7.5 레거시 정리
- 구형 Gemini 헬퍼(actions, commands) 6개 파일 삭제 (-628줄)
- shared workflow 기반으로 리팩토링하여 중복 제거

> **관련 PR**: #8 (`feat/workflow-improvements`), #9 (`chore/workflow-hardening-v1.22`)

---

## 호환성 정보

| 항목 | 값 |
|------|----|
| GStreamer | 1.18.0 이상 |
| 타겟 플랫폼 | i.MX8MP (NXP BSP) |
| 커널 | Linux 5.10.x |
| GLIBC | 2.31 이상 (2.33 의존성 제거됨) |

---

## 알려진 제한사항

- 성능 최적화 계획(버스 메시지 풀링, Zero-copy 경로 재검증)은 향후 버전에서 구현 예정
- `/dev/shm` 기반 프로세스 간 상태 공유 방식은 검토 단계

---

## 참고 문서

- [녹화 동기화 계획서](RECORDING_SYNC_PLAN.md)
- [성능 최적화 계획서](PERFORMANCE_OPTIMIZATION_PLAN.md)
- [splitmuxsink 기술 문서](SPLITMUXSINK.md)
- [캡처 최적화 문서](CAPTURE_OPTIMIZATIONS.md)
- [보안 노트](SECURITY-NOTES.md)
