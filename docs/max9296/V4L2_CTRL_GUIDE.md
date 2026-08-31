# V4L2 Control 사용 가이드 (PIM Camera / max9296 + AP1302)

기존 i2ctransfer 기반 스크립트(`cam_*.sh`)는 그대로 유지하고, 런타임 튜닝은 V4L2 컨트롤(`v4l2-ctl`)로 대체하는 것을 목표로 한다.

이 문서는 다음을 제공한다.
- 어떤 `/dev/v4l-subdevX` 노드가 어떤 채널(ch0~ch3)을 의미하는지
- 각 V4L2 컨트롤이 어떤 AP1302 레지스터에 매핑되는지
- fixed-point(고정점) 값의 스케일(256=1.0, 4096=1.0)과 사용 예제
- 운영 환경에서 안전하게 적용하는 절차(cam-operate/재시작 스크립트와의 관계)

## 1) 장치 노드/채널 매핑 규칙

이 플랫폼의 전역 채널 정의는 이미 운영 스크립트/JSON에서 고정되어 있다.

- `ch0/ch1` = i2c2 쪽 카메라
- `ch2/ch3` = i2c1 쪽 카메라

V4L2 subdev 노드도 이 전역 채널과 정합되게 사용한다.

- `/dev/v4l-subdev2` : (전역) ch0/ch1
- `/dev/v4l-subdev3` : (전역) ch2/ch3

참고: 드라이버는 `/dev/v4l-subdev3`에서 커스텀 컨트롤 이름을 `*_ch2/_ch3`로 표시되도록 맞춰 혼란을 줄였다.

배포 패키지(pim-package)에는 동일 문서가 `/opt/pim/docs/V4L2_CTRL_GUIDE.md`로 포함된다.

### 1.1 해상도와 디지털 crop은 독립 제어

| 카메라당 출력 | single V4L2 폭 | dual V4L2 폭 | 드라이버 요청 상한 | 노출 쓰기 안전 상한 |
|---:|---:|---:|---:|---:|
| 1920x1080 | 1920x1080 | 3840x1080 | 30 | 30 |
| 1280x720 | 1280x720 | 2560x720 | 30 | 30 |
| 640x360 | 640x360 | 1280x360 | 120 | 30 |

`cam_width`/`cam_height`는 AP1302/CSI 출력 크기를 선택한다. `crop_enable`과
`dz`는 선택된 출력 안에서 디지털 확대·중심 조준만 하며 출력 해상도를 바꾸지
않는다. 따라서 FHD에서 crop을 켜도 CSI 출력은 1920x1080이고, 640x360에서
crop을 꺼도 CSI 출력은 640x360이다.

기본 640x360 `KEEP` 정책은 AP1302 출력 context를 640x360으로 바꾸지만 AR0234
sensor-mode 선택은 펌웨어 값을 유지한다. 즉 640x360 출력이 곧 AR0234의
640x360 readout을 의미하지 않는다. 후보 sensor-mode 0~15는 full-FOV 120 FPS
profile로 검증되지 않았으므로 운영 기본은 `KEEP`이다. 일반 드라이버는 이 경로에서
최대 120 FPS 요청을 허용하지만 패키지 기본값은 회귀 안전성을 위해 30 FPS다.
120 FPS에서는 패키지의 전용 fragment를 사용해 AE auto와 활성 채널
`led_flash.flash_delay=0`도 함께 적용한다. 이 보드에서 delay 128은 요청/caps를
유지한 채 실제 CSI 전달률을 크게 낮췄다.

## 2) 값 표현(고정점) 규칙

V4L2 컨트롤은 기본적으로 정수값으로 노출된다. 대부분은 레지스터 스케일을
그대로 사용하지만 디지털 zoom은 사람이 읽는 백분율·정규화 좌표를 AP1302 8.8
형식으로 변환한다.

- Gain: `ufixed8` (u16)
  - 스케일: `256 = 1.0x`, `512 = 2.0x`
- Brightness/Contrast/Saturation/LSC: `fixed12` (u16)
  - 스케일: `4096 = 1.0`, `6144 = 1.5`, `8192 = 2.0`
- Exposure: `unsigned 32-bit`
  - V4L2는 s32 범위를 쓰므로 드라이버는 `0..INT_MAX` 범위를 허용한다.
- Digital zoom: 사용자 ABI는 백분율과 정규화 좌표를 사용한다.
  - `dz`: `100..300` = 1.00x..3.00x
  - `dz_x`/`dz_y`: `0..65535`, 중앙 `32768(0x8000)`

| `dz` | 의미 | AP1302 `0x1010` |
|---:|---:|---:|
| 100 | 1.00x, 확대 없음 | `0x0100` |
| 150 | 1.50x | `0x0180` |
| 200 | 2.00x | `0x0200` |
| 300 | 3.00x | `0x0300` |

보드 기본값(참고: `--list-ctrls` 기준)
- `brightness_chX`: default=0
- `contrast_chX`: default=0
- `saturation_chX`: default=4096
- `gain_chX`: default=256
- `lsc_chX`: default=16383(0x3fff)

참고
- V4L2 컨트롤(`contrast_chX`, `saturation_chX` 등)은 `v4l2-ctl --list-ctrls` 출력에 레지스터 주소를 직접 표시할 수 없다.
- 레지스터 주소는 아래 "컨트롤 ↔ 레지스터 매핑" 섹션을 기준으로 본다.

## 3) 컨트롤 ↔ 레지스터 매핑 (요약)

드라이버 소스 기준: `projects/max9296/max9296.c`

### 3.1 공통 컨트롤

- `crop_enable` (`V4L2_CID_USER_BASE+0x102b`) -> bool, 기본 false
- `exp_time` -> `0x500c` (u32, 듀얼 모드에서는 양 채널에 동일 적용)
- `dz` -> `0x1010` (100~300%, 기본 100%, 양 채널 공통)
- `dz_x` -> `0x118c` (공유 정규화 중심 X, 기본 32768)
- `dz_y` -> `0x118e` (공유 정규화 중심 Y, 기본 32768)
- `hue` -> Hue (0~359)
- `power_line_frequency` -> 전원 주파수 필터 (0~3, 기본 1=50Hz)

### 3.2 Per-Channel ISP 컨트롤

- `/dev/v4l-subdev2`: `*_ch0`, `*_ch1`
- `/dev/v4l-subdev3`: `*_ch2`, `*_ch3`

| 컨트롤 | AP1302 레지스터 | 타입 | 설명 |
|---------|-----------------|------|------|
| `ae_on_chX` | `0x5002` | bool | AE 자동/수동 (1=auto, 0=manual) |
| `auto_white_balance_chX` | `0x5100` | bool | AWB on/off |
| `auto_gain_chX` | `0x5002` | bool | Auto Gain (AE 모드에서 암묵 처리) |
| `gain_chX` | `0x5006` | u16, ufixed8 | 수동 Gain (256=1.0x) |
| `exp_time_chX` | `0x500c` | u32 | 수동 Exposure Time (μs) |
| `hflip_chX` / `vflip_chX` | `0x100c` | bool | 수평/수직 반전 |
| `brightness_chX` | `0x7000` | u16, fixed12 | 밝기 (4096=1.0) |
| `contrast_chX` | `0x7002` | u16, fixed12 | 대비 (4096=1.0) |
| `saturation_chX` | `0x7006` | u16, fixed12 | 채도 (4096=1.0) |
| `lsc_chX` | `0x54a0` | u16, fixed12 | LSC 보정 강도 |
| `led_flash_chX` | AR0234 `0x3270` | u16 | LED Flash (bit8=EN, bit7:0=DELAY) |
| `dz_x_chX` | `0x118c` | 0~65535, 기본 32768 | 채널별 정규화 중심 X |
| `dz_y_chX` | `0x118e` | 0~65535, 기본 32768 | 채널별 정규화 중심 Y |

듀얼 합성 모드는 양 AP1302의 센서 판독 타이밍을 맞춰야 하므로 배율은 공통
`dz`만 사용한다. 서로 다른 위치를 검사할 때는 채널별 중심만 바꾼다.
`0x1012`는 중심 X가 아니라 줌 전이 속도이므로 드라이버가 즉시 적용값
`0x8000`만 쓴다. `0x1014`는 optical zoom factor라 이번 구현에서 쓰지 않으며,
실제 중심은 `0x118c/0x118e`다.

`crop_enable=false`이면 줌과 중심값은 cache만 갱신하고 `0x1010`, `0x1012`,
`0x118c`, `0x118e` I2C 쓰기를 발행하지 않는다. true에서는 STREAMOFF 상태에서
enable한 뒤 공통 배율과 활성 채널 중심을 런타임 변경할 수 있다. 스트리밍 중
enable 전환은 `-EBUSY`이며 같은 값의 no-op은 성공한다. true에서 false로 바꾼 뒤
기존 하드웨어 crop을 제거하려면 `cam_hard_reset.sh -s -S` 또는 `init_cam.sh`로
firmware를 다시 로드한다. gstApp 재시작만으로는 하드웨어 epoch가 바뀌지 않는다.

### 3.3 노출 쓰기 안전 정책

일반 영상 FPS 요청 상한과 `EXP_TIME(0x500c)` 쓰기 안전 상한은 별도 정책이다.
640x360의 31~120 FPS에서 `exp_time`, `exp_time_chX` 또는 수동 AE
전환으로 노출 쓰기가 필요하면 I2C 전에 `-EBUSY`로 거부한다. 로그에는 채널,
모드, 현재 FPS, 요청 노출값, 안전 상한이 남는다.

고속 운용에서 AE auto이면 초기 exposure seed만 생략하고 gain/AWB/flip
등은 유지한다. 30 FPS 이하에서는 기존 노출·gain·AE 동작을 유지한다. SoC 정지
이력이 있는 수동 WB `0x510a` 쓰기는 이 구현에 추가하지 않았다.

### 3.4 MCP4018 디지털 가변저항

MCP4018T-503E (50kΩ, 128단계). MAX9295 MFP4 GPIO가 HIGH일 때만 동작한다 (VCC 공급).

| 디바이스 | 컨트롤 | 범위 | 기본값 | 설명 |
|----------|--------|------|--------|------|
| subdev2 | `mcp4018_wiper_ch0` | 0~127 | 63 | Port B 가변저항 |
| subdev2 | `mcp4018_wiper_ch1` | 0~127 | 63 | Port A 가변저항 |
| subdev3 | `mcp4018_wiper_ch2` | 0~127 | 63 | Port B 가변저항 |
| subdev3 | `mcp4018_wiper_ch3` | 0~127 | 63 | Port A 가변저항 |

### 3.5 DMA 센서 레지스터 접근

AP1302 DMA를 통해 AR0234 센서 레지스터를 직접 읽기/쓰기할 수 있다.

| 디바이스 | 컨트롤 | 플래그 | 설명 |
|----------|--------|--------|------|
| subdev2 | `dma_reg_write_ch0` | - | CH0 센서 레지스터 쓰기 |
| subdev2 | `dma_reg_write_ch1` | - | CH1 센서 레지스터 쓰기 |
| subdev2 | `dma_reg_read_ch0` | volatile, execute-on-write | CH0 센서 레지스터 읽기 |
| subdev2 | `dma_reg_read_ch1` | volatile, execute-on-write | CH1 센서 레지스터 읽기 |
| subdev3 | `dma_reg_write_ch2` | - | CH2 센서 레지스터 쓰기 |
| subdev3 | `dma_reg_write_ch3` | - | CH3 센서 레지스터 쓰기 |
| subdev3 | `dma_reg_read_ch2` | volatile, execute-on-write | CH2 센서 레지스터 읽기 |
| subdev3 | `dma_reg_read_ch3` | volatile, execute-on-write | CH3 센서 레지스터 읽기 |

값 인코딩 (32-bit): `[31:16] = 레지스터 주소, [15:0] = 데이터`

DMA 읽기 절차:
1. 읽을 주소를 상위 16비트에 넣어 `-c` (set)로 전달
2. 결과를 `-C` (get)로 읽기 — 상위 16비트=주소, 하위 16비트=값

```bash
# 직접 사용 예 (chip ID 읽기)
v4l2-ctl -d /dev/v4l-subdev2 -c dma_reg_read_ch0=$((0x3000 << 16))
v4l2-ctl -d /dev/v4l-subdev2 -C dma_reg_read_ch0
# 출력: dma_reg_read_ch0: 805309014 (= 0x30000A56 → val=0x0A56)
```

DMA 쓰기 절차:
```bash
# test pattern 켜기 (reg=0x3070, val=0x0001)
v4l2-ctl -d /dev/v4l-subdev2 -c dma_reg_write_ch0=$((0x30700001))
```

## 3.6) FPS 제어 (Frame Sync)

### FSYNC 기반 프레임 레이트 제어

이 드라이버는 AP1302 펌웨어에서 직접 FPS를 설정하지 않고, **GPIO를 통한 FSYNC(Frame Sync) 신호**로 프레임 레이트를 제어한다.

#### 동작 원리

1. **FPS 설정** (V4L2 Frame Interval)
   ```bash
   v4l2-ctl -d /dev/v4l-subdev2 --set-parm=30  # 30 FPS
   v4l2-ctl -d /dev/v4l-subdev2 --set-parm=15  # 15 FPS
   v4l2-ctl -d /dev/v4l-subdev2 --set-parm=60  # 60 FPS
   ```

2. **FSYNC 신호 생성** (`max9296_fsync` 커널 스레드)
   - GPIO를 통해 주기적인 펄스 신호 생성
   - 주기 = `1,000,000 / fps` (마이크로초)
   - 펄스 폭: HIGH 1ms, LOW (주기 - 1ms)

3. **타이밍 예시**
   ```
   30 FPS:  HIGH 1.0ms + LOW 32.3ms = 33.3ms 주기
   15 FPS:  HIGH 1.0ms + LOW 65.7ms = 66.7ms 주기
   60 FPS:  HIGH 1.0ms + LOW 15.7ms = 16.7ms 주기
   120 FPS: HIGH 1.0ms + LOW 7.3ms  = 8.3ms 주기
   ```

4. **AP1302 동작**
   - FSYNC 신호의 rising edge마다 새 프레임 캡처 시작
   - 펌웨어가 센서(AR0234)를 FSYNC에 동기화

#### 지원 FPS 범위

- 공통 최소값: 1 FPS
- 1920x1080, 1280x720: 최대 30 FPS
- 640x360: 일반 모듈에서 최대 120 FPS 요청 가능. 별도 qualification 모듈은 없다.
- 120은 요청 허용 상한이며 `KEEP` 경로 과거 실측 113~115 FPS는 엄격 기준
  118.8 FPS를 통과하지 못했다. 따라서 정확한 120 FPS 전달을 보장하지 않는다.
- 모든 모드의 `0x500c` 노출 쓰기 안전 상한: 30 FPS

#### 코드 위치

- FSYNC 스레드: `max9296.c:2373-2502` (`max9296_fsync`)
- FPS 저장: `max9296.c:1949` (`max9296_s_frame_interval`)
- GPIO 초기화: `max9296.c:2834-2842`
- 스레드 시작: `max9296.c:2971`

#### FPS 확인

```bash
# 현재 FPS 확인
v4l2-ctl -d /dev/v4l-subdev2 --get-parm

# 출력 예:
# Streaming Parameters Video Capture:
#   Frames per second: 30.000 (30/1)
```

#### 주의사항

- FPS 변경은 스트리밍 시작 전에 설정하는 것을 권장
- 듀얼 채널 모드에서는 양쪽 채널이 동일한 FSYNC 신호를 공유
- FSYNC GPIO가 없으면 FPS 제어가 불가능 (Device Tree 확인 필요)

## 4) v4l2-ctl 기본 사용

### 4.0 현재값 스냅샷/원복(권장)

테스트/튜닝 중에는 flip, gain_chX, exp_time(_chX) 같은 값이 누적되어 “현재 상태가 기본값이 아닌 상태”가 되기 쉽다.
아래처럼 스냅샷을 떠두면 언제든 원복할 수 있다.

1) 스냅샷 저장

```bash
v4l2-ctl -d /dev/v4l-subdev2 --list-ctrls --list-ctrls-menus > /tmp/subdev2.ctrls.before.txt
v4l2-ctl -d /dev/v4l-subdev3 --list-ctrls --list-ctrls-menus > /tmp/subdev3.ctrls.before.txt
```

2) “기본값으로 원복” 예시(필요한 항목만)

```bash
# 채널별(커스텀) 기본값
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=brightness_ch0=0,brightness_ch1=0,contrast_ch0=0,contrast_ch1=0,saturation_ch0=4096,saturation_ch1=4096
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=gain_ch0=256,gain_ch1=256
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=hflip_ch0=0,hflip_ch1=0,vflip_ch0=0,vflip_ch1=0
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=lsc_ch0=16383,lsc_ch1=16383

sudo v4l2-ctl -d /dev/v4l-subdev3 --set-ctrl=brightness_ch2=0,brightness_ch3=0,contrast_ch2=0,contrast_ch3=0,saturation_ch2=4096,saturation_ch3=4096
sudo v4l2-ctl -d /dev/v4l-subdev3 --set-ctrl=gain_ch2=256,gain_ch3=256
sudo v4l2-ctl -d /dev/v4l-subdev3 --set-ctrl=hflip_ch2=0,hflip_ch3=0,vflip_ch2=0,vflip_ch3=0
sudo v4l2-ctl -d /dev/v4l-subdev3 --set-ctrl=lsc_ch2=16383,lsc_ch3=16383

```

3) 원복 후 확인

```bash
v4l2-ctl -d /dev/v4l-subdev2 --get-ctrl=exp_time,gain_ch0,gain_ch1,brightness_ch0,brightness_ch1,contrast_ch0,contrast_ch1,saturation_ch0,saturation_ch1,hflip_ch0,hflip_ch1,vflip_ch0,vflip_ch1,lsc_ch0,lsc_ch1
v4l2-ctl -d /dev/v4l-subdev3 --get-ctrl=exp_time,gain_ch2,gain_ch3,brightness_ch2,brightness_ch3,contrast_ch2,contrast_ch3,saturation_ch2,saturation_ch3,hflip_ch2,hflip_ch3,vflip_ch2,vflip_ch3,lsc_ch2,lsc_ch3
```

### 4.1 컨트롤 목록 확인

```bash
v4l2-ctl -d /dev/v4l-subdev2 --list-ctrls --list-ctrls-menus
v4l2-ctl -d /dev/v4l-subdev3 --list-ctrls --list-ctrls-menus
```

권장: 보드에서 결과를 파일로 남기기

```bash
v4l2-ctl -d /dev/v4l-subdev2 --list-ctrls --list-ctrls-menus > /tmp/subdev2.ctrls.txt
v4l2-ctl -d /dev/v4l-subdev3 --list-ctrls --list-ctrls-menus > /tmp/subdev3.ctrls.txt
```

확인 포인트(문서/스크립트 작성 시 기준)
- `gain_chX`, `exp_time`, `brightness_chX`, `contrast_chX`, `saturation_chX`, `lsc_chX`의 `min/max/default` 값
- 커스텀 채널 컨트롤이 실제로 보이는지
  - subdev2: `*_ch0`, `*_ch1`
  - subdev3: `*_ch2`, `*_ch3`
- `ae_on_chX` 값(1/0의 의미)

예시(참고용)
```text
User Controls

exp_time (int) : min=0 max=... step=1 default=10000 value=20000
ae_on_ch0 (bool) : default=1 value=1
gain_ch0 (int) : min=0 max=... step=1 default=256 value=256

```

### 4.2 공통(커스텀) 컨트롤 설정 예시

```bash
# exp_time: 예) 20000 (30 FPS 이하에서만 레지스터 쓰기 허용)
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=exp_time=20000

# fixed12: contrast/saturation 1.0 (4096)
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=contrast_ch0=4096,contrast_ch1=4096,saturation_ch0=4096,saturation_ch1=4096

# brightness: default/mid-point는 list-ctrls에서 default 값을 확인 권장
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=brightness_ch0=0,brightness_ch1=0

# LSC: 1.0 근처(예: 0x3fff)
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=lsc_ch0=16383,lsc_ch1=16383
```

### 4.3 채널별(커스텀) 설정 예시

```bash
# /dev/v4l-subdev2 = ch0/ch1
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=gain_ch0=256,gain_ch1=512
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=hflip_ch0=1,hflip_ch1=0

# /dev/v4l-subdev3 = ch2/ch3
sudo v4l2-ctl -d /dev/v4l-subdev3 --set-ctrl=gain_ch2=256,gain_ch3=512
sudo v4l2-ctl -d /dev/v4l-subdev3 --set-ctrl=vflip_ch2=0,vflip_ch3=1
```

### 4.4 디지털 줌·중심 조준

```bash
# enable 전환은 STREAMOFF 상태에서만 가능
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=crop_enable=1

# 스트리밍 중에도 가능한 공통 배율 + 채널별 중심 tuple
sudo v4l2-ctl -d /dev/v4l-subdev2 \
  --set-ctrl=dz=200,dz_x_ch0=32768,dz_y_ch0=52000,dz_x_ch1=32768,dz_y_ch1=32768

# 모든 활성 채널을 같은 중심으로 바꾸는 공유 alias
sudo v4l2-ctl -d /dev/v4l-subdev2 \
  --set-ctrl=dz=150,dz_x=32768,dz_y=32768
```

`dz=150`은 1.50배, `dz=200`은 2.00배다. 출력 해상도는 그대로이며 선택한
중심 주변의 더 좁은 영역을 같은 출력 크기로 확대한다. 값은 드라이버 cache에
유지되어 스트림 재시작과 firmware 재로드 뒤 재적용된다. 단,
`crop_enable=false`이면 cache만 유지하고 crop 레지스터는 쓰지 않는다.

### 4.5 Auto/Manual 권장 순서

Auto가 켜져 있으면 manual 값이 즉시 덮어써질 수 있다. 실사용 권장 순서:

```bash
# AE를 manual로 (ch0/ch1)
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=ae_on_ch0=0,ae_on_ch1=0

# 이후 채널별 exp_time/gain 값을 설정(예: ch0)
sudo v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=ae_on_ch0=0,exp_time_ch0=20000,gain_ch0=512
```

채널별로 AE on/off를 하고 싶으면 `ae_on_chX` / `auto_gain_chX`를 사용한다.

## 5) 운영 절차(서비스/스크립트와 함께 안전하게 쓰기)

이 시스템은 `cam-operate`(systemd)와 여러 감시 스크립트가 카메라 앱을 자동 재시작/초기화할 수 있다.
V4L2 컨트롤을 수동으로 만질 때는 아래처럼 “자동 루프”를 잠깐 멈추는 것을 권장한다.

### 5.0 패키지 JSON과 해상도 전환

패키지 기본 `edgeconf_pim_base.json`은 `640x360@30`, crop false, `dz=100`,
모든 중심 32768이다. 기존 장비에 일부 키만 안전하게 병합할 때는 설치되는
`/opt/pim/config/max9296_640x360_fragment.json`을 사용한다. fragment에는
credential, 채널 enable, bitrate 같은 장비별 값이 없다.

```bash
CONF=/root/shared_v/edgeconf_pim.json
FRAGMENT=/opt/pim/config/max9296_640x360_fragment.json

jq -e '.VHL_CAM|type == "object"' "$CONF"
jq --slurpfile patch "$FRAGMENT" \
  '.VHL_CAM = (.VHL_CAM * $patch[0])' "$CONF" >"$CONF.360p.tmp"
jq -e . "$CONF.360p.tmp"
```

원본을 백업한 뒤 같은 파일시스템에서 원자 교체하고
`cam_hard_reset.sh -s -S` 또는 `init_cam.sh`를 실행한다. FHD는
`cam_width=1920, cam_height=1080`, HD는 `1280,720`, 360p는 `640,360`으로
선택하며 crop 키는 어느 해상도에서도 독립적으로 쓸 수 있다. 운영 FPS 상한은
FHD/HD 30, 360p 120이다. 패키지 기본값은 30이며 120 FPS 시험 시 같은 모듈에서
`max9296_640x360_120_fragment.json`을 적용하고 하드 리셋한다.

```bash
CONF=/root/shared_v/edgeconf_pim.json
FRAGMENT=/opt/pim/config/max9296_640x360_120_fragment.json
TMP=${CONF}.120.tmp

jq --slurpfile patch "$FRAGMENT" \
  '.VHL_CAM = (.VHL_CAM * $patch[0])' "$CONF" >"$TMP"
jq -e . "$TMP"
install -m 0640 "$TMP" "$CONF"
rm -f "$TMP"
/opt/pim/bin/cam_hard_reset.sh -s -S
```

이 fragment는 채널 enable, bitrate와 장비별 경로는 보존하고 640x360@120,
crop false, dz 100, 중심 32768, AE auto, flash delay 0을 설정한다. 활성 AR0234의
delay 128은 보드 A/B에서 CSI를 약 46 FPS로 낮췄고 ch0 delay만 0으로 바꾸자 약
112~113 FPS로 회복됐다. 현재 정상 실측은 약 113~115 FPS이며 엄격 118.8 FPS
기준은 통과하지 못하므로 정확한 120 FPS 전달을 보장하지 않는다.

### 5.1 테스트/튜닝 시(권장)

```bash
# 1) 자동 운영 데몬 중지
sudo systemctl stop cam-operate

# 2) 앱/헬퍼 종료(필요시)
sudo /opt/pim/bin/kill_test.sh
```

이 상태에서 `v4l2-ctl`로 컨트롤을 바꾸고 확인한다.

### 5.2 모듈 리셋이 필요할 때

`init_cam.sh`는 카메라 앱 종료 + `rmmod/modprobe`(max9296, imx8-media-dev) + 앱 재기동까지 수행한다.

```bash
sudo /opt/pim/bin/init_cam.sh
```

## 6) 레거시 i2c 스크립트와의 관계(참고)

기존 스크립트는 그대로 유지되므로, 아래 스크립트가 실행되면 V4L2로 설정한 값이 덮일 수 있다.

- `cam_ae_on.sh` / `cam_ae_off.sh` : `0x5002` 직접 write
- `cam_manual_gain.sh` : `0x5006` 직접 write
- `cam_manual_exp_time.sh` : `0x500c` 직접 write
- `cam_rotate_setting.sh` : `0x100c` 직접 write
- `cam_ae_setting.sh` : `0x5100` 직접 write

직접 I2C 스크립트는 드라이버의 30 FPS exposure guard와 cache/fingerprint를
우회한다. 특히 `cam_manual_exp_time.sh`는 31 FPS 이상 고속 시험에서
사용하지 않는다. 운영 경로는 V4L2 컨트롤만 사용하고 위 스크립트는 정지된
디버그 환경의 레거시 도구로 제한한다.

## 7) LED Flash 제어

AR0234 센서의 LED Flash는 V4L2 컨트롤 또는 DMA를 통해 제어한다.

```bash
# V4L2 컨트롤로 제어 (led_flash_chX)
# 켜기: bit8=1(enable), bit7:0=delay → 0x0103 = 259
v4l2-ctl -d /dev/v4l-subdev2 -c led_flash_ch0=259

# 끄기
v4l2-ctl -d /dev/v4l-subdev2 -c led_flash_ch0=0

# DMA로 직접 제어 (레지스터 0x3270)
./cam_dma_write.sh 0 0x3270 0x0103   # 켜기
./cam_dma_read.sh 0 0x3270           # 확인
./cam_dma_write.sh 0 0x3270 0x0000   # 끄기
```

주의: LED Flash 레지스터(0x3270)는 상태 비트가 추가로 반영될 수 있다. 검증 시 `mask=0x01ff` 기준으로 비교한다.

## 8) DMA 센서 레지스터 접근 (셸 스크립트)

V4L2 DMA 컨트롤을 편리하게 사용하기 위한 헬퍼 스크립트가 제공된다.

| 스크립트 | 위치 | 용도 |
|----------|------|------|
| `cam_dma_read.sh` | `/opt/pim/bin/` | V4L2 DMA 레지스터 읽기 |
| `cam_dma_write.sh` | `/opt/pim/bin/` | V4L2 DMA 레지스터 쓰기 |
| `cam_sensor_frame_sync.sh` | `/opt/pim/bin/` | AR0234 FRAME_COUNT 채널 간 증분 비교 |
| `cam_ap1302_dma_verify.sh` | `/opt/pim/bin/` | I2C 직접 DMA read/write (교차 검증용) |
| `cam_ar0234_led_flash_read.sh` | `/opt/pim/bin/` | I2C 직접 LED flash 읽기 |
| `cam_ar0234_led_flash_write.sh` | `/opt/pim/bin/` | I2C 직접 LED flash 쓰기 |

### 8.1 DMA 읽기

```bash
# 사용법
cam_dma_read.sh <channel> <reg_hex>

# 채널 매핑: 0/1→subdev2, 2/3→subdev3 (자동)
cam_dma_read.sh 0 0x3000     # ch0 chip ID → val=0x0a56
cam_dma_read.sh 1 0x3000     # ch1 chip ID
cam_dma_read.sh 2 0x3000     # ch2 chip ID
cam_dma_read.sh 3 0x3000     # ch3 chip ID
```

### 8.2 DMA 쓰기

```bash
# 사용법
cam_dma_write.sh <channel> <reg_hex> <val_hex>

# test pattern 켜기/끄기
cam_dma_write.sh 0 0x3070 0x0001   # test pattern on
cam_dma_read.sh 0 0x3070           # readback 확인 → val=0x0001
cam_dma_write.sh 0 0x3070 0x0000   # 원복
```

### 8.3 DMA 검증 절차

```bash
# 1) chip ID 확인 (전 채널)
cam_dma_read.sh 0 0x3000   # 기대값: val=0x0a56
cam_dma_read.sh 1 0x3000
cam_dma_read.sh 2 0x3000
cam_dma_read.sh 3 0x3000

# 2) write/readback 검증
cam_dma_write.sh 0 0x3070 0x0001
cam_dma_read.sh 0 0x3070           # val=0x0001 → PASS
cam_dma_write.sh 0 0x3070 0x0000   # 원복
cam_dma_read.sh 0 0x3070           # val=0x0000 → PASS
```

주의사항:
- DMA 읽기/쓰기는 카메라 스트리밍 중에도 사용할 수 있다
- DMA 접근은 AP1302 ISP 동작에 영향을 주지 않는다

### 8.4 센서 프레임 카운터 동기 비교

AR0234 `R0x303A FRAME_COUNT`를 반복해서 읽고, 첫 측정 이후 각 채널의
누적 증가량을 비교한다. 16비트 카운터의 `0xffff` 순환은 자동 처리한다.

> **현재 제품 환경의 측정 한계:** AP1302 DMA/SIPM 경유 시험에서는 이
> 레지스터가 `0x0000` 또는 `0xffff`로 반복 관측되어
> `RESET_OR_INVALID`로 판정됐다. SIPM 오류가 없더라도 이 값만 반복되면
> 유효한 프레임 카운터로 간주하지 않으며, 센서 동기 판정에 사용해서는
> 안 된다. 이 스크립트는 카운터가 경과시간상 가능한 값으로 연속 증가하는
> 장치와 펌웨어에서만 프레임 수 비교 진단으로 사용한다.

`pim-camera-v016`에서 실측한 내용(2026-08-14):

| 상태 | `0x303A` 관측 | 판정 |
|---|---|---|
| 유휴(비스트리밍) | `0xffff` 고정 | `RESET_OR_INVALID` |
| 스트리밍 중 | `0x0000` ↔ `0xffff` 교대 | `RESET_OR_INVALID` |

**같은 DMA 경로의 다른 레지스터는 정상이다.** `0x3000`(chip id)은 4채널
모두 `0x0a56`, `0x3002`는 `0x0040`, `0x300a`(frame_length_lines)는
`0x09d9`/`0x09dc`/`0x09db`로 채널마다 다른 실제 값이 나온다. 16비트 읽기의
양 극단만 돌아온다는 것은 경로 문제가 아니라 **이 레지스터가 이 터널로
응답하지 않는다**는 뜻이다.

고정 sentinel은 표본 간 증가량이 0이라 예전에는 `NO_PROGRESS`로 떨어졌는데,
그 문구("센서가 프레임을 내지 않았다")는 뒷받침할 수 없는 하드웨어 주장이다.
레지스터가 응답하지 않는 것과 센서가 멈춘 것은 구분되지 않는다. 그래서 관측이
전부 `{0x0000, 0xffff}`이면 증가량 산술과 무관하게 `RESET_OR_INVALID`로
판정한다. sentinel이 아닌 값에서 멈춘 경우는 여전히 `NO_PROGRESS`다.

**판정은 채널별로 추적한다.** run 전체를 하나의 플래그로 두면 정상 채널
하나가 플래그를 지워, 침묵한 채널이 "증가량 0인 정상 카운터"로 취급된다.
그러면 옆 채널의 실제 증가가 `MISMATCH`로 보고되어 — 응답하지 않는
레지스터를 근거로 "채널이 어긋났다"고 단정하게 된다. 비교 대상 채널 중
하나라도 sentinel만 돌려주면 비교 전체를 무효로 본다.

요약 줄의 `sentinel_only=`에는 침묵한 채널 목록이 들어간다
(`sentinel_only=ch0` / `sentinel_only=none`). 채널별 상세는
`channel_summary`의 `sentinel_only=0|1`에 나온다.

```bash
# 전 채널, 1초 간격, baseline 포함 10회
cam_sensor_frame_sync.sh

# 한 AP1302에 연결된 ch0/ch1만 0.5초 간격으로 20회
cam_sensor_frame_sync.sh 0,1 0.5 20

# 두 AP1302를 포함한 전 채널을 2초 간격으로 30회
cam_sensor_frame_sync.sh 0,1,2,3 2 30
```

결과 의미:

- `MATCH`: 모든 채널의 누적 프레임 증가량이 같다
- `NEAR`: 1프레임 차이. 순차 DMA 읽기가 프레임 경계를 넘었을 수 있어 재측정 필요
- `MISMATCH`: 누적 증가량 차이가 2프레임 이상
- `NO_PROGRESS`: 측정 중 어느 채널도 프레임 카운터가 증가하지 않음
- `RESET_OR_INVALID`: 모듈러 증가량이 경과시간의 물리적 상한을 초과함. 센서
  카운터 재초기화 또는 DMA 무효 읽기가 있었으므로 동기 판정에서 제외

`raw_offset`은 현재 16비트 카운터의 기준 채널 대비 차이이고, `drift`는
baseline 이후 누적 증가량 차이다. 센서 초기화 시점이 다를 수 있으므로 동기
유지 판정에는 `raw_offset`보다 `drift`를 우선한다. `read_window_ms`가 한 프레임
주기보다 길면 같은 순간의 카운터를 읽은 것이 아니므로 프레임 위상 판정에는
사용할 수 없다. 이 측정은 프레임 수 일치 여부를 확인하며 노출/라인 위상까지
증명하지는 않는다.

정상 wrap은 이전 값과 현재 값의 모듈러 증가량이 경과시간상 가능한 경우에만
인정한다. 예를 들어 `0xfffe → 0x0000`은 2프레임 증가지만 `0x0016 → 0x0012`는
65532프레임 증가가 되어 `RESET_OR_INVALID`로 분류된다. 이때 `valid_total`은
연속성이 확인된 구간만 합산하고 `drift=NA`로 바뀐다. 최종 결과도
`MISMATCH` 대신 `RESET_OR_INVALID`가 되어 잘못된 65536프레임 누적을 방지한다.

증가량의 기본 물리 상한은 120fps와 측정 오차 여유 8프레임이다. 다른 센서
조건에서는 환경변수로 조정할 수 있다.

```bash
MAX_SENSOR_FPS=60 FRAME_STEP_MARGIN=8 cam_sensor_frame_sync.sh 0,1 1 30
```

## 9) MCP4018 가변저항

```bash
# 최소 저항 (0Ω)
v4l2-ctl -d /dev/v4l-subdev2 -c mcp4018_wiper_ch0=0

# 최대 저항 (50kΩ)
v4l2-ctl -d /dev/v4l-subdev2 -c mcp4018_wiper_ch0=127

# 중간값 (기본, ~25kΩ)
v4l2-ctl -d /dev/v4l-subdev2 -c mcp4018_wiper_ch0=63
```

## 10) 아직 미대체(갭)

- `cam_manual_iso.sh`는 `0x5008`을 직접 write한다.
  - 이 레지스터의 의미/스케일이 확정되면 V4L2 컨트롤로 추가할 수 있다.
