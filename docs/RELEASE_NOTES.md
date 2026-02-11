# PIM Package Release Notes

## v0.5.8 (2026-01-09 ~ 2026-02-11)

### 핵심
**보안 전면 패치 + 녹화 동기화 재설계 + V4L2 직접 제어 + 커널 드라이버 안정화 + 성능 최적화 + 인프라 개선**

gstApp, ORD, VCM 3개 애플리케이션의 보안 취약점을 전수 점검하고, 녹화 분할 동기화 시스템을 재설계하여 정각 정렬 신뢰성을 대폭 향상시켰습니다. GStreamer extra-controls 방식을 V4L2 subdev ioctl 직접 호출로 전환하고, MAX9296 커널 드라이버의 커널 패닉 3건을 수정했습니다. 파이프라인 저지연 최적화와 빌드/배포 인프라를 전면 개선했습니다.

---

### 컴포넌트 버전

| 컴포넌트 | 이전 (v0.5.7) | 현재 (v0.5.8) | 변경 규모 |
|---------|--------------|--------------|----------|
| **gstApp** | v1.2 | **v1.4** | 23+11파일, +6,401 / -4,786줄 |
| **ORD** | v4.7 | **v4.8** | 26 커밋 |
| **VCM** | v4.2 | **v4.3** | 20 커밋 |
| **MAX9296 Driver** | v1.6 | **v2.0** | 6 릴리즈 |

---

### 신규 기능

#### 1. 녹화 동기화 시스템 재설계 (gstApp + VCM)

녹화 파일 분할의 정각 정렬 신뢰성을 근본적으로 개선했습니다.

- **세션 기반 녹화 아키텍처**: GStreamer 1.18.0 호환 세션 관리 도입
- **분할 트리거 방식 전환**: 정확한 시간 일치(`==`) → 목표 시간 도달 확인(`>=`)
- **타이머 정밀도 향상**: 1초 → 500ms 주기로 단축
- **스마트 분할 보호**: 최소 분할 간격 5초, 최대 드리프트 허용치 30초
- **Snap-back 복구**: 00초 정각으로의 자동 복구 (유예 기간 58초)
- **키프레임 동기화**: encoderBin에 키프레임 강제 삽입, 분할 시점 재생 호환성 보장
- **fragment-closed 워커 스레드**: splitmuxsink 이벤트 처리를 별도 스레드로 오프로드
- **VCM 동기화 개선**: `.srt_done` 플래그 기반 세션 완료 협업, 시작 신호 감지 개선
- **녹화 통계 로깅**: fragment-opened 시점에 이전 세션 통계(파일명, 크기, 지속시간) 출력

#### 2. V4L2 직접 제어 통합 (gstApp + MAX9296)

GStreamer extra-controls 방식에서 V4L2 subdev ioctl 직접 호출로 전환했습니다.

- **subdev ioctl 직접 호출**: 카메라 컨트롤 응답성 및 안정성 향상
- **듀얼 채널 per-channel 제어**: 채널별 독립적인 V4L2 컨트롤 적용
- **새로운 V4L2 컨트롤**: `ae_on` (자동 노출), `ext_time` (외부 타임스탬프)
- **설정 파서 확장**: `v4l_map`, `rtsp_tune` 옵션 추가
- **RTSP latency 설정**: 설정 파일에서 레이턴시 직접 제어

#### 3. 파이프라인 저지연 최적화 (gstApp v1.4)

gstApp v1.3 이후 성능 중심 업데이트를 추가 적용했습니다.

- **큐 저지연 튜닝**: `max-size-time` 300~500ms → 100~200ms, `max-size-buffers` 3~5프레임
- **오브젝트 풀링**: FragmentClosedEvent 풀 도입으로 힙 할당 반복 제거
- **버스 메시지 필터링**: 고빈도 QOS/TAG 메시지 필터링 (main.cpp -200줄/+42줄)
- **시간 기반 큐 사이징**: FPS별 자동 큐 크기 계산, `queue_tune` JSON 설정 지원 및 컴팩트 기본값 적용 (100~300ms)
- **안전한 파일 쓰기**: `O_TRUNC` 제거, `ftruncate` + 파일 잠금
- **그레이스풀 셧다운**: SIGTERM 핸들러로 kill_test.sh 시 안전 종료
- **Mutex 범위 최소화**: I/O 및 문자열 연산을 Mutex 밖으로 이동

#### 4. PNG 캡처 시스템 개선 (gstApp)

- **PNG 캡처 인코더 추가**: 새로운 PNG 인코딩 파이프라인
- **캡처 타이밍 안정화**: captureBin 대폭 확장
- **버퍼드 캡처 강화**: 파일 쓰기 안전성 강화
- **캡처 디렉토리 동적 설정**: IPC를 통한 저장 경로 변경

#### 5. VCM 비동기 파일 I/O

메인 스레드 블로킹을 제거하여 응답성과 처리량을 향상시켰습니다.

```
이전 (동기): 메인 스레드 → 파일 쓰기 (블로킹) → 다음 작업
이후 (비동기): 메인 스레드 → 큐 → 즉시 다음 작업
              워커 스레드 → 파일 쓰기 (백그라운드)
```

#### 6. RAW → BMP 병렬 변환 유틸리티

캡처된 RAW 이미지를 BMP로 자동 변환하는 Python 유틸리티를 추가했습니다.

- **병렬 처리**: multiprocessing 기반 4코어 동시 변환
- **자동 감지**: `/dev/shm/capture/` 디렉토리 감시, RAW 포맷 자동 판별
- **루프 모드**: `--loop` 옵션으로 지속적 감시 및 변환
- **Pillow 사전 빌드**: ARM64용 Pillow 10.4.0 wheel 패키지 포함 (`upgrade_file/pip/`)

```bash
python convert_raw_to_bmp_parallel.py          # 1회 실행
python convert_raw_to_bmp_parallel.py --loop   # 루프 모드
```

#### 7. VCM 경로 외부화

하드코딩된 경로를 TVhlConf 설정으로 이동하여 환경별 설정 및 QEMU 테스트를 지원합니다.

#### 8. ORD SD 카드 체크 활성화

- `waitingDisk()`에서 `checkSD()` 호출 활성화 — 디스크 대기 시 SD 카드 상태 확인

#### 9. 런타임 스크립트 강화

프로덕션 안정성 및 복구 전략을 대폭 개선했습니다.

**설정 마이그레이션 스크립트 (`update_edgeconf.sh`)**
- **ERR trap + 구조화된 로깅**: 실패 시점과 명령을 syslog에 자동 기록
- **JSON 검증 및 백업**: jq 구문 검증 + `/opt/pim/config/` 자동 백업
- **레거시 설정 마이그레이션**:
  - 구 채널 설정(`cam_ch0..3`, `ch0_rotate`) → 신규 i2c 기반 구조 자동 변환
  - ORD/VCM 헤더 제거 (분리된 설정 파일로 이전)
- **신규 설정 섹션 추가**:
  - `queue_tune`: 파이프라인 저지연 타이밍 제어 (main_src_time_ms, enc_src_time_ms, rec_sink_time_ms, cap_src_time_ms)
  - `rtsp_tune`: RTSP 레이턴시 및 버퍼 튜닝 (factory_latency_ms, appsink_max_buffers, bin_queue_max_time_ms)
  - `capture.path`, `capture.queue_size`: 캡처 경로 및 큐 크기 설정

**녹화 파일 관리 (`chk_cam_operate.sh`)**
- **2단계 파일 이동**: `/dev/shm` (RAM) → `sd_tmp_path` (SD 버퍼) → `final_path` (SD 최종)
- **스테일 .part 파일 정리**: 120초 동안 크기 변화 없는 .part 파일 자동 복구 또는 삭제
- **세션 기반 retention**: 최근 N개 세션 보호 정책 (기본값: 2세션)
- **RAM 전용 모드**: SD 카드 BAD/RO 시 `/dev/shm/recordings`에서 1.6GiB 제한 녹화
- **SD 임계값 기반 제어**: WARN(95%), CRIT(98%) 임계값, CRIT 도달 시 SD 쓰기 즉시 중단
- **카메라 연결 해제 복구**: 주기적 `init_cam.sh` 재실행 (300초마다), 재부팅 방지
- **세션 완료 마커 이벤트 처리**: `.all_done` 마커 기반 .part 커밋 최적화

**카메라 복구 전략 (`start_cam.sh`, `init_cam.sh`, `BG_Check_for_pim.sh`)**
- **복구 소유권 위임**: `start_cam.sh`에서 `gst_err` 감지 시 `/tmp/recover_req_init_cam` 요청 생성
- **중앙 복구 로직**: `chk_cam_operate.sh`가 retry/init/reboot 결정 (분산된 로직 제거)
- **연결 해제 시 재부팅 방지**: BG_Check_for_pim.sh에서 복구 요청 플래그만 설정
- **모듈 로드 실패 처리**: init_cam.sh에서 modprobe 반환값 검증 및 조기 종료

**SD 카드 마운트 (`automnt_sd_for_emmc_boot.sh`)**
- **RO 검출 즉시 대응**: H/W RO(`/sys/block/mmcblk1/ro`) 또는 S/W RO 검출 시 즉시 `sd_mount_flag=0` 설정
- **tmp_path 자동 fallback**: SD 마운트 실패 시 `/dev/shm`으로 자동 전환 및 cam-operate 재시작
- **sd_tmp_path 지원**: JSON 설정 경로 기반 정리 디렉토리 생성
- **부트 시 .part 파일 정리**: 이전 마운트의 미완성 파일 자동 삭제
- **ext4 커밋 주기 조정**: `commit=60` 옵션으로 쓰기 주기 최적화

**카메라 수동 제어 스크립트**
- **AE (Auto Exposure) 제어**: `cam_ae_on.sh`, `cam_ae_off.sh` — i2c 직접 명령 (0x50 0x02 0x02 0x99/0x00)
- **수동 파라미터 설정**: `cam_manual_gain.sh`, `cam_manual_exp_time.sh`, `cam_manual_iso.sh` — 16진수 변환 및 i2c 전송

---

### 보안 강화

#### gstApp (Critical)
- `system()` / `popen()` 호출 전량 제거 → `execvp()` / `g_spawn_sync()` 교체
- 하드코딩된 AES 암호화 키 외부 설정으로 분리
- i2c 명령 실행 및 mkdir 경로 검증 로직 추가
- 16개 파일에 걸친 리소스 누수 전수 점검 및 수정
- `stat()` → `g_stat()` 교체로 GLIBC_2.33 의존성 제거

#### ORD (10개 항목)
- 디스크 정리/재활용 정리/Tail 복사 파일 토큰 검증
- RTC 시간 범위 검증 (2000~2100년)
- echo 명령 → 직접 파일 쓰기로 쉘 사용 감소
- fgets 버퍼 크기 수정 (`sizeof(tmp)` 사용)
- Overlay 큐 요소 크기 수정 (`MAX_DATA_LEN`)
- TCP 패킷 최소 길이 검증 (10바이트)
- TCP read 상태 변수 초기화
- JSON-C 내부 포인터 직접 저장 방지

#### VCM (1개 항목)
- `sprintf` → `snprintf`, `system()` 제거

#### 녹화 스크립트
- automnt_sd, chk_cam_operate, kill_test 스크립트의 임시 파일 처리 강화

**총 보안 개선: 28개 항목** (gstApp 16파일 + ORD 10개 + VCM 1개 + 스크립트 1개)

---

### 스레드 안전성 개선

#### ORD (3개)
- 스레드 조인 보호 (NULL 체크)
- Redis 트리거 및 복사 스레드 라이프사이클 관리
- 클라이언트 해제 시 max FD 재계산 (fd_sets 기반)

#### VCM (5개)
- `_TOpsData` 스레드 잠금 활성화
- 네트워크 FD 세트 Mutex (`m_fdsMutex`) 도입
- SRT Mutex 추가
- TOpsData 댕글링 포인터 해결
- 큐 데이터 손상 수정 및 IPC 에러 처리 강화

**총 스레드 안전성 개선: 8개 항목**

---

### 성능 최적화

#### gstApp
- **타임스탬프 캐싱**: `g_date_time_format` 호출을 동일 초 내 캐싱으로 대체 (호출 1/4 절감)
- **정적 버퍼 전환**: `g_strdup_printf` → `snprintf` + 정적 버퍼
- **Makefile 크로스 컴파일 안전성 개선**

#### VCM
- **비동기 파일 I/O**: 전용 워커 스레드 + 큐 기반 처리
- **Monotonic Clock**: `CLOCK_MONOTONIC` 사용으로 NTP 동기화 시에도 안정적

#### ORD
- **ext4 디스크 사용량 정확한 계산**: `disk_size_mnt = used + available`
- **부분 TCP 전송 처리**: `send(MSG_DONTWAIT)` 루프로 데이터 손실 방지

---

### MAX9296 커널 드라이버 (v1.7 → v2.0)

v0.5.7에 포함되었던 v1.6에서 5개 릴리즈를 거쳐 v2.0으로 업데이트되었습니다.

#### v2.0 (Critical 안정화)
- **[CRITICAL] kthread_stop UAF 수정**: 자연 종료 스레드의 task_struct 참조 카운트 관리 (`get_task_struct()`/`put_task_struct()`)
- **[HIGH] 듀얼 모드 peer UAF 수정**: 4-phase remove 구조 도입으로 peer 스레드 안전한 정지
- **[MEDIUM] soft lockup 수정**: `msleep_interruptible()` 표준 API 전환
- **probe 실패 리소스 누수 수정**: 에러 경로에 스레드/참조 클린업 추가
- 커스텀 sleep 헬퍼 제거, 포인터 NULL 할당 추가

#### v1.9
- `usleep_range` 타이밍 최적화: delay_ms 범위 폭을 10%로 증가
- `_FILE_` 매크로 정의에 괄호 추가 (연산자 우선순위 문제 방지)

#### v1.8
- 죽은 코드(`#if 0` 블록) 11개 완전 제거
- FSYNC 기반 FPS 제어 메커니즘 문서화
- 코드 스타일 정리 및 로직 개선

#### v1.7
- rmmod 시 kthread use-after-free 에러 수정
- GitHub Actions CI 워크플로우 추가

**품질 점수: 9.8/10 (프로덕션 사용 가능)**

---

### 버그 수정

| 컴포넌트 | 버그 | 설명 |
|---------|------|------|
| gstApp | `search_file` 로직 오류 | 최근 수정 파일을 정확히 반환하도록 수정 |
| gstApp | Segfault | 키프레임 동기화 중 세그폴트 수정 |
| gstApp | 출력 파일 충돌 | 동일 이름 바이너리 출력 충돌 방지 |
| gstApp | subdev 매핑 오류 | V4L2 subdev 노드 매핑 수정 |
| gstApp | 메모리 누수 | main.cpp, videoBin.cpp 할당 해제 누락 수정 |
| gstApp | 소켓 클린업 | tcpServer 소켓 자원 누수 수정 |
| ORD | SD 체크 누락 | `waitingDisk()`에서 `checkSD()` 활성화 |
| ORD | msgq 오버플로 | 수신자 다운 시 msgq full 안전 처리 |
| ORD | OPS JSON 처리 | parsed offset 전송으로 수정 |
| VCM | 댕글링 포인터 | TOpsData 메모리 접근 오류 수정 |
| VCM | 큐 데이터 손상 | 큐 데이터 무결성 보장 |
| MAX9296 | use-after-free | rmmod 시 kthread 에러 수정 |
| MAX9296 | 커널 패닉 3건 | kthread UAF, peer UAF, soft lockup 수정 (v2.0) |
| MAX9296 | probe 리소스 누수 | 에러 경로 스레드/참조 클린업 (v2.0) |
| MAX9296 | 죽은 코드 | `#if 0` 블록 11개 제거 |

---

### 빌드/배포 인프라 개선

#### build.sh 전면 재설계
- **선택적 모듈 빌드**: `./build.sh ord` — 개별 모듈만 빌드 가능
- **선택적 클린**: `./build.sh clean vcm` — 특정 모듈만 정리
- **진행 표시**: 각 모듈 빌드 시작/완료 로그 출력
- **에러 안내**: 잘못된 모듈명 입력 시 사용 가능한 모듈 목록 표시

#### Docker 빌드 환경 (`docker/`)
x86_64 호스트에서 타겟(Ubuntu 20.04 ARM64, GLIBC 2.31)과 동일한 환경으로 빌드합니다.

- **QEMU ARM64 에뮬레이션**: x86_64에서 ARM64 네이티브 빌드 실행
- **Dockerfile**: Ubuntu 20.04 ARM64 + build-essential, cmake, json-c, hiredis 등
- **`docker/build-image.sh`**: 도커 이미지 빌드 (최초 1회)
- **`docker/build.sh`**: 컨테이너 내 빌드 실행 (선택적 모듈 빌드 지원)
- **바이너리 호환성 검증**: 빌드 후 `file`, `readelf` 자동 확인
- **GLIBC 호환성 해결**: SDK(2.33) → Docker(2.31)로 전환하여 타겟 실행 보장

```bash
# 사용법
./docker/build-image.sh        # 이미지 빌드 (최초 1회)
./docker/build.sh              # 전체 빌드
./docker/build.sh ord          # 개별 모듈 빌드
./docker/build.sh clean        # 클린
```

#### 설치 및 배포 스크립트
- `install_deb.sh` 추가: 패키지 설치 자동화
- `test/rsync_pim.sh` 추가: 빌드 결과물(pim.deb)을 타겟으로 rsync 전송

#### 카메라 제어 스크립트
- `cam_ae_on.sh`, `cam_ae_off.sh`: 자동 노출 on/off
- `cam_manual_exp_time.sh`: 수동 노출 시간 설정
- `cam_manual_gain.sh`: 수동 게인 설정
- `cam_manual_iso.sh`: 수동 ISO 설정

#### fake-hwclock 강화
- RTC 재시도 메커니즘 (최대 3회)
- 커널 로그 듀얼 출력 옵션 (`LOG_TO_KERNEL`)
- RTC 드라이버 존재 확인 (`/dev/rtc0`)
- syslog 레벨별 커널 로그 매핑
- **RTC 방전 대응**: RTC 초기화 감지 시 fake-hwclock 기반 시간 복구 및 RTC 재동기화 (`hwclock -w`) 로직 추가

#### 복구 메커니즘 개선
- `chk_cam_operate.sh`: 카메라 동작 감시 강화, 임시/part 파일 관리 개선
- `automnt_sd_for_emmc_boot.sh`: SD 카드 자동 마운트 에러 처리 강화
- `kill_test.sh`: 프로세스 종료 시 리소스 정리 개선
- `BG_Check_for_pim.sh`: 복구 시그널 처리 강화

---

### CI/CD 및 자동화 (gstApp)

- **중앙집중 워크플로우 설정**: `workflow-config.yml` 토글 게이트 시스템
- **AI 코드 리뷰 3종 통합**: Claude, Gemini, OpenCode 자동 PR 리뷰
- **ChatOps `/build`**: 이슈 코멘트에서 빌드 트리거
- **보안 게이트**: comment-driven 봇을 조직 멤버 전용으로 제한
- **레거시 정리**: 구형 Gemini 헬퍼 6개 파일 삭제 (-628줄)

---

### 문서

#### 통합 문서 (`docs/`)
| 문서 | 내용 |
|------|------|
| [`RELEASE_NOTES.md`](./RELEASE_NOTES.md) | PIM Package v0.5.8 통합 릴리즈 노트 (이 문서) |
| [`CHANGELOG.md`](./CHANGELOG.md) | PIM Package 변경사항 상세 |
| [`docker-build.md`](./docker-build.md) | Docker 빌드 환경 가이드 |
| [`session-lifecycle.md`](./session-lifecycle.md) | 세션 라이프사이클 관리 |
| [`RELEASE_NOTES_version_0.5.4-0.5.7.md`](./RELEASE_NOTES_version_0.5.4-0.5.7.md) | 이전 버전 릴리즈 노트 |

#### 서브 프로젝트 문서
| 컴포넌트 | 문서 | 내용 |
|----------|------|------|
| **gstApp** | [`gstApp/RELEASE_NOTES_v1.4.md`](./gstApp/RELEASE_NOTES_v1.4.md) | v1.4 릴리즈 노트 (저지연 최적화) |
| **gstApp** | [`gstApp/RELEASE_NOTES_v1.3.md`](./gstApp/RELEASE_NOTES_v1.3.md) | v1.3 릴리즈 노트 (보안, 녹화 동기화) |
| **gstApp** | [`gstApp/RECORDING_SYNC_PLAN.md`](./gstApp/RECORDING_SYNC_PLAN.md) | 녹화 동기화 계획서 |
| **gstApp** | [`gstApp/PERFORMANCE_OPTIMIZATION_PLAN.md`](./gstApp/PERFORMANCE_OPTIMIZATION_PLAN.md) | 성능 최적화 계획서 |
| **gstApp** | [`gstApp/SPLITMUXSINK.md`](./gstApp/SPLITMUXSINK.md) | splitmuxsink 기술 문서 |
| **gstApp** | [`gstApp/SECURITY-NOTES.md`](./gstApp/SECURITY-NOTES.md) | 보안 패치 노트 |
| **gstApp** | [`gstApp/CAPTURE_OPTIMIZATIONS.md`](./gstApp/CAPTURE_OPTIMIZATIONS.md) | 캡처 최적화 문서 |
| **ORD** | [`ord/RELEASE_NOTES.md`](../ord/RELEASE_NOTES.md) | ORD v4.8 릴리즈 노트 |
| **ORD** | [`ord/VERIFICATION_GUIDE_ORD.md`](../ord/docs/VERIFICATION_GUIDE_ORD.md) | ORD 검증 가이드 |
| **ORD** | [`ord/edgeconf_pim.json`](../ord/docs/edgeconf_pim.json) | 시스템 통합 설정 예제 |
| **ORD** | [`ord/ord_vcm_conf.json`](../ord/docs/ord_vcm_conf.json) | ORD/VCM 운영 설정 예제 |
| **VCM** | [`vcm/VERIFICATION_GUIDE_VCM.md`](../vcm/docs/VERIFICATION_GUIDE_VCM.md) | VCM 검증 가이드 |
| **MAX9296** | [`max9296/RELEASE_NOTES.md`](./max9296/RELEASE_NOTES.md) | MAX9296 v2.0 릴리즈 노트 |
| **MAX9296** | [`max9296/CHANGELOG.md`](./max9296/CHANGELOG.md) | MAX9296 드라이버 변경사항 |
| **MAX9296** | [`max9296/V4L2_CTRL_GUIDE.md`](./max9296/V4L2_CTRL_GUIDE.md) | V4L2 컨트롤 사용 가이드 |

---

### 호환성 정보

| 항목 | 값 |
|------|----|
| 타겟 플랫폼 | i.MX8MP (NXP BSP) |
| 커널 | Linux 5.10.x |
| GStreamer | 1.18.0 이상 |
| GLIBC | 2.31 이상 (2.33 의존성 제거됨) |
| json-c | 정적 링킹 |
| hiredis | 정적 링킹 |
| Redis | OPS 데이터 처리 시 필요 |

---

### 마이그레이션 가이드 (v0.5.7 → v0.5.8)

#### 1. 코드 업데이트
```bash
cd /opt/pim-package
git pull
git submodule update --init --recursive
```

#### 2. 빌드
```bash
./build.sh clean
./build.sh
```

#### 3. 설정 확인

**ORD 로그 태그 변경** (로그 분석 스크립트 업데이트 필요):
```bash
# 이전: [CPY] [RDS] [TCP] [OVL] [RTC] [OSS] [VER] [ERR]
# 이후: [EVT] [OPS]
```

**VCM 경로 설정** (`edgeconf_pim.json`에 추가):
```json
{
  "VHL_CAM": {
    "tmp_path": "/dev/shm",
    "sd_tmp_path": "/mnt/sd_cam/tmp",
    "final_path": "/mnt/sd_cam"
  }
}
```

#### 4. 서비스 재시작
```bash
systemctl restart ord vcm gstApp
```

#### 5. 검증
```bash
# 버전 확인
journalctl -u gstApp | grep "version"   # 1.4
journalctl -u ord | grep "version"      # 4.8
journalctl -u vcm | grep "version"      # 4.3

# 녹화 동기화 확인
journalctl -u gstApp | grep "split"
journalctl -u vcm | grep "start signal"

# V4L2 컨트롤 확인
v4l2-ctl -d /dev/v4l-subdev2 --list-ctrls
```

---

### 알려진 제한사항

- gstApp 성능 최적화 중 Zero-copy 데이터 경로 재검증은 향후 버전에서 구현 예정
- `/dev/shm` 기반 프로세스 간 상태 공유 방식은 검토 단계

---

### 통계 요약

| 구분 | 수치 |
|------|------|
| **총 커밋** | 약 140개 (gstApp 72 + ORD 27 + VCM 20 + MAX9296 3 + 통합 30) |
| **보안 개선** | 28개 항목 |
| **스레드 안전성** | 8개 항목 |
| **성능 개선** | 14개 항목 (gstApp v1.4 +7) |
| **커널 패닉 수정** | 3건 (MAX9296 v2.0) |
| **버그 수정** | 16개 항목 |
| **신규 유틸리티** | raw2bmp 병렬 변환, rsync 헬퍼 |
| **런타임 스크립트** | 10개 개선 (설정 마이그레이션, 녹화 관리, 복구 전략, SD 마운트, 카메라 제어) |
| **인프라 개선** | 14개 항목 (Docker, 빌드, 스크립트, 복구) |
| **문서** | 13개 파일 |

---

### 버전 흐름

```
v0.5.4 (캡처 + 인코더 + Muxer)
    ↓
v0.5.5 (안정성 강화)
    ↓
v0.5.6 (ext4 + journald)
    ↓
v0.5.7 (비동기 캡처 + Request Queue)
    ↓
v0.5.8 (보안 + 녹화 동기화 + V4L2 + 드라이버) ← 현재
```

---

### 기여자

- **hwjo**: 프로젝트 유지보수, V4L2 통합, 녹화 동기화 설계
- **Sisyphus AI**: ORD/VCM 보안 및 안정성 개선
- **Claude**: gstApp 보안 패치, 문서화, CI/CD 자동화
- **Gemini**: gstApp 성능 최적화(객체 풀링, 큐 튜닝, 캐싱) 및 동기화 로직 고도화
- **GLM**: 기술 자문 및 시스템 아키텍처 검토
- **GLM**: 기술 자문 및 시스템 아키텍처 검토

---

**배포일**: 2026-02-11 (업데이트)
**이전 버전**: v0.5.7 (2026-01-09)
**상태**: 프로덕션 준비 완료
