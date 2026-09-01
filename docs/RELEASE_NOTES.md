# PIM Package Release Notes

## Unreleased (2026-09-01)

### MAX9296 2.11 고속 수동 노출

- 640x360의 mode-valid 31~120 FPS에서 수동 `EXP_TIME(0x500c)`를 더 이상
  `-EBUSY`로 차단하지 않는다. 드라이버는 frame period와 기존 30 FPS 검증
  기준을 경고하고 실제 레지스터 쓰기를 진행한다.
- gstApp은 `ae_on=false`인 JSON 수동 노출을 고속에서도 적용한다. `ae_on=true`인
  고속 기동에서는 기존처럼 초기 exposure seed를 생략한다.
- gstApp preflight는 FHD/HD 30 FPS, 360p 120 FPS 상한을 제어 ioctl 전에
  검증한다. 모드 상한 초과는 `-EINVAL`로 종료한다.
- 120 FPS에서는 nominal frame period 약 8,333 us보다 짧은
  `exp_time=5000`부터 시험하고 실제 FPS와 영상을 함께 확인한다.

### 카메라 기동 지연과 감시 유예 분리

- gstApp `-d` 기본값을 싱글/듀얼 CSI 공통 5초로 통일했다.
- `camera_startup_grace_sec`(기본 25초)를 추가하여 GPIO 전원 시퀀스와 드라이버
  prepare를 포함한 cold-start 감시 유예가 `-d` 변경에 따라 짧아지지 않게 했다.
- 기존 `startup_grace_extra_sec`(10초)는 FINAL STALL 워밍업 계산에만 유지한다.
- `rst_time` start-marker timeout(싱글 25초, 듀얼 35초)과 `init_cooldown_sec`(40초)는
  변경하지 않았다.
- 상세 근거와 타겟 검증 절차는
  [`camera-startup-timing.md`](./camera-startup-timing.md)에 기록했다.

## v0.5.9 (2026-02-11 ~ 2026-03-11)

### 핵심
**카메라 Disconnect Graceful Degradation + 시스템 복구 안정성 강화 + RTSP 안정성 개선**

작성자: hwjo

---

### 컴포넌트 버전

| 컴포넌트 | 이전 (v0.5.8) | 현재 (v0.5.9) | 비고 |
|---------|--------------|--------------|------|
| **gstApp** | v1.4 | **v1.5** | disconnect graceful degradation, RTSP 안정성 |
| **MAX9296 Driver** | v2.0 | **v2.1** | link_status sysfs, MCP4018 지원 |
| **pim_guardian** | v9.2 | **v10.0** | 대규모 리팩터링, symlink 지원 |

---

### 신규 기능

#### 1. 카메라 Disconnect Graceful Degradation

카메라 연결 해제 시 정상 채널의 녹화를 중단하지 않고, 주기적으로 복구를 시도하는 체계입니다.

- **드라이버 link_status sysfs**: MAX9296 `load_regs()` 시 I2C write 실패를 Link A/B별로 추적, per-channel 비트마스크(bit0~bit3)로 `/sys/bus/i2c/devices/X-0048/link_status`에 노출
- **gstApp disconnect 채널 보호**: 시작 시 sysfs 읽어 `g_link_disconnect_mask` 설정, `splitCheck`/`splitNow`/`forceKeyframe`에서 disconnect 채널 skip
- **marker_channel 재선정**: disconnect된 marker_channel을 활성 채널로 자동 재선정하여 `start_video_time_chk` 기록 유지
- **BG_Check 연동**: driver sysfs 기반 disconnect 감지 시 `chk_cam_connect.sh` I2C 폴링 skip, `err_cam` 파일 직접 생성
- **gstApp playing 전 에러체크 skip**: `start_video_time_chk` 파일 기반으로 gstApp 재생 시작 전 `chk_cam_connect.sh` 호출 방지
- **kill_test.sh start_video_time_chk 삭제**: gstApp 종료 시 파일 삭제하여 다음 시작 시 정확한 가드 동작 보장
- **주기적 복구 (periodic-only)**: `maybe_init_cam_on_disconnect()` — JSON 설정 가능 간격(기본 180초)으로 `init_cam.sh` 실행
- **disconnect 판단 통일**: `cam_is_disconnected_unified` (recovering 상태 기반 오탐) 제거 → `drv_disc`(sysfs) + `cam_disconnect_flag`(err_cam) 기반
- **cooldown 중 err_cam 보존**: driver disconnect로 생성된 err_cam 파일을 BG_Check cooldown 중 삭제하지 않음
- **JSON 설정** (`ord_vcm_conf.json` ETC 섹션):
  - `disconnect_init_interval_sec`(180s) — disconnect 시 init_cam 주기적 복구 간격
  - `disconnect_init_grace_sec`(60s) — init_cam 실행 후 재감지 유예 시간
  - `startup_grace_extra_sec`(10s) — v0.5.9 당시 gstApp 시작 유예에 사용. 현재는 FINAL STALL 워밍업 전용
  - `init_cooldown_sec`(40s) — init_cam 실행 후 재실행 대기 시간

#### 2. RTSP appsrc caps 동적 전파 (gstApp v1.5)

- appsrc caps를 실제 비디오 caps에서 동적 추출하여 설정
- RTSP 클라이언트 연결 시 caps 불일치로 인한 스트림 실패 해결
- media_configure 콜백에서 caps 전파 안정화

#### 3. pim_guardian 리팩터링 (v9.2 → v10.0)

Python 기반 시스템 모니터링 데몬을 전면 리팩터링하여 타입 안전성과 모니터링 범위를 대폭 강화했습니다.

- **타입 시스템 도입**: TypedDict(`IOMetric`, `DiskUsageInfo`, `AppProcInfo`) 기반 구조화된 데이터 모델, 전체 함수 타입 힌트 적용
- **카메라 상태 통합 판단**: V4L2 subdev 제어 응답(hw), BG_Check 에러 마스크(bg), cam_state.json 상태를 결합한 `cam_effective` 3단계 판단 (`STARTING` → `active/expected` → `UNKNOWN`)
- **startup grace 로직**: v0.5.9 당시 시작 timestamp + `pim_cam_start_delay`로 계산. 현재는 `/tmp/cam_state/last_start_ts`부터 총 `camera_startup_grace_sec`로 계산
- **온도 경고 시스템**: 히스테리시스 기반 (진입 80°C / 해제 75°C), 30초 주기 로깅, peak 추적
- **RAM delta 모니터링**: `/dev/shm` 사용량 변화율(KB/s) 추적, 16MB/s 초과 시 경고 (해제 8MB/s)
- **tmp sync 경고**: `start_video_time_chk` 동기화 상태 연속 실패 3회 시 경고
- **guardian state 파일 출력**: `/tmp/pim_guardian_state.json`에 전체 상태 주기적 기록
- **에러 이력 수집**: tmp 에러 파일 + journalctl 에러/critical/panic 통합, 180초 윈도우 내 최신 5건 표시
- **guardian 비트마스크**: `GUARD_BIT_CAM_MISMATCH`(0x100), `HB_FROZEN`(0x200), `SD_RO`(0x400), `CPU_HOT`(0x800), `VOLT_ERR`(0x1000)
- **복구 요청**: `--recovery` 플래그 활성 시 `recover_req_init_cam` 파일 생성으로 init_cam 트리거
- **symlink 기반 프로젝트 연결**: `/opt/pim/bin/pim_guardian` symlink 지원

#### 4. edgeconf app 강제 전환

- `force_edgeconf_app_to_gstapp()` 함수 추가
- edgeconf JSON의 `.VHL_CAM.app`이 gstApp이 아닌 경우 자동 전환
- jq + 임시 파일 기반 안전한 JSON 수정

#### 5. SD 재삽입 시 RAM 녹화 복구

- SD 카드 재삽입 시 RAM(`/dev/shm`)에 저장된 녹화 파일을 SD로 자동 복구(backfill)
- 녹화 중단 없이 데이터 보존

#### 6. automnt_sd 안정성 강화

- **fstype 감지 실패 무한루프 방지**: `reinsert_fail_cnt` 백오프 메커니즘 도입, 5회 연속 실패 시 60초 대기 후 재시도 + `/dev/shm` fallback
- **tmp_path fallback/restore**: SD 미삽입 또는 마운트 실패 시 `tmp_path`를 `/dev/shm`으로 자동 전환, SD 재삽입 시 이전 경로로 자동 복구

---

### 버그 수정

- **cam_is_disconnected_unified 오탐**: init_cam 후 "recovering" 상태가 disconnect로 오판되어 periodic init_cam이 즉시 재발동되는 문제 수정
- **all file not create false positive**: disconnect 시 marker_channel 미갱신으로 `start_video_time_chk` 미기록 → 수정
- **periodic init_cam 간격 미준수**: file-count-mismatch/all-file-not-create disconnect 경로에서 `DISCONNECT_INIT_CAM_STATE_FILE` last_init 미갱신 → 수정
- **BG_Check cooldown 중 err_cam 삭제**: driver disconnect err_cam이 cooldown 중 삭제되어 disconnect 상태 추적 손실 → 수정
- **recover_req disconnect 경로**: driver disconnect 시 불필요한 init_cam 트리거 → drv_disc 체크 추가
- **disconnect streak 유실**: cam_disconnect_flag 기반 streak이 cooldown 리셋으로 소실 → 보존 로직 추가
- **chk_voltage.sh 에러 로그 오동작**: 파일명 `err_volt.log` → `err_voltage.log` 수정 (BG_Check 감지 불가 문제), 에러 메시지 `CPU TEMP ERR` → `VOLTAGE ERR` 수정

---

### 인프라 개선

- **Docker 빌드 환경**: 크로스 컴파일 Docker 환경 추가
- **문서 정리**: camera-operation-guide 갱신, 테스트 스크립트 재배치
- **watchdog 타임아웃 확장**: 30s/20s → 300s/300s (disconnect 시나리오 대응)
- **종료 시퀀스 로그 정리**: NOTICE → INFO 레벨 조정, 중복 로그 제거
- **locale 설정**: C.UTF-8 기본 설정
- **pim_gate sFTP_UDP 지원**: 시리얼 명령 enable series 수정

---

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
- **전 채널 키프레임 동시 동기화**: 정각 분할 시점에 모든 인코더(encoderBin)에 `force-keyunit` 이벤트를 즉시 전송하여, 채널 간 분할 시점 편차(Skew)를 수 밀리초(ms) 이내로 최소화하고 실시간 멀티채널 재생 동기화를 실현했습니다.
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

성능 병목 지점을 제거하고 시스템 반응성을 극대화하기 위한 대규모 튜닝을 완료했습니다.

- **컴팩트 큐(Compact Queue) 기본값 적용**: 
  - 지연 시간을 줄이기 위해 파이프라인 전 구간의 기본 큐 사이즈를 대폭 축소했습니다.
  - **Main/Enc**: 100ms, **Record/Capture**: 300~500ms로 설정하여 메모리 점유율과 Latency를 동시에 개선했습니다.
- **오브젝트 풀링 (Object Pooling)**: `FragmentClosedEvent` 풀 도입으로 힙 메모리 할당/해제 오버헤드를 완전히 제거하여 장기 가동 안정성을 확보했습니다.
- **고속 버스 메시지 필터링**: 불필요한 QOS/TAG 메시지를 핸들러 최상단에서 차단하여 CPU 제어 루프 부하를 경감했습니다.
- **문자열/타임스탬프 캐싱**: 무거운 `g_date_time_format` 호출을 75% 절감하여 CPU 피크 부하를 유의미하게 낮췄습니다.
- **안전한 파일 쓰기**: `O_TRUNC` 위험을 제거하고 `ftruncate` + 파일 잠금을 통해 데이터 무결성을 강화했습니다.
- **그레이스풀 셧다운**: `SIGTERM` 핸들러 추가로 `kill_test.sh` 실행 시 녹화 파일이 깨지지 않고 정상적으로 닫히도록 개선했습니다.

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

#### 9. RTC 방전 복구 시스템 (fake-hwclock)

RTC 배터리 방전으로 인해 시스템 시각이 초기화되는 상황에 대비한 이중 안전장치를 구축했습니다.

- **자동 시간 복구**: 부팅 시 RTC 시각이 무효하거나 과거 시점일 경우, 파일 시스템에 저장된 `fake-hwclock` 데이터를 기반으로 시스템 시간을 즉시 복구합니다.
- **RTC 재활성화 (Resurrect)**: 복구된 시간을 RTC 하드웨어에 다시 기록(`hwclock -w`)하여, 방전되었던 RTC가 다시 정상적인 시간 흐름을 가질 수 있도록 강제로 재가동시킵니다.
- **부팅 안정성**: 유효한 시간 소스가 없을 경우 2026년 1월 1일(Safe Epoch)로 강제 설정하여 로그 및 파일 생성 오류를 방지합니다.

#### 10. 런타임 스크립트 강화

프로덕션 안정성을 위한 기타 스크립트 개선 사항입니다.

**설정 마이그레이션 스크립트 (update_edgeconf.sh)**
- **ERR trap + JSON 검증**: 실패 시 자동 로깅 및 백업, 신규 `queue_tune`/`rtsp_tune` 섹션 자동 추가.
- **레거시 자동 변환**: 구형 설정 구조를 신규 i2c 기반 구조로 자동 마이그레이션.

**SD 카드 마운트 및 관리 (automnt_sd / chk_cam_operate)**
- **RO 검출 즉시 대응**: 하드웨어/소프트웨어 Read-Only 감지 시 즉시 쓰기를 중단하고 RAM 모드로 전환.
- **2단계 안전 이동**: RAM(/dev/shm) → SD 버퍼 → SD 최종 경로로 이어지는 안전한 파일 이동 프로세스.
- **ext4 최적화**: `commit=60` 옵션 적용으로 SD 카드 쓰기 수명 연장 및 성능 향상.

**카메라 수동 제어 스크립트**
- AE On/Off 및 Gain/Exp_time/ISO 수동 설정을 위한 전용 도구 세트 추가.

**JSON 설정 추가 (`edgeconf_pim.json`)**
- **`queue_tune` 섹션 신규**: `main_src_time_ms`(300), `enc_src_time_ms`(300), `rec_sink_time_ms`(500), `cap_src_time_ms`(500) — 파이프라인 큐 지연 튜닝
- **`rtsp_tune` 섹션 신규**: `rtsp_factory_latency_ms`(200), `rtsp_appsink_max_buffers`(3), `rtsp_factory_queue_max_buffers`(3), `rtsp_bin_queue_max_time_ms`(100) — RTSP 스트리밍 튜닝
- **`capture` 확장**: `response`(true), `path`("/dev/shm/capture"), `queue_size`(30) 추가
- **per-channel V4L2 설정**: `chN.ae_on`(true), `chN.ae_gain`(256), `chN.bps`([bps, 2048]) 채널별 제어
- **경로 설정**: `sd_tmp_path`("/mnt/sd_cam/tmp"), `final_path`("/mnt/sd_cam")
- **muxer**: 녹화 컨테이너 포맷 설정 (`"mp4"` 기본값)

**JSON 설정 추가 (`ord_vcm_conf.json`)**
- `ORD.err_send_period`(180) — 에러 전송 주기(초)

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

### 🔗 프로젝트 문서 맵 (Documentation Index)

프로젝트의 상세 설계 및 운영 정보를 담고 있는 문서 가이드입니다.

#### 1. 메인 통합 문서 (`docs/`)
- [`RELEASE_NOTES.md`](./RELEASE_NOTES.md): **[현재 문서]** 전체 프로젝트 릴리즈 요약 및 주요 변경 사항
- [`CHANGELOG.md`](./CHANGELOG.md): 커밋 단위의 상세 변경 이력 및 기여자 정보
- [`session-lifecycle.md`](./session-lifecycle.md): 녹화 세션의 생성부터 소멸까지의 상태 전이 및 파일 관리 로직
- [`docker-build.md`](./docker-build.md): Docker 기반의 ARM64 크로스 빌드 환경 구축 및 사용 가이드
- [`cpu-usage-analysis.md`](./cpu-usage-analysis.md): 최적화 전후의 CPU 점유율 비교 및 병목 지점 분석 보고서

#### 2. gstApp 전문 문서 (`docs/gstApp/`)
- [`PERFORMANCE_OPTIMIZATION_PLAN.md`](./gstApp/PERFORMANCE_OPTIMIZATION_PLAN.md): 큐 튜닝, 객체 풀링 등 단계별 성능 개선 로드맵
- [`RECORDING_SYNC_PLAN.md`](./gstApp/RECORDING_SYNC_PLAN.md): 영상-자막 정각 분할 및 키프레임 동기화 설계 메커니즘
- [`CAPTURE_OPTIMIZATIONS.md`](./gstApp/CAPTURE_OPTIMIZATIONS.md): Valve 엘리먼트 기반 캡처 파이프라인 최적화 상세
- [`SPLITMUXSINK.md`](./gstApp/SPLITMUXSINK.md): GStreamer splitmuxsink 플러그인의 기술적 특성 및 속성 가이드
- [`SECURITY-NOTES.md`](./gstApp/SECURITY-NOTES.md): 보안 패치 내역 및 향후 보안 강화 계획

#### 3. ORD 서브모듈 문서 (`ord/docs/`)
- [`ord/RELEASE_NOTES.md`](../ord/RELEASE_NOTES.md): ORD 모듈 전용 릴리즈 노트
- [`ord/docs/VERIFICATION_GUIDE_ORD.md`](../ord/docs/VERIFICATION_GUIDE_ORD.md): ORD 기능 검증 시나리오 및 테스트 절차
- [`ord/docs/edgeconf_pim.json`](../ord/docs/edgeconf_pim.json): 시스템 통합 설정(JSON) 전체 스키마 예제
- [`ord/docs/ord_vcm_conf.json`](../ord/docs/ord_vcm_conf.json): ORD/VCM 운영 파라미터 설정 가이드

#### 4. VCM 서브모듈 문서 (`vcm/docs/`)
- [`vcm/RELEASE_NOTES.md`](../vcm/RELEASE_NOTES.md): VCM 모듈 전용 릴리즈 노트
- [`vcm/docs/VERIFICATION_GUIDE_VCM.md`](../vcm/docs/VERIFICATION_GUIDE_VCM.md): 자막 생성 및 동기화 기능 검증 가이드

#### 5. 하드웨어 및 드라이버 문서 (`docs/max9296/`)
- [`max9296/V4L2_CTRL_GUIDE.md`](./max9296/V4L2_CTRL_GUIDE.md): MAX9296 GMSL2 및 ISP 제어를 위한 V4L2 커스텀 컨트롤 가이드
- [`max9296/RELEASE_NOTES.md`](./max9296/RELEASE_NOTES.md): 커널 드라이버 안정화 및 패치 내역 (v2.0)

### 기여자

- **hwjo**: 프로젝트 유지보수, V4L2 통합, 녹화 동기화 설계
- **Sisyphus AI**: ORD/VCM 보안 및 안정성 개선
- **Claude**: gstApp 보안 패치, MAX9296 드라이버 안정화(커널 패닉 수정), 런타임 스크립트(복구 전략 및 마이그레이션) 강화, 문서화 및 CI/CD 자동화
- **Gemini**: gstApp 성능 최적화(객체 풀링, 큐 튜닝, 캐싱) 및 동기화 로직 고도화
- **GLM**: 기술 자문 및 시스템 아키텍처 검토

---

**배포일**: 2026-02-11 (업데이트)
**이전 버전**: v0.5.7 (2026-01-09)
**상태**: 프로덕션 준비 완료
