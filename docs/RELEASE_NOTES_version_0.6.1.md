# PIM Package 릴리즈 노트
## v0.6.1 (2026-04-09 ~ 2026-04-30)

---

## 🎯 핵심 수정사항 (Quick Summary)

- **VCM SRT 파이프라인 안정화 (v4.4)**: `popen` 3회/iter 제거(mktime 기반), prefix 가드, 조건부 쓰레드 생성, `PATH_START_VIDEO_TIME` mtime 재동기화 (1ms wait 루프 내부 throttled stat 포함)
- **led_flash 통합 LED 제어**: edgeconf `led_flash` 스키마 + MAX9296 v2.3 MCP4018 wiper / AR0234 R0x3270 V4L2 통합
- **MAX9296 v2.3**: MCP4018 VCC/wiper + LED flash V4L2 통합, AWB 프리셋 10가지 확장, 채널/저수준 로그 구조화 (`chN` 접두사)
- **gstApp 업데이트 (v2.0)**: single mode ch3 단독 활성 버그 수정, cam_state 녹화 시각 파일 기반 미러링, `exp_time` NOTICE 노출, led_flash V4L2 통합, parser JSON 타입 검증 + bps 범위 폴백
- **chk_cam_operate 진단 로그 강화**: 채널별 enable/disconnect/checked/missing 분리, SRT 파일(`*data.srt*`) 존재 검증 통합
- **chk_cam_operate retention 사각지대 차단**: RAM/SD 보호선(2 sessions) hard cap fallback, /dev/shm panic watchdog, SD inode/ro 감시 + RAM-only 폴백
- **kill_test.sh kill 대상 정리**: VCM v4.4 자체 동기화로 카메라 kill 시 vcm 동반 kill 불필요
- **docker build 산출물 검증 자동화**: ARM aarch64 + GLIBC max 검사, `mcp_trust_test` 모듈 등록, clean 화이트리스트

---

## 📦 v0.6.1

### 🔥 핵심
**VCM SRT 안정화 + led_flash 통합 + 진단 로그 강화**

VCM의 SRT 동기화 루프를 popen-free로 재구성하고, led_flash 통합 LED 제어를 edgeconf/MAX9296/gstApp 정합 라인업으로 마련했습니다. `chk_cam_operate` 채널별 진단 로그와 docker 빌드 산출물 자동 검증을 도입해 운영 가시성과 패키지 품질을 끌어올렸습니다.

작성자: hwjo

---

### 컴포넌트 버전

| 컴포넌트 | 이전 (v0.6.0) | 현재 (v0.6.1) | 비고 |
|---------|--------------|--------------|------|
| **gstApp** | v1.5 | **v2.0** | single ch3 fix, cam_state 파일 미러링, led_flash V4L2, exp_time NOTICE |
| **MAX9296 Driver** | v2.2 | **v2.3** | MCP4018 wiper + LED flash V4L2 통합, AWB 10종, 채널 로그 구조화 |
| **pim_guardian** | v10.1 | **v10.1** | 변경 없음 |
| **ORD** | v4.8.1 | **v4.8.1** | 변경 없음 |
| **VCM** | v4.3 | **v4.4** | SRT 파이프라인 안정화 (소스 변경, 별도 빌드/배포) |

> **참고**: MAX9296 저장소 표기는 v2.1 (2026-04-23, MCP4018 + LED flash V4L2 통합). PIM 패키지 통합 표기는 v0.6.0의 v2.2를 계승하여 v2.3으로 매김.

---

### 주요 변경

#### 1. VCM SRT 파이프라인 안정화 (v4.4)

기존 SRT 동기화 루프가 매 반복마다 `popen("date +%s")`/`popen("date -d")`를 3회 호출하고 fragile한 prefix 처리에 의존하던 부분을 재구성했습니다.

- **함수명 오타 수정**: `thread_watingMakeSRT` → `thread_waitingMakeSRT`
- **popen 제거 (date(1) 의존성 제거)**: `time(NULL)` + `mktime()` 기반 시각 비교로 전환. fork/exec 비용과 trailing newline 핸들링 이슈 동시 해소
- **prefixFileName 가드**: 첫 분할 전 garbage 사용 방지를 위해 `{0}` 초기화 + 비정상 prefix(빈값/제어문자/`vhl_name` 불일치) 차단. 차단 시 첫 4바이트 hex와 vhl_name을 함께 ERR 로그에 기록 (디버깅 정보 확보)
- **조건부 쓰레드 생성**: `srt_enable / srt_test / vib_enable / vib_test` 플래그가 모두 OFF면 SRT 쓰레드 미생성. `m_srtThreadActive` 멤버로 `destroy()`의 `pthread_join` 보호
- **`PATH_START_VIDEO_TIME` 보존 + mtime 재동기화**: 기존 시작 직후 unlink → 보존으로 변경. gstApp이 카메라 (재)시작 시 `GST_MESSAGE_NEW_CLOCK` 핸들러에서 동일 경로를 재작성하면 mtime 변화로 자동 재동기화 진입 (`set_start_time`)
- **1ms wait 루프 내부 throttled mtime 검사**: SRT 시작시각 도달 대기 중에도 100 iter당 1회 `stat()`로 `PATH_START_VIDEO_TIME` mtime 변경을 감지, 변경 시 `set_start_time`으로 goto 재진입. 메인 루프 외 1ms 정밀 대기 구간에서도 gstApp 재시작 직후 stale 시작시각이 그대로 사용되는 문제 차단
- **신규 매크로**: `PATH_START_VIDEO_TIME_ACTUAL = "/tmp/cam_state/recording/start_video_time"` (`vcm/util.h`)

> **운영 영향**: `start_cam.sh`에서 srt sync 사유의 `pkill vcm`이 더 이상 필요하지 않아 비활성화(주석)되었습니다. `kill_test.sh`도 카메라 kill 시 vcm 동반 kill을 제거했습니다 (자체 동기화 위임). v4.4 vcm을 빌드/배포해야 합니다.

---

#### 2. led_flash 통합 LED 제어 (config + binary 정합)

기존 실험적 `subdev` 키를 정리하고, MCP4018 디지털 포텐셔미터 wiper와 AR0234 R0x3270 LED flash 동작을 단일 `led_flash` 통합 키로 묶었습니다.

- **`update_edgeconf.sh`**:
  - `led_flash` 통합 키 도입: `{enable: bool, wiper: 0-127, flash_delay: 0-255}`
  - 기존 `subdev` 드래프트 키 삭제 (legacy cleanup)
  - 채널별 `awb` 누락 시 `"auto"` 자동 추가 (기본값 일원화)
- **`edgeconf_pim_base.json`**: ch0~ch3에 `led_flash: {enable: false, wiper: 63, flash_delay: 0}` 기본값 추가
- **MAX9296 v2.3** (저장소 v2.1 반영):
  - **`mcp4018_power_ch0/ch1`** standalone V4L2 컨트롤 추가 — MAX9295 MFP4 GPIO로 MCP4018 I²C-bus 게이트 제어 (진단/디버그용)
  - **`apply_channel_controls`에서 LED flash replay** — 캐시된 `ch_ctrl->led_flash`를 AR0234 R0x3270으로 DMA write. firmware_ready 이전에 V4L2로 내려온 설정도 초기화 완료 후 자동 적용
  - **`apply_channel_controls`에서 MCP4018 wiper replay** — MFP4 open → I²C write → MFP4 close 원자 시퀀스를 함수 내부에서 수행, dual/single 콜러가 포트 정보를 넘겨 per-channel replay로 통합
  - **`V4L2_CID_MCP4018_WIPER/_CH1` 핸들러 원자화** — Port A/B가 host `0x2F`를 공유해도 코드 차원에서 상호배제, address remap 없이 두 포트 독립 wiper 설정 가능
- **gstApp**: led_flash V4L2 통합 제어 호출 경로 반영

---

#### 3. MAX9296 v2.3 — AWB 확장 + 로그 구조화

- **AWB 프리셋 10가지 확장** (single mode global 채널 식별 로그 개선과 함께 적용)
- **통합 로그 포맷**: `max9296_apply_channel_controls`가 채널+모드+결과+상세를 한 줄로 출력
  - 예) `ch0 dual applied ok(addr:0x12 ae:on awb:1 gain:... exp:... rot:... mcp:on wiper:0x3f delay:0x00) ret:0`
- **저수준 로그 chN 접두사**: I²C/DMA/MCP4018 write 경로 로그에 채널 식별자 추가
- **init_controls 진입 로그 정리** + V4L2 가이드 문서에 init_controls 로그 해석 섹션 추가

---

#### 4. gstApp 업데이트 (v2.0)

- **single mode V4L2 채널 슬롯 통일** — ch3 단독 활성 설정이 V4L2 슬롯에 반영되지 않던 버그 수정
- **cam_state 녹화 시각 미러링 파일 기반 전환** — v0.6.0의 cam_state JSON→파일 리팩터링 후속. `start_video_time` 등을 `/tmp/cam_state/recording/`에 직접 기록
- **NOTICE 요약 로그 `exp_time` 노출**
- **led_flash V4L2 통합 제어 호출 경로**
- **parser JSON config 견고화** (`parser.cpp/h`):
  - `json_get_int` / `json_get_uint` / `json_get_uint32` / `json_get_int_array` 신규 strict accessor 도입
  - 누락 키: 기존 default 유지 (조용히)
  - 타입 mismatch / 음수 / 배열 길이 불일치: default 유지 + `LOG_ERR` (기존 `LOG_CRIT` 노이즈와 무성 fallthrough 제거)
  - 마이그레이션 키: `cam_width/height`, `recording_time`, `log/debug_level`, `fps`, capture(`delay/timeout/quality/queue_size`), cam[i] `exp_time`/`bps[]`/`ae_gain`/`led_flash(wiper, flash_delay)`
- **bps 범위 폴백**: 기존 `bps < 1` 시 `return -1` abort → `MIN_BITRATE_KBPS..MAX_BITRATE_KBPS` 범위 검사로 전환, 벗어나면 `DEFAULT_RECORD_BITRATE` / `DEFAULT_RTSP_BITRATE` 폴백 후 startup 계속
- **single-encoder 모드 rtsp bps 미러링**: `!dual_enc`일 때 rtsp 슬롯에 rec bps 미러링하여 다운스트림 코드 정합성 유지

---

#### 5. chk_cam_operate 채널별 진단 로그 + SRT 검증

기존 채널별 분기 안에 흩어져 있던 enable/disconnect/file-exist 판정을 배열 기반으로 정리하고, SRT 파일 검증을 카운트에 포함했습니다.

- **채널 상태 배열 분리**:
  - `enabled_chs`: edgeconf에서 `enable=true` 채널
  - `disconnect_chs`: 드라이버 disconnect bitmask 채널
  - `checked_chs`: 실제 검증 대상 (enable && !disconnect)
  - `missing_chs`: 파일 미존재 채널
- **SRT 파일 검증 통합** — `srt_en=true`일 때 `${tmp_path}/*${vhl_name}_${datetime_}*data.srt*` 존재 여부를 `check_num` 카운트에 포함, `srt_status: ok / miss / disabled` 노출
- **로그 포맷 구조화**:
  - 실패: `${muxer},srt file chk fail: en=[ch0,ch1,ch2,ch3] disc=[] chk=[ch0,ch1,ch2,ch3] miss=[ch3] srt=[miss] (retry/boot/total)`
  - 성공: `${muxer},srt file chk ok: en=[...] disc=[...] chk=[...] srt=[ok]`

---

#### 5-1. chk_cam_operate retention 사각지대 차단 (RAM/SD)

기존 retention 로직은 `PROTECT_RECENT_SESSIONS=2` 보호선 때문에 다음 케이스에서 cap 초과에도 삭제 0건이 되는 사각지대가 있었습니다.

- 거대 단일 세션 1개가 RAM cap(1.6GiB) / SD crit(98%)을 단독 초과
- 모든 파일이 `.part` 상태 (commit 마커 누락) → 세션 후보 0
- 파일명 패턴 미스로 세션 ID 추출 실패한 orphan 파일

추가로 SD 측에는 다음 위험이 있었습니다.

- ext4 ro 리마운트 시 retention silent skip → EROFS/ENOSPC 무한 발생
- df-block만 보고 ext4 inode 고갈 미감지 (`*.srt` / `-vib.bin` 누적)
- `disable_file` 회복 조건이 block만 보고 inode 무시 → 재발생 루프

**다층 안전장치** (`chk_cam_operate.sh`):

- **RAM hard cap** (`RAM_HARD_CAP_BYTES_DEFAULT=2.0GiB`): 보호선 무시하고 `oldest fragment`부터 파일 단위 evict (newest 1개는 항상 보존)
- **/dev/shm panic watchdog** (`RAM_FS_PANIC_PCT_DEFAULT=92`): 사용률 자체가 임계 도달 시 모드 무관 emergency evict
- **SD hard cap** (`SD_HARD_CAP_PCT_DEFAULT=99`): 동일한 파일 단위 evict, 단 stop은 `df% < warn_pct` 도달 시 break
- **SD ro → force-disable**: RW 테스트 실패 감지 시 `SD_WRITE_DISABLE_FILE` 강제 작성 → RAM-only 폴백 즉시 발동
- **inode watchdog**: `get_df_inode_pct`로 ext4 inode 사용률 감시, `crit` 도달 시 SD writes disable
- **회복 조건 강화**: block AND inode 모두 `warn_pct` 미만일 때만 SD writes 재개 (단일 지표 회복으로 인한 재발생 차단)

**신규 헬퍼**: `emergency_evict_oldest_fragments()`, `emergency_evict_oldest_fragments_pct()`, `ram_fs_panic()`, `get_df_inode_pct()`

**환경변수 오버라이드** (운영 튜닝):
```bash
RAM_HARD_CAP_BYTES=2147483648   # 2.0 GiB
RAM_FS_PANIC_PCT=92             # /dev/shm usage%
SD_HARD_CAP_PCT=99              # SD usage% bypass 임계
WARN_PCT=95 / CRIT_PCT=98       # 기존 retention/disable 임계 (현행 유지)
```

**동작 매트릭스**:

| 상황 | 트리거 라인 | 효과 |
|---|---|---|
| SD 95~98% | `retention: deleting session` | 세션 단위 삭제 (보호선 2개 유지) |
| SD ≥98% | `CRITICAL: disk usage` | `/tmp/sd_write_disabled` → RAM-only 폴백 |
| SD inode ≥98% | `CRITICAL: SD inode` | 동일 (block 무관) |
| SD ≥99% + 보호 세션만 남음 | `SD HARD CAP` | 보호선 무시 oldest fragment evict |
| SD ro 리마운트 | `SD read-only — force-disable` | RAM-only 즉시 폴백, EROFS 폭주 차단 |
| /dev/shm ≥92% (RAM-only) | `panic threshold reached` | RAM emergency evict |
| RAM > 2.0GiB (RAM-only) | `RAM HARD CAP` | RAM 보호선 무시 evict |

---

#### 6. 카메라 kill 흐름에서 vcm 제외 (start_cam + kill_test)

VCM v4.4의 SRT 안정화(#1)로 vcm을 죽이지 않고도 mtime 재동기화로 복구되므로, 카메라 kill 시 vcm을 동반 종료하던 두 지점을 정리했습니다.

- **`start_cam.sh`**: srt sync 사유 `pkill vcm` 라인 주석 처리
- **`kill_test.sh`**: kill 대상 list에서 `vcm` 제거 (`list="BG_Check_for_pim.sh vcm"` → `"BG_Check_for_pim.sh"`)

> **전제**: VCM v4.4 (SRT 파이프라인 안정화 적용 빌드)를 사용해야 합니다.

---

#### 7. docker build 산출물 검증 자동화 + mcp_trust_test 등록

`docker/build.sh`에 빌드 후 산출물 자동 검증과 신규 모듈 `mcp_trust_test` 등록을 추가했습니다.

- **`mcp_trust_test` 모듈 등록**: clean / build / 검증 화이트리스트 모두 반영
- **`verify_binary`**: 빌드 산출물 ARM aarch64 여부 + GLIBC max 버전 출력
- **`verify_directory`**: pim_gate 디렉토리 산출물 개수 확인
- **clean 화이트리스트**: 정의되지 않은 모듈명 입력 시 거부 (오타로 임의 디렉토리 삭제 방지)
- **검증 실패 시 exit 2**

---

### 신규 문서

- **`docs/file_check_reboot-behavior.md`** — `ord_vcm_conf.json`의 `.ETC.file_check_reboot` 값이 `chk_cam_operate.sh` 루프에서 어떻게 해석되고 어떤 조건에서 재부팅을 트리거하는지 명세
- **`docs/ord_vcm_conf-settings-analysis.md`** — `ord_vcm_conf.json` 설정값이 ord, vcm, chk_cam_operate, BG_Check_for_pim에 미치는 영향 범위 정리
- **`docs/pim-package-0.5.9-수정사항_20260320.xlsx`**, **`docs/pim-package-0.5.9-수정사항_20260401.xlsx`**, **`docs/pim-package-0.6.0-수정사항_20260409.xlsx`** — 외부 공유용 수정사항 정리

---

### 인프라 개선

- `docker/build.sh` 산출물 자동 검증 (arch/GLIBC/디렉토리)
- `mcp_trust_test` 빌드 파이프라인 통합
- gstApp 바이너리 동기화 (single ch3 fix, led_flash V4L2, cam_state 파일 미러링)
- max9296.ko 동기화 (MCP4018 wiper + LED flash V4L2 통합, AWB 10종, 채널 로그 구조화)

---

### 📊 통계

| 구성요소 | 변경 파일 | 주요 키워드 |
|---------|----------|------------|
| **VCM SRT 안정화** | `vcm/tcpServer.{cpp,h}`, `vcm/util.h` | popen 제거, mktime, prefix 가드, mtime 재동기화 (메인 + 1ms wait throttled stat) |
| **led_flash 통합** | `update_edgeconf.sh`, `edgeconf_pim_base.json`, `max9296.ko`, `gstApp` | MCP4018 wiper, AR0234 R0x3270, V4L2 |
| **gstApp parser** | `parser.cpp/h` | json_get_int/uint/uint32/int_array, bps 범위 폴백, single-encoder rtsp 미러링 |
| **chk_cam_operate (진단)** | `chk_cam_operate.sh` | 채널별 진단, SRT 파일 검증 |
| **chk_cam_operate (retention)** | `chk_cam_operate.sh` | RAM hard cap, /dev/shm panic, SD hard cap, SD ro force-disable, inode watchdog |
| **카메라 kill 흐름** | `start_cam.sh`, `kill_test.sh` | vcm 동반 kill 제거 (자체 동기화 위임) |
| **docker build** | `docker/build.sh` | mcp_trust_test, 산출물 검증 |
| **문서** | `docs/*.md`, `docs/*.xlsx` | file_check_reboot 명세, ord_vcm 설정 분석 |

---

### 🔄 마이그레이션 가이드

#### v0.6.0 → v0.6.1

**필수 작업**

1. **edgeconf 설정 추가** (자동 마이그레이션 지원):
   ```json
   {
     "led_flash": {
       "enable": false,
       "wiper": 63,
       "flash_delay": 0
     }
   }
   ```
   - ch0~ch3 모두에 `led_flash` 객체가 추가되며, 기존 실험적 `subdev` 키가 정리됩니다.
   - `awb` 누락 채널은 `"auto"`로 자동 채워집니다.

2. **MAX9296 드라이버 교체**: `max9296.ko` v2.3 (MCP4018 wiper + LED flash V4L2 통합, AWB 10종)

3. **gstApp 바이너리 교체** (v1.5 → v2.0): single ch3 fix, cam_state 파일 기반 미러링, led_flash V4L2 통합, exp_time NOTICE

4. **VCM 재빌드/재배포**: SRT 파이프라인 안정화 v4.4 — `vcm/tcpServer.{cpp,h}`, `vcm/util.h` 변경분 반영
   - **주의**: vcm 바이너리는 본 패키지에 포함되지 않습니다 (서브모듈 빌드/배포 흐름 정책). 별도로 빌드해 `dist/pim/usr/local/bin/vcm`을 갱신해야 합니다.

**권장 작업**

- `start_cam.sh`의 srt sync 사유 `pkill vcm` + `kill_test.sh`의 vcm 동반 kill 비활성화 — VCM v4.4 SRT 안정화 미반영 환경이라면 활성화 유지
- docker build 산출물 검증 출력 (`verify_binary`/`verify_directory`)을 CI에서 실패 신호(exit 2)로 활용
- chk_cam_operate retention emergency 임계값 (`RAM_HARD_CAP_BYTES` / `RAM_FS_PANIC_PCT` / `SD_HARD_CAP_PCT`)을 운영 환경에 맞게 튜닝. 로그에서 `RAM HARD CAP` / `SD HARD CAP` / `panic threshold reached`가 자주 뜨면 fragment size 정책(분할 주기/비트레이트) 재검토 권장

---

### 🎯 버전 흐름

```
v0.5.9 (disconnect graceful degradation + RTSP + pim_guardian v10)
    ↓
v0.6.0 (cam_state 리팩터링 + DMA + 안정성)
    ↓
v0.6.1 (VCM SRT 안정화 + led_flash 통합 + 진단 로그 강화) ← 현재
```

---

## 👥 기여자
- **hwjo** — 프로젝트 유지보수 및 통합
- **Claude Opus 4.7** — VCM SRT 안정화, led_flash 통합 설계, 진단 로그 구조화

---

**문서 작성일**: 2026-04-27 (최종 갱신: 2026-04-30)
**이전 버전 커밋**: 2d4ecad (v0.6.0)
**HEAD 커밋**: 6f73c1e (chk_cam_operate retention emergency evict)
**연관 커밋**: 4d3e77f (vcm SRT mtime + kill_test vcm 제외), 10d65ea (gstApp parser JSON 검증)
