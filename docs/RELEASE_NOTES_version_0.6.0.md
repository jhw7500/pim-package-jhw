# PIM Package 릴리즈 노트
## v0.6.0 (2026-03-12 ~ 2026-04-08)

---

## 🎯 핵심 수정사항 (Quick Summary)

- **cam_state 파일 기반 전환**: jq/JSON 방식에서 디렉토리 기반 파일 관리로 전환, 주기적 스크립트의 CPU spike 제거
- **MAX9296 DMA 드라이버**: SIPM→DMA 전환, FSYNC 깜빡임 수정, MCP4018 LED 제어 지원
- **시스템 안정성 강화**: i2c 글리치 필터링, SD RO 즉시 감지(21초→3초), WiFi power_save 안정화
- **ETH1 ping 헬스체크**: edgeconf 기반 네트워크 상태 모니터링 추가
- **pim_guardian 인터랙티브 복구**: SD RO/cam disconnect 등 이상 감지 시 사용자 승인 기반 복구

---

## 📦 v0.6.0

### 🔥 핵심
**cam_state 파일 기반 리팩터링 + MAX9296 DMA + 시스템 안정성 강화**

cam_state를 jq/JSON에서 파일 기반 구조로 전환하여 CPU spike를 제거하고, MAX9296 드라이버에 DMA 지원을 추가했습니다. 시스템 안정성 전반을 강화했습니다.

작성자: hwjo

---

### 컴포넌트 버전

| 컴포넌트 | 이전 (v0.5.9) | 현재 (v0.6.0) | 비고 |
|---------|--------------|--------------|------|
| **gstApp** | v1.5 | **v1.5** | RTSP graceful shutdown, cam_state 파일 기반 반영 |
| **MAX9296 Driver** | v2.1 | **v2.2** | DMA R/W, FSYNC 수정, MCP4018 지원 |
| **pim_guardian** | v10.0 | **v10.1** | 인터랙티브 복구 프롬프트 |
| **ORD** | v4.8.1 | **v4.8.1** | - |
| **VCM** | v4.3 | **v4.3** | cam_state 녹화 시간 미러링 |

---

### 주요 변경

#### 1. cam_state jq/JSON → 파일 기반 전환

jq 호출이 주기적 스크립트에서 CPU spike를 유발하여 파일 기반으로 전환했습니다.

- **기존**: `/tmp/cam_state.json` (jq로 읽기/쓰기)
- **변경**: `/tmp/cam_state/` 디렉토리 내 개별 파일 관리
- **영향 범위**: cam_state.sh 라이브러리, BG_Check, chk_cam_operate, init_cam, start_cam, pim_guardian, gstApp 바이너리 일괄 반영
- **recording 스키마 추가**: `cam_recording_set`/`sync_schema` 함수 추가, VCM에서 녹화 시간 미러링

---

### 신규 기능

#### 2. MAX9296 DMA 드라이버 (v2.2)

MAX9296 드라이버에 DMA R/W V4L2 컨트롤을 추가하고 FSYNC 관련 이슈를 수정했습니다.

- **SIPM→DMA 전환**: DMA 기반 센서 레지스터 읽기/쓰기 V4L2 컨트롤 추가
- **FSYNC 깜빡임 수정**: `usleep_range` 지터 제거로 영상 깜빡임 해결
- **exposure 로직 개선**: AE/AWB/LSC 초기화를 `0x3c` 글로벌 쓰기로 복원, AE 모드 무관하게 `exp_time` 항상 설정
- **MCP4018 지원**: ch0~ch3 네이밍, LED flash DMA 경로 추가
- **DMA 셸 스크립트**: `cam_dma_read.sh`, `cam_dma_write.sh` (채널→subdev 자동 매핑)
- **채널 resolve 공통화**: `cam_channel_resolve.sh` 추가, 기존 스크립트 채널 매핑 로직 통합

#### 3. ETH1 ping 헬스체크

edgeconf 기반 네트워크 상태 모니터링 기능을 추가했습니다.

- **`chk_eth1.sh`**: edgeconf JSON의 `ping_check_enable`, `client_ip_addr`, `ping_max_fail_count` 설정 기반 ping 체크
- **BG_Check 연동**: `BG_Check_for_pim.sh`에서 `chk_eth1.sh` 호출 활성화
- **설정 마이그레이션**: `update_edgeconf.sh`에 ETH1 ping 설정 자동 마이그레이션 로직 추가
- **기본값**: `defaultconf.json` / `edgeconf_pim_base.json`에 기본값 포함

#### 4. AR0234 센서 제어 스크립트

- **clock 제어**: AR0234 clock 설정 스크립트 추가
- **LED flash 제어**: AR0234 LED flash 제어 스크립트 추가
- **MCP4018 LED 제어**: `mcp4018_ctrl.sh` 추가
- **AP1302 DMA 센서 진단**: DMA 기반 센서 레지스터 진단 스크립트 추가

#### 5. pim_guardian 인터랙티브 복구 (v10.1)

SD RO/cam disconnect/heartbeat frozen 감지 시 자동 복구 대신 사용자 승인 후 복구를 실행합니다.

- **y/n 프롬프트**: 30초 타임아웃으로 사용자 확인 후 복구 실행
- **SD RO 복구 절차**: kill_test → sd-mount 중지 → umount → blkid 기반 파일시스템 감지(ext4/vfat/exfat) → fsck → sd-mount 재시작
- **fstype 감지 불가 시**: 복구 중단 및 SD 손상 안내 메시지 출력

#### 6. cam_state 녹화 시간 동기화

- **cam_state.sh**: recording 스키마 추가 (`start_video_time` 등)
- **VCM**: `mirror_recording_time_to_cam_state` 함수 추가, 녹화 시간을 cam_state에 미러링

---

### 버그 수정

- **i2c 일시적 통신 불량 시 불필요한 리셋 방지**: 읽기 실패 시 즉시 리셋 쓰기 대신 읽기 전용 재시도(3회)를 먼저 수행하여 일시적 글리치 필터링. 재시도 실패 시에만 리셋 쓰기 1회 수행 (`chk_cam_connect.sh`)
- **SD read-only 즉시 감지 최적화**: `is_sd_ro()` 헬퍼 함수로 H/W+S/W RO 통합 판단, State 1 RO 감지 시 fallback 시간 21초→3초 단축, State 2 무한루프 방지 (`automnt_sd_for_emmc_boot.sh`)
- **SD 마운트 fstype 감지 실패 무한루프 방지**: 연속 5회 실패 시 60초 backoff 대기, SD 물리적 제거 시에만 카운터 리셋 (`automnt_sd_for_emmc_boot.sh`)
- **MAX9296 FSYNC 깜빡임**: `usleep_range` 지터 제거로 영상 깜빡임 해결
- **MAX9296 exposure 로직**: per-channel `EXT_TIME_CHx` 제거, 공유 `EXT_TIME`만 사용, AE auto/manual 무관 `exp_time` 항상 설정
- **DMA stuck 자동 리셋**: `cam_ap1302_dma_verify.sh`에 DMA stuck 시 자동 리셋 추가
- **WiFi power_save off 안정화**: `rc.local` 직접 호출 제거 → `wifi_power_save_off.sh` 분리, 무선 인터페이스 미존재 시 에러 출력 방지 (30초 타임아웃 폴링)
- **BG_Check cam_reset_streak**: 에러 해소 시 `cam_reset_streak` 호출 추가
- **gstApp EXT_TIME**: per-channel EXT_TIME 제거, 공유 EXT_TIME만 사용

---

### 인프라 개선

- **gstApp 바이너리 업데이트**: RTSP graceful shutdown 반영, cam_state 파일 기반 전환 반영
- **VCM 녹화 시간 미러링**: cam_state 녹화 시간 동기화 추가
- **init_cam**: vib.bin 정리 추가
- **sc16is7xx 드라이버**: 디버깅 로그 추가

---

### 📊 통계

| 구성요소 | 커밋 수 | 주요 키워드 |
|---------|---------|------------|
| **cam_state 전환** | 2 | jq→파일 기반, recording 스키마 |
| **MAX9296** | 2 | DMA, FSYNC, MCP4018, exposure |
| **시스템 안정성** | 5 | i2c 글리치, SD RO, WiFi, 마운트 루프 |
| **신규 기능** | 5 | ETH1 ping, AR0234, LED flash, DMA 진단 |
| **pim_guardian** | 1 | 인터랙티브 복구 |
| **인프라** | 3 | gstApp 바이너리, sc16is7xx, VCM |

---

### 🔄 마이그레이션 가이드

#### v0.5.9 → v0.6.0

**필수 작업**

1. **cam_state 전환**: `/tmp/cam_state.json` → `/tmp/cam_state/` 디렉토리 구조로 변경됨
   - jq 기반 스크립트가 있다면 `cam_state.sh` 라이브러리 함수 사용으로 전환 필요
   - guardian, BG_Check 등 소비자 스크립트 자동 반영됨

2. **edgeconf 설정 추가** (자동 마이그레이션 지원):
   ```json
   {
     "ping_check_enable": false,
     "client_ip_addr": "",
     "ping_max_fail_count": 3
   }
   ```

3. **MAX9296 드라이버 교체**: `max9296.ko` 업데이트 (DMA 지원, FSYNC 수정)

**권장 작업**
- gstApp 바이너리 업데이트 (RTSP graceful shutdown, cam_state 파일 기반)
- `wifi_power_save_off.sh` 스크립트 확인 (rc.local에서 분리됨)

---

### 🎯 버전 흐름

```
v0.5.7 (비동기 캡처)
    ↓
v0.5.8 (보안 + 녹화 동기화 + V4L2 + 드라이버)
    ↓
v0.5.9 (disconnect graceful degradation + RTSP + pim_guardian v10)
    ↓
v0.6.0 (cam_state 리팩터링 + DMA + 안정성) ← 현재
```

---

## 👥 기여자
- **hwjo** — 프로젝트 유지보수 및 통합
- **Claude Opus 4.6** — cam_state 리팩터링, 시스템 안정성 개선

---

**문서 작성일**: 2026-04-08
**이전 버전 커밋**: 9b58c30 (v0.5.9)
**HEAD 커밋**: 2d4ecad
