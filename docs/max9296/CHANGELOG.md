# Changelog

All notable changes to the MAX9296 driver will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.11] - 2026-09-01

### Changed
- mode-valid 31~120 FPS에서 `EXP_TIME(0x500c)` 수동 쓰기를 차단하지 않고
  경고 후 적용한다. JSON 초기 수동 노출과 런타임 `exp_time`/
  `exp_time_chX` 모두 같은 정책을 사용한다.
- 경고에는 채널, 모드, FPS, 요청 노출값, frame period, 기존 검증 상한과
  `over_period` 여부를 포함한다. 모드 상한을 넘는 FPS는 계속 `-EINVAL`이다.
- 120 FPS에서는 약 8,333 us보다 짧은 노출값부터 시험하고 실제 영상과 계층별
  FPS를 함께 판정한다. AE auto의 고속 초기 seed 생략과 `0x510a` 미사용은 유지한다.

### Verification
- i.MX8 BSP 5.10.35 clean cross-build: srcversion
  `FA657080406DAF10D6903F7`, SHA-256
  `8bffdef309bc3ff4dea5bb7e1df8b6eca3558cca53ed549553c5711caa3fd888`.
- 360p 정책 36개, 드라이버 노출/zoom 계약, gstApp controls 111개, prepare
  1,117개 및 양 source contract가 통과했다.
- `pim-mp 0.6.3+jhw.camera5` DEB 내부의 드라이버/gstApp/가이드가 source와
  byte-identical임을 확인했다. camera5 타겟 검증은 별도 수행한다.

## [2.10] - 2026-08-31

### Changed
- 기본 `MAX9296_360P_MAX_FPS`를 30에서 120으로 변경해 일반 모듈 하나로
  640x360의 1~120 FPS 요청을 허용한다. 1920x1080/1280x720 상한은 30 FPS다.
- 이 값은 드라이버의 요청 허용 상한이다. `KEEP` 경로 과거 실측은 약
  113~115 FPS이므로 실제 120 FPS 전달을 보장하지 않는다.
- 패키지 기본 edgeconf는 회귀 안전성을 위해 `640x360@30`을 유지한다.
- 활성 AR0234에서 `led_flash.flash_delay=128`이 120 FPS 전달률을 크게 낮추는 것을
  단일 변수 보드 시험으로 확인했다. 패키지 120 FPS fragment는 delay 0과 AE auto를
  적용하고 config migration은 운영자가 명시한 delay 값을 보존한다.

### Safety
- 모든 모드의 `EXP_TIME(0x500c)` 쓰기 안전 상한은 30 FPS로 유지한다.
  640x360의 31~120 FPS에서는 AE auto로 운용하며 수동 노출 및 수동 AE 전환을
  I2C 쓰기 전에 `-EBUSY`로 거부한다.
- SoC 정지 이력이 있는 수동 WB `0x510a` 쓰기는 추가하지 않았다.

### Verification
- i.MX8 BSP 5.10.35 clean cross-build: srcversion
  `8EBDAFE29DF1EA7734A71CB`, SHA-256
  `7a5e0a330b6992c1d10731d1ba02f415cea6e2c428feb5de76625f0b4d066241`.
- 기본 120 FPS 및 명시적 30 FPS override 정책 테스트와 전체 호스트 게이트 통과.
- `pim-mp 0.6.3+jhw.camera3`의 packaged fragment로 dual 640x360@120을 재검증했다.
  sensor `117.5/118.9`, AP1302 `114.9/114.4`, CSI `113.3/113.1` FPS이며
  transport error 0, strict 120 판정은 FAIL이다. 30 FPS 원복 회귀는 PASS다.

## [2.9] - 2026-08-28

### Added
- 1920x1080, 1280x720과 production 640x360 AP1302 출력 모드.
- `crop_enable`(기본 false), 공통 `dz` 100~300(1.00x~3.00x), 채널별
  `dz_x_chX`/`dz_y_chX` 중심 제어와 firmware replay.
- 640x360 readout 후보, 엄격 120 FPS, CPU/RSS/DDR/온도와 frame-format 검증 도구.

### Safety
- 일반 모드 상한과 `EXP_TIME(0x500c)` 쓰기 안전 상한을 별도 정책으로 유지한다.
  production은 전 모드 30 FPS이며 qualification의 31~120 FPS 수동 노출은 I2C
  전에 `-EBUSY`로 거부한다.
- SoC 정지 이력이 있는 수동 WB `0x510a` 쓰기는 추가하지 않았다.
- `crop_enable=false`에서는 `0x1010`, `0x1012`, `0x118c`, `0x118e`를 쓰지 않는다.

### Changed
- 듀얼 합성의 배율은 채널별이 아니라 공통 `dz`만 사용한다. 중심은 채널별로
  유지한다. `0x1012`는 중심 X가 아니라 전이 속도이며 실제 중심은
  `0x118c/0x118e`다.
- 640x360 `KEEP`은 AP1302/CSI 출력 context만 바꾸고 AR0234 sensor-mode는
  유지한다. KEEP 120 FPS 실측은 약 113~115 FPS로 엄격 기준에 미달해 production
  기본은 30 FPS다.
- 드라이버 버전 2.8 → 2.9.

### Verification
- i.MX8 BSP 5.10.35 clean cross-build: srcversion
  `DA89ABE8A6E147911293CE6`, SHA-256
  `b27ae021fe4cb569ed6264712fabebb2a6b2cb6f5ab27278aebdb4113e09fc33`.
- 360p/노출/crop/readout/FPS/resource/frame-integrity 전체 호스트 게이트 통과.

## [2.8] - 2026-08-27

- single 640x360, dual 1280x360과 디지털 줌·중심 컨트롤을 추가했다.
- 모든 `0x500c` 쓰기를 안전 가드로 통합하고 30 FPS 초과 수동 노출을 선제 거부했다.
- live control 주소 선택은 요청 모드가 아니라 실제 프로그램된 모드 토폴로지를 따른다.

## [2.7] - 2026-08-21

- cached control의 소모성 pending 게이트를 제거해 cold boot와 gstApp respawn에서
  manual AE/gain 복원이 동일하게 동작하도록 했다.
- 병렬 prepare와 BSP의 누수 전원 참조를 함께 처리한다.

## [2.5] - 2026-08-20

### Fixed
- prepare 가 벤더 ISI capture 드라이버의 반환되지 않는 V4L2 전원 참조를 lease 로
  인수 (`0608424`). `imx8-isi-cap.c` 는 `s_power(1)` 만 호출하고 해제 경로가
  `s_stream(0)` 까지만 가서 `power_count` 가 단조 증가한다. 그래서 첫 카메라 기동
  이후의 모든 prepare 가 `-EBUSY` 로 막혔고 rebind 나 재부팅 외에 회복 경로가
  없었다. 실측: `s_power(1)` 14회 / `s_power(0)` 0회.

### Changed
- prepare **admission** 게이트가 `power_count` 대신 실제 `streaming` 여부로만
  거부한다. 이 BSP 에서 `power_count` 는 살아있는 소유자의 증거가 아니다.
  `max9296_cancel_prepare()` 의 게이트는 바꾸지 않았다 - 인수가 `power_count` 를
  0 으로 만들어 정상 흐름에서 그대로 동작한다.
- 드라이버 버전 2.4 → 2.5

### 검증
- 온타겟(pim-camera-v016): 누수 잔류 상태에서 prepare 성공, 그 구간 펌웨어
  다운로드 0건(`epoch` 불변 - warm 재사용 유지), cancel 후 재 prepare 성공,
  스트리밍 중에는 여전히 `-EBUSY`
- 보드 게이트 **G1~G4 전부 통과** (2026-08-21, 드라이버 2.5 한 버전). G4 는 사이클마다
  하드 리셋하는 방식으로 dual 50/50 + single 50/50 을 완주했고, 각 사이클이 펌웨어
  재다운로드와 `v4l2-ctl` 종료 상태를 함께 확인한다
- **전제 조건**: 두 CSI 도메인의 prepare write 는 반드시 병렬로 해야 한다. 순차로 쓰면
  양쪽 `READY` 를 받고 펌웨어도 정상인데 두 번째 도메인이 스트림하지 못하며, ABI 가
  이를 거부하지 않아 상태줄로는 알 수 없다. 계약 원문은 상위 저장소에 있다 -
  https://github.com/jhw7500/max9296/blob/master/docs/parallel-prepare-v1.md 의
  "Parallel use" 절

## [2.4] - 2026-08-12

### Added
- 읽기 전용 `health_raw` sysfs ABI: MAX9296 DES, RX3 GMSL link, MAX9295 SER
  management endpoint, AP1302 ISP HINF counter를 요청 시점에 한 번만 샘플링
- `tools/max9296_health_export.py`: 두 MAX9296 인스턴스의 raw snapshot을
  `/run/pim-camera/max9296.json` camera-health v1 문서로 원자적으로 변환
- DES/GMSL/SER/ISP/Sensor를 분리한 진단 상태와
  `configured_channel_mask`, `physical_present_mask`,
  `stream_domain_active_mask` 세 종류의 mask
- dual-wide 공유 stream domain, 독립적인 MAX9295/AP1302 remote probe branch,
  SER 귀속 불가 및 Sensor/ISP stall 모호성에 대한 단위 테스트
- 병렬 prepare ABI: prepare 를 stream commit 에서 분리하고 lease/epoch 게이트를
  추가 (`482795c`, `77bb9dc`, `2118a05`)

### Changed
- sysfs attribute 생성 실패 시 이미 생성한 attribute를 역순으로 회수
- 드라이버 버전 2.3 → 2.4

### Fixed
- rebind 를 가로질러 공유 reset 을 보존 (`8a142a4`)
- detach 이후 peer worker 복구, 비대칭 peer 를 remove 시 분리 (`02c014a`, `ab6aaa1`)
- 공유 FSYNC 계약 강제 (`6495f43`)
- probe 실패 경로에서 리소스를 안전하게 되감기 (`2106d91`)
- 전원 시퀀스 refcount 일원화 및 FSYNC/enable 게이트 정정 (`d8ec2e1`)
- 단일 채널 모드에서 시리얼라이저 주소를 0x40 으로 고정 (`3d238c6`)
- 단일 채널에서 CH1 MCP4018 컨트롤을 활성 채널로 게이트 (`dc8350b`)
- 카메라 pinctrl 그룹을 실제 사용 핀에 정합 (dts) (`5ae703f`)
- 조용히 실패하던 I2C/DMA 경로에 로그 추가, 저수준 로그 줄바꿈 누락 수정
  (`1d82fbd`, `3b1692e`)

### Safety
- health read는 reset, power toggle, register write, module reload를 수행하지 않음
- health용 I2C read는 retry/log 없이 한 번만 시도하며 control mutex가 사용 중이면
  대기하지 않고 `busy:true`를 반환
- AR0234 deep DMA probe는 수백 ms 지연 가능성 때문에 이 shallow ABI에서 제외

## [2.3] - 2026-04-27

### Changed
- 채널 설정 로그를 구조화하고 저수준 write 성공/실패 로그를 정리 (`25388f3`)
- I2C/DMA/MCP4018 저수준 로그에 `chN` 접두사 추가 (`6c7ce37`)
- 버전 번호: 2.1 → 2.3 (`fb00849`)

### Notes
- **2.2 는 존재하지 않는다.** 상위 저장소에 `SW_VERSION "2.2"` 를 도입한 커밋이
  없으며 버전은 2.1 에서 2.3 으로 곧바로 올라갔다. 2.2 를 찾다 헛수고하지 않도록
  명시해 둔다.

## [2.1] - 2026-04-23

### Added
- **MCP4018 VCC power V4L2 컨트롤**: `mcp4018_power_ch0/ch1` (bool). MAX9295 MFP4 GPIO로 MCP4018 I²C-bus 게이트를 제어. 진단/디버그용 standalone handle
- **apply_channel_controls에서 led_flash replay**: 캐시된 `ch_ctrl->led_flash`를 AR0234 R0x3270으로 DMA write. firmware_ready 이전에 V4L2로 내려온 설정이 초기화 완료 후 자동 적용됨
- **apply_channel_controls에서 MCP4018 wiper replay**: 지정 port의 MFP4 GPIO를 열고 wiper를 쓴 뒤 닫는 원자 시퀀스를 함수 내부에서 수행. dual/single 모드 콜러가 포트 정보(ser_addr/host/wiper)를 넘겨 per-channel replay로 통합

### Changed
- **`V4L2_CID_MCP4018_WIPER/_CH1` handler 원자화**: s_ctrl 내부에서 MFP4 open → I²C write → MFP4 close를 원자적으로 수행. Port A/B가 host 0x2F를 공유해도 코드 차원에서 상호배제되어 address remap 없이 두 포트 독립 wiper 설정 가능
- **통합 로그 포맷**: `max9296_apply_channel_controls`가 채널+모드+결과+상세(AE/AWB/gain/exp/rot/mcp/wiper/delay)를 한 줄로 출력. 예: `ch0 dual applied ok(addr:0x12 ae:on ... mcp:on wiper:0x3f delay:0x00) ret:0`
- MCP4018 주석 정정: "VCC controlled by MFP4 HIGH" → "I²C-bus gate controlled by MFP4 (wiper is retained by the pot after gate closes)"
- 버전 번호: 2.0 → 2.1

### Removed
- `max9296_apply_cached_controls` 말미 중복 요약 로그 `cached controls applied (exp:%d)` 제거 (채널별 통합 로그로 대체)

### Notes
- **MCP4018 port 매핑**: 드라이버 내부 "CH0/CH1"은 local(Port A / Port B) 개념. adapter 2 → 전역 ch0/ch1, adapter 1 → 전역 ch2/ch3에 대응
- **replay gating**: flash enable bit(0x100)가 꺼진 채널은 MCP4018 write를 생략 → 미장착 보드에서 ENXIO 로그 방지
- **Single 모드**: led_flash는 CH0 슬롯(AP1302 firmware 라우팅), MCP4018은 `sensor->enable`로 active local port를 선택

## [2.0] - 2026-02-11

### Fixed
- **[CRITICAL] kthread_stop UAF**: `max9296_shared_init` 자연 종료 후 task_struct 자동 회수로 인한 kthread_stop UAF 패닉 수정. `get_task_struct()`/`put_task_struct()`로 참조 카운트 관리
- **[HIGH] 듀얼 모드 peer UAF**: sensor_B remove 완료 후 sensor_A 스레드의 freed memory 접근 패닉 수정. 4-phase remove 구조로 재설계 (peer threads → own threads → cleanup → V4L2)
- **[MEDIUM] kthread_stop soft lockup**: `ssleep()`/`msleep()` 중 `kthread_should_stop()` 미확인으로 인한 soft lockup 패닉 수정
- **probe 실패 경로 리소스 누수**: `get_task_struct()` 이후 probe 실패 시 스레드 및 task_struct 참조 누수 수정. `free_ctrls` 에러 경로에 클린업 추가

### Refactored
- 커스텀 `max9296_interruptible_sleep()` → `msleep_interruptible()` 표준 커널 API 전환
- kthread_stop 후 스레드 포인터 NULL 할당 추가

### Changed
- 버전 번호: 1.9 → 2.0

## [1.9] - 2026-02-09

### Fixed
- **usleep_range 타이밍 최적화**: `max9296_load_regs`에서 delay_ms 사용 시 범위 폭을 10%로 증가하여 커널 타이머 효율성 개선 (708줄)
- **매크로 안전성 개선**: `_FILE_` 매크로 정의에서 `__FILE__` 참조에 괄호 추가하여 매크로 전개 시 연산자 우선순위 문제 방지 (46줄)

### Changed
- 버전 번호: 1.8 → 1.9

## [1.8] - 2026-02-08 (추정)

### Added
- FSYNC 기반 FPS 제어 메커니즘 문서화 (V4L2_CTRL_GUIDE.md)

### Fixed
- 죽은 코드(`#if 0` 블록) 11개 완전 제거
- `max9286_set_ctrl_pixelrate` 함수명 오타 수정 → `max9296_set_ctrl_pixelrate`
- CI 빌드 테스트를 Linux 5.10 환경에서 실행하도록 수정

### Refactored
- 코드 스타일 정리 및 로직 개선

## [1.7] - 2026-02-07 (추정)

### Fixed
- rmmod 시 kthread use-after-free 에러 수정
- build-test와 auto-rereview-request 워크플로우 비활성화

### Added
- GitHub Actions 워크플로우 추가

## [1.6] - 2026-02-06 이전

### Added
- 초기 드라이버 구현
- MAX9296 GMSL2 Deserializer 지원
- AP1302 ISP 통합
- 듀얼 채널 per-channel V4L2 커스텀 컨트롤 지원
- FSYNC GPIO 기반 프레임 동기화 (1~120 FPS)
- 48개 V4L2 컨트롤 지원
  - 채널별 AE, AWB, Gain, Exposure 제어
  - 채널별 Flip (H/V) 제어
  - 채널별 이미지 튜닝 (Brightness, Contrast, Saturation, LSC)

---

## 버전 관리 규칙

- **Major.Minor** 형식 사용
- **Major**: 주요 기능 추가 또는 호환성 변경
- **Minor**: 버그 수정, 경미한 개선, 코드 정리

## 링크

- [소스 코드](https://github.com/jhw7500/max9296)
- [이슈 트래커](https://github.com/jhw7500/max9296/issues)
