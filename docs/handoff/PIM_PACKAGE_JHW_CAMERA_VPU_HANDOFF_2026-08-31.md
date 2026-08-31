# PIM Camera/VPU 시험 패키지 설치 및 검증 가이드

## 1. 전달 목적과 범위

이 문서는 기존 `pim-package`를 사용하는 동일 사양 시험 보드에서 최신 카메라/VPU
기능을 설치하고 검증하기 위한 절차다. 전달물은 아래 DEB와 이 문서 두 파일이며,
소스 저장소 통합과 운영 장비 일괄 배포는 이번 범위가 아니다.

검증 대상은 다음과 같다.

- 최신 `gstApp`의 single-channel/single-CSI 동작
- MAX9296/AP1302의 1920x1080, 1280x720, 640x360 출력
- 출력 해상도와 독립적인 digital crop 및 중심 조준
- 채널별 VPU H.264 파라미터
- 640x360@30의 sensor/ISP/CSI/ISI FPS와 자원 사용량
- 실제 ISI RGB565 frame과 RTSP 영상의 녹색 화면 여부

120 FPS는 연구용 qualification 항목이며 이 전달본의 production 합격 기준이 아니다.
production 기준은 모든 출력 모드에서 30 FPS다.

## 2. 전달 파일 식별

| 항목 | 값 |
|---|---|
| 파일 | `pim-mp_0.6.3+jhw.camera1_arm64.deb` |
| 크기 | 30,763,272 bytes |
| SHA-256 | `901c4caa93a0aee817e6f51bbd74f20e3c07d5046e2eeeda979d54a13a1c2bd7` |
| Package | `pim-mp` |
| Version | `0.6.3+jhw.camera1` |
| Architecture | `arm64` |
| 대상 SoC | i.MX8MP |
| 대상 OS | Ubuntu 20.04 |
| 대상 커널 | `5.10.35-lts-5.10.y+g2fce14defc04` |

설치 전에 반드시 체크섬을 확인한다.

```bash
cd /root/camtest/handoff-camera1-20260831
printf '%s  %s\n' \
  '901c4caa93a0aee817e6f51bbd74f20e3c07d5046e2eeeda979d54a13a1c2bd7' \
  'pim-mp_0.6.3+jhw.camera1_arm64.deb' | sha256sum -c -
```

예상 결과:

```text
pim-mp_0.6.3+jhw.camera1_arm64.deb: OK
```

## 3. 설치 중단 조건

다음 중 하나라도 해당하면 `dpkg -i`를 실행하지 않는다.

- `uname -m`이 `aarch64`가 아님
- `uname -r`이 대상 커널 문자열과 정확히 다름
- Ubuntu 20.04가 아님
- 전달 DEB SHA-256 불일치
- 현재 사용 중인 이전 `pim-mp` DEB를 확보하지 못함
- edgeconf, ord/vcm 설정 및 defaultconf 백업 실패
- 카메라와 녹화를 중단할 수 없는 운영 장비

이 패키지의 `postinst`는 카메라 파일만 교체하지 않는다. 커널 모듈, 라이브러리,
systemd service, 일부 시스템 설정, 기본 설정 파일과 심볼릭 링크도 처리한다. 최초
시험은 반드시 지정된 시험 보드에서 수행한다.

## 4. 주요 변경사항

### 4.1 카메라 출력

| 카메라당 출력 | single V4L2 | dual-wide V4L2 | production FPS |
|---|---|---|---:|
| 1920x1080 | 1920x1080 | 3840x1080 | 30 |
| 1280x720 | 1280x720 | 2560x720 | 30 |
| 640x360 | 640x360 | 1280x360 | 30 |

`VHL_CAM.cam_width`와 `cam_height`는 AP1302/CSI 출력 크기를 선택한다. 현재
640x360은 AR0234 센서의 native 640x360 readout이 아니다. 센서는 FHD readout을
유지하고 AP1302/CSI 출력이 640x360으로 축소된다. 이 설명은 `crop_enable=false`,
`dz=100` 기준이다. 공급자 보드 Case A에서 AR0234 window는
X `0x0004..0x0783`(1920), Y `0x0040..0x0477`(1080)으로 실측됐다.

### 4.2 Digital crop

| edgeconf 키 | 범위·기본값 | 의미 |
|---|---|---|
| `crop_enable` | `false` | false이면 crop 관련 I2C 쓰기 없음 |
| `dz` | 100~300, 기본 100 | bus 공통 배율, 100=1.0x, 150=1.5x, 200=2.0x |
| `dz_x`, `dz_y` | 0~65535, 기본 32768 | 채널별 정규화 중심 |

해상도와 crop은 독립이다. 예를 들어 HD에서 `dz=200`을 적용해도 출력은
1280x720이며 화면 안의 시야만 2배 확대된다. 640x360에서 crop을 끄면
640x360 전체 시야 축소 출력이다. 다만 인터페이스와 출력 크기가 독립이라는 뜻이지
sensor readout window가 항상 고정된다는 뜻은 아니다. 공급자 보드의 HD+1.5x Case E는
출력 1280x720을 유지하면서 AR0234 window가 중앙 1280x720으로 바뀌었다.

실제 드라이버 매핑은 다음과 같다.

- `dz` -> AP1302 `0x1010`, 8.8 fixed-point로 변환
- `0x1012` -> 줌 전이 속도이며 즉시 적용값 `0x8000` 사용
- `0x1014` -> optical zoom factor이므로 이번 구현에서 미사용
- 실제 중심 -> `0x118c`/`0x118e`

`crop_enable=false`에서는 `0x1010`, `0x1012`, `0x118c`, `0x118e` 쓰기를
발행하지 않는다. crop-enabled 상태로 prepare한 뒤에는 `dz`, `dz_x_chX`,
`dz_y_chX`를 런타임 변경할 수 있다. 스트리밍 중 `crop_enable` 전환은
`-EBUSY`이며, enable을 바꾼 뒤에는 `cam_hard_reset.sh -s -S` 또는
`init_cam.sh`로 firmware를 다시 prepare한다. gstApp 재시작만으로는 충분하지 않다.

### 4.3 노출 안전

- `exp_time`과 `exp_time_chN`은 AP1302 `0x500c`에 연결된다.
- 30 FPS 초과에서 수동 exposure I2C 쓰기는 실행 전에 `-EBUSY`로 거부된다.
- 30 FPS 이하의 기존 AE, gain, exposure 동작은 유지된다.
- SoC 정지 이력이 있는 수동 WB `0x510a` 쓰기는 추가하지 않았다.

### 4.4 VPU H.264 설정

아래 키는 채널별 `[record, rtsp]` 두 원소 배열이다. 배열 길이가 2가 아니면
gstApp이 해당 키를 무시하고 기본값을 사용한다.

| 키 | 범위 | 기본값 | 의미 |
|---|---:|---:|---|
| `bps` | 0 이상 | `[2048,2048]` | kbps, 0은 encoder 자동 rate control |
| `gop` | 0~300 | `[0,0]` | 0은 현재 FPS로 치환하여 약 1초 간격 |
| `profile` | 9~12 | `[9,9]` | 9 Baseline, 10 Main, 11 High, 12 High10 |
| `quant` | -1~51 | `[-1,-1]` | 초기 QP, -1 자동 |
| `qp_min` | 0~51 | `[0,0]` | 0 미설정 |
| `qp_max` | 0~51 | `[0,0]` | 0 미설정 |

위 `profile` 번호와 범위는 H.264 기준이다. `enc="h265"`에서는 codec별 허용값과
기본값이 다르므로 H.264 profile 번호를 그대로 넣지 않는다. Case H는 이 모호성을
없애기 위해 `enc="h264"`를 명시한다.

single-encoder mode에서는 실제 RTSP slot이 record slot 값에 맞춰진다.

## 5. 설치 전 점검과 백업

### 5.1 환경 확인

```bash
set -e
test "$(uname -m)" = 'aarch64'
test "$(uname -r)" = '5.10.35-lts-5.10.y+g2fce14defc04'
. /etc/os-release
test "$ID" = 'ubuntu'
test "$VERSION_ID" = '20.04'
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' pim-mp
df -h / /root
```

### 5.2 이전 DEB 확보

기존 설치본의 DEB를 아래 이름으로 준비한다. 설치된 파일만 있고 이전 DEB가 없으면
중단한다.

```bash
BACKUP=/root/pim-handoff-backup-20260831
install -d -m 0700 "$BACKUP"
install -m 0600 /path/to/current-team-pim-mp.deb \
  "$BACKUP/previous-pim-mp.deb"
dpkg-deb -f "$BACKUP/previous-pim-mp.deb" Package Version Architecture
```

### 5.3 설정과 현재 상태 백업

PIM 장비의 live 설정 경로는 `/root/shared_v/edgeconf_pim.json`을 기준으로 한다.
파일명이 다르면 실제 `edgeconf*.json`을 확인한 뒤 이후 명령의 `EDGE`만 정확한 경로로
바꾼다.

```bash
set -e
BACKUP=/root/pim-handoff-backup-20260831
EDGE=/root/shared_v/edgeconf_pim.json
test -f "$EDGE"
test -f /root/shared_v/ord_vcm_conf.json
test -f /etc/defaultconf.json

cp -a "$EDGE" "$BACKUP/edgeconf_pim.json"
cp -a /root/shared_v/ord_vcm_conf.json "$BACKUP/ord_vcm_conf.json"
cp -a /etc/defaultconf.json "$BACKUP/defaultconf.json"
jq empty "$BACKUP/edgeconf_pim.json"
jq empty "$BACKUP/ord_vcm_conf.json"

{
  uname -a
  cat /etc/os-release
  dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' pim-mp
  systemctl is-active cam-operate.service || true
  pgrep -a gstApp || true
  sha256sum "$EDGE" /root/shared_v/ord_vcm_conf.json /etc/defaultconf.json
  sha256sum /usr/local/bin/gstApp /opt/pim/driver/max9296.ko || true
  modinfo -F vermagic max9296 || true
} > "$BACKUP/preinstall-state.txt" 2>&1
```

## 6. 설치

```bash
set -e
WORK=/root/camtest/handoff-camera1-20260831
cd "$WORK"
printf '%s  %s\n' \
  '901c4caa93a0aee817e6f51bbd74f20e3c07d5046e2eeeda979d54a13a1c2bd7' \
  'pim-mp_0.6.3+jhw.camera1_arm64.deb' | sha256sum -c -

systemctl stop cam-operate.service
dpkg -i ./pim-mp_0.6.3+jhw.camera1_arm64.deb \
  2>&1 | tee ./install-pim-mp-camera1.log
depmod -a
ldconfig

dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' pim-mp
modinfo -F vermagic max9296
/opt/pim/bin/cam_hard_reset.sh -s -S \
  2>&1 | tee ./postinstall-hard-reset.log
```

필수 결과:

```text
pim-mp 0.6.3+jhw.camera1 arm64
5.10.35-lts-5.10.y+g2fce14defc04 ...
하드 리셋 완료 (CSI2 + ISI 재바인드 포함)
```

설치 스크립트는 기존 edgeconf에 누락된 crop/VPU 키를 backfill한다. 대부분의 기존
non-null 값은 보존한다. camera3부터 `led_flash.flash_delay`도 명시값을 보존하고,
키가 누락된 레거시 설정에만 128을 backfill한다. 활성 AR0234의 delay 128은
640x360@120 전달률을 낮추므로 고속 fragment가 지정한 0을 설치 중 덮어쓰면 안 된다.
설치 전후 비교는 다음과 같이 확인한다.

```bash
diff -u /root/pim-handoff-backup-20260831/edgeconf_pim.json \
  /root/shared_v/edgeconf_pim.json || true
jq '.VHL_CAM | {app,cam_width,cam_height,fps,i2c2,i2c1}' \
  /root/shared_v/edgeconf_pim.json
```

## 7. 설치 파일 무결성 확인

```bash
sha256sum \
  /usr/local/bin/gstApp \
  /opt/pim/driver/max9296.ko \
  /usr/lib/gstreamer-1.0/libgstvpu.so \
  /usr/lib/libfslvpuwrap.so.3.0.0 \
  /opt/pim/bin/update_edgeconf.sh \
  /opt/pim/bin/cam_fps_stack.sh \
  /opt/pim/bin/cam_360p_resource.sh \
  /opt/pim/bin/uyvy_frame_check.py \
  /opt/pim/bin/rgb565_frame_check.py \
  /opt/pim/config/edgeconf_pim_base.json \
  /opt/pim/config/max9296_640x360_fragment.json
```

예상 SHA-256:

| 파일 | SHA-256 |
|---|---|
| `gstApp` | `c816f84094f7d357c51a20b8c694ea198d0207fac68eca53128e5225b5ddafbe` |
| `max9296.ko` | `b27ae021fe4cb569ed6264712fabebb2a6b2cb6f5ab27278aebdb4113e09fc33` |
| `libgstvpu.so` | `d83594447b7dac184c019371c0c296b72345585913ed03adf6e0a56f60a38b27` |
| `libfslvpuwrap.so.3.0.0` | `03980af335703b0352a9a43f2dff62657671db5aaf822e476a415d5e762a4927` |
| `update_edgeconf.sh` | `086b971fac74fcff5ebfbd1c5b40c1d81f2011b21a8687069652b1a3a29737e1` |
| `cam_fps_stack.sh` | `0c517795c947105e50951fb9743cb1550bd0a65b2921024bf25ddbc2d209b21a` |
| `cam_360p_resource.sh` | `bade675c2ec06596a61fa6e6c9ff969c148b294dbd43dad6ba58ef358d41bcd6` |
| `uyvy_frame_check.py` | `b4b4d610c56175a836f6f19fe66bf9464ab5536b553e7363ef796a21d7ca9580` |
| `rgb565_frame_check.py` | `9dd626dda8ee4e98b770b45db13632f9ac490b5a07bedf027f53fd6cef268d6d` |
| `edgeconf_pim_base.json` | `847e8ad4a05e8ff452186a1be1e487ee10d876b62aef730144396ccd9d4075e9` |
| `max9296_640x360_fragment.json` | `e8d961af71e4f1f8f2fc2089706c8c7d1d5747c1d1c99d157fcac5e6f6f8646d` |

VPU plugin도 확인한다.

```bash
gst-inspect-1.0 vpuenc_h264
ldd /usr/local/bin/gstApp | grep -E 'not found|fslvpu|gst' || true
```

`not found`가 한 줄이라도 나오면 시험을 중단한다.

## 8. JSON 적용 공통 규칙

아래 예시는 기존 JSON을 입력으로 사용하고, 임시 파일의 JSON 문법이 정상일 때만 live
파일을 교체한다. 다른 설정을 포함한 샘플 JSON 전체로 덮어쓰지 않는다.

각 case 적용 뒤에는 다음을 실행한다.

```bash
/opt/pim/bin/cam_hard_reset.sh -s -S
pgrep -a gstApp
media-ctl -p
```

gstApp 실행 중에는 `/dev/video4`가 busy이므로 `v4l2-ctl --get-fmt-video`가
실패할 수 있다. capture node의 정확한 `RGBP` format/stride 확인은 9.4처럼 서비스를
중지한 독점 capture 구간에서 수행한다.

아래 A/B/E/H는 카메라 출력·crop·VPU만 검증하는 자격시험이다. MCP4018/LED flash가
없는 보드에서 기존 `led_flash.enable=true`를 그대로 두면 선택적 LED 제어의
`-ENXIO`가 camera/crop dmesg 판정에 섞일 수 있다. 따라서 각 case는 enabled
channel의 `led_flash.enable=false`를 명시적으로 적용한다. LED 자체를 검증할 때는 이
변경을 하지 말고 별도 시험으로 분리한다. 최종 단계에서는 반드시 백업한 운영값을
복원한다.

### 8.1 Case A: ch0만, 640x360@30, crop off

```bash
set -e
EDGE=/root/shared_v/edgeconf_pim.json
TMP=/root/shared_v/edgeconf_pim.json.handoff.tmp
jq '
  .VHL_CAM.app = "gstApp"
  | .VHL_CAM.cam_width = 640
  | .VHL_CAM.cam_height = 360
  | .VHL_CAM.fps = 30
  | .VHL_CAM.i2c2.crop_enable = false
  | .VHL_CAM.i2c2.dz = 100
  | .VHL_CAM.i2c2.ch0.enable = true
  | .VHL_CAM.i2c2.ch1.enable = false
  | .VHL_CAM.i2c1.ch2.enable = false
  | .VHL_CAM.i2c1.ch3.enable = false
  | .VHL_CAM.i2c2.ch0.led_flash.enable = false
  | .VHL_CAM.i2c2.ch1.led_flash.enable = false
  | .VHL_CAM.i2c2.ch0.dz_x = 32768
  | .VHL_CAM.i2c2.ch0.dz_y = 32768
' "$EDGE" > "$TMP"
jq empty "$TMP"
install -m 0640 "$TMP" "$EDGE"
rm -f "$TMP"
/opt/pim/bin/cam_hard_reset.sh -s -S
```

예상 capture 크기: `640x360`.

### 8.2 Case B: ch0+ch1, 각 640x360@30, crop off

```bash
set -e
EDGE=/root/shared_v/edgeconf_pim.json
TMP=/root/shared_v/edgeconf_pim.json.handoff.tmp
jq '
  .VHL_CAM.app = "gstApp"
  | .VHL_CAM.cam_width = 640
  | .VHL_CAM.cam_height = 360
  | .VHL_CAM.fps = 30
  | .VHL_CAM.i2c2.crop_enable = false
  | .VHL_CAM.i2c2.dz = 100
  | .VHL_CAM.i2c2.ch0.enable = true
  | .VHL_CAM.i2c2.ch1.enable = true
  | .VHL_CAM.i2c1.ch2.enable = false
  | .VHL_CAM.i2c1.ch3.enable = false
  | .VHL_CAM.i2c2.ch0.led_flash.enable = false
  | .VHL_CAM.i2c2.ch1.led_flash.enable = false
  | .VHL_CAM.i2c2.ch0.dz_x = 32768
  | .VHL_CAM.i2c2.ch0.dz_y = 32768
  | .VHL_CAM.i2c2.ch1.dz_x = 32768
  | .VHL_CAM.i2c2.ch1.dz_y = 32768
' "$EDGE" > "$TMP"
jq empty "$TMP"
install -m 0640 "$TMP" "$EDGE"
rm -f "$TMP"
/opt/pim/bin/cam_hard_reset.sh -s -S
```

예상 capture 크기: dual-wide `1280x360`.

### 8.3 HD/FHD 출력 선택

Case B의 채널 설정을 유지하고 아래 두 필드만 바꾼다.

```bash
# HD: 카메라당 1280x720, dual-wide 2560x720
jq '.VHL_CAM.cam_width=1280 | .VHL_CAM.cam_height=720' \
  /root/shared_v/edgeconf_pim.json > /root/shared_v/edgeconf_pim.json.handoff.tmp
jq empty /root/shared_v/edgeconf_pim.json.handoff.tmp
install -m 0640 /root/shared_v/edgeconf_pim.json.handoff.tmp \
  /root/shared_v/edgeconf_pim.json
rm -f /root/shared_v/edgeconf_pim.json.handoff.tmp
/opt/pim/bin/cam_hard_reset.sh -s -S

# FHD: 카메라당 1920x1080, dual-wide 3840x1080
jq '.VHL_CAM.cam_width=1920 | .VHL_CAM.cam_height=1080' \
  /root/shared_v/edgeconf_pim.json > /root/shared_v/edgeconf_pim.json.handoff.tmp
jq empty /root/shared_v/edgeconf_pim.json.handoff.tmp
install -m 0640 /root/shared_v/edgeconf_pim.json.handoff.tmp \
  /root/shared_v/edgeconf_pim.json
rm -f /root/shared_v/edgeconf_pim.json.handoff.tmp
/opt/pim/bin/cam_hard_reset.sh -s -S
```

### 8.4 Case E: HD@30, crop 1.5x

```bash
set -e
EDGE=/root/shared_v/edgeconf_pim.json
TMP=/root/shared_v/edgeconf_pim.json.handoff.tmp
jq '
  .VHL_CAM.cam_width = 1280
  | .VHL_CAM.cam_height = 720
  | .VHL_CAM.fps = 30
  | .VHL_CAM.i2c2.crop_enable = true
  | .VHL_CAM.i2c2.dz = 150
  | .VHL_CAM.i2c2.ch0.enable = true
  | .VHL_CAM.i2c2.ch1.enable = true
  | .VHL_CAM.i2c1.ch2.enable = false
  | .VHL_CAM.i2c1.ch3.enable = false
  | .VHL_CAM.i2c2.ch0.led_flash.enable = false
  | .VHL_CAM.i2c2.ch1.led_flash.enable = false
  | .VHL_CAM.i2c2.ch0.dz_x = 32768
  | .VHL_CAM.i2c2.ch0.dz_y = 32768
  | .VHL_CAM.i2c2.ch1.dz_x = 32768
  | .VHL_CAM.i2c2.ch1.dz_y = 32768
' "$EDGE" > "$TMP"
jq empty "$TMP"
install -m 0640 "$TMP" "$EDGE"
rm -f "$TMP"
/opt/pim/bin/cam_hard_reset.sh -s -S
```

출력 크기는 dual-wide `2560x720`으로 유지되고 시야만 1.5배 확대돼야 한다.

crop-enabled 상태의 런타임 조준 예:

```bash
v4l2-ctl -d /dev/v4l-subdev2 --list-ctrls | \
  grep -E 'crop_enable|dz|dz_x_ch0|dz_y_ch0'
v4l2-ctl -d /dev/v4l-subdev2 \
  -c dz=150,dz_x_ch0=40000,dz_y_ch0=40000
v4l2-ctl -d /dev/v4l-subdev2 \
  -c dz=150,dz_x_ch0=32768,dz_y_ch0=32768
```

### 8.5 Case H: VPU 설정

```bash
set -e
EDGE=/root/shared_v/edgeconf_pim.json
TMP=/root/shared_v/edgeconf_pim.json.handoff.tmp
jq '
  .VHL_CAM.app = "gstApp"
  | .VHL_CAM.enc = "h264"
  | .VHL_CAM.cam_width = 640
  | .VHL_CAM.cam_height = 360
  | .VHL_CAM.fps = 30
  | .VHL_CAM.i2c2.crop_enable = false
  | .VHL_CAM.i2c2.dz = 100
  | .VHL_CAM.i2c2.ch0.enable = true
  | .VHL_CAM.i2c2.ch1.enable = true
  | .VHL_CAM.i2c1.ch2.enable = false
  | .VHL_CAM.i2c1.ch3.enable = false
  | .VHL_CAM.i2c2.ch0.led_flash.enable = false
  | .VHL_CAM.i2c2.ch1.led_flash.enable = false
  | .VHL_CAM.i2c2.ch0.bps = [4096,1024]
  | .VHL_CAM.i2c2.ch0.gop = [0,60]
  | .VHL_CAM.i2c2.ch0.profile = [10,9]
  | .VHL_CAM.i2c2.ch0.quant = [-1,-1]
  | .VHL_CAM.i2c2.ch0.qp_min = [10,10]
  | .VHL_CAM.i2c2.ch0.qp_max = [40,40]
' "$EDGE" > "$TMP"
jq empty "$TMP"
install -m 0640 "$TMP" "$EDGE"
rm -f "$TMP"
/opt/pim/bin/cam_hard_reset.sh -s -S
journalctl -u cam-operate.service -b --since '-2 min' --no-pager | \
  grep -E 'bps|gop|profile|quant|qp_|encoder'
```

profile 번호는 codec별 의미가 다르므로 이 Case는 `enc="h264"`를 명시한다.
single-encoder mode(`dualEn=0`)에서는 ch0 RTSP의 유효값이 record 값인
`bps=4096`, `gop=30`, `profile=10`에 맞춰지는 것이 정상이다. 시험 후에는 백업
JSON 또는 승인된 production JSON으로 `enc`를 포함한 모든 운영값을 복원한다.

## 9. FPS·자원·영상 검증

### 9.1 Sensor에서 ISI까지 FPS

```bash
EVIDENCE=/root/camtest/handoff-camera1-20260831/evidence
install -d -m 0700 "$EVIDENCE"
/opt/pim/bin/cam_fps_stack.sh \
  -c ch01 -d 20 -i 2 -D -L HANDOFF_640X360_30 -R 30 | \
  tee "$EVIDENCE/cam-fps-stack.txt"
```

30 FPS 합격 판단에서는 `pass120` 값을 사용하지 않는다. sensor/ISP/CSI가 약 30 FPS를
지속하는지, ISI 신뢰 여부와 drop/overflow가 없는지를 함께 본다.

### 9.2 CPU/RSS/DDR/온도

```bash
/opt/pim/bin/cam_360p_resource.sh \
  -d 20 -v /dev/video4 \
  -o /root/camtest/handoff-camera1-20260831/evidence/resources.txt
```

### 9.3 gstApp와 RTSP

```bash
systemctl is-active cam-operate.service
pgrep -a gstApp
ss -ltnp | grep ':8554'
journalctl -u cam-operate.service -b --since '-5 min' --no-pager | \
  tee /root/camtest/handoff-camera1-20260831/evidence/gstapp-journal.txt
```

gstApp 로그에 표시된 장비의 RTSP URL과 기존 인증정보를 사용하여 각 enabled channel을
검사한다.

```bash
ffprobe -v error -rtsp_transport tcp -select_streams v:0 \
  -show_entries stream=codec_name,width,height,avg_frame_rate \
  -of default=noprint_wrappers=1 'RTSP_URL_FROM_DEVICE_LOG'
```

ch0/ch1 모두 JSON의 `VHL_CAM.enc`에 맞는 codec으로 decode되고 요청한 논리 채널
해상도가 표시돼야 한다. Case H는 H.264이며, 공급자 보드의 일반 A/B/E와 최종 운영
설정은 `enc="h265"`라서 ffprobe에 `codec_name=hevc`가 표시됐다. cold start 직후 첫
probe가 비어 있으면 즉시 실패로 판정하지 말고 8554 listener와 gstApp PID를 확인한 뒤
최대 60초 안에서 다시 시도한다.

### 9.4 RGB565 녹색 화면 검사

MAX9296 subdevice media-bus는 UYVY지만 `/dev/video4` ISI capture node는
`RGBP`(RGB565)다. RGB565 원시 프레임을 UYVY로 해석하면 대부분 녹색으로 보일 수 있다.

먼저 실제 포맷과 stride를 기록한다.

```bash
v4l2-ctl -d /dev/video4 --get-fmt-video | \
  tee /root/camtest/handoff-camera1-20260831/evidence/video4-format.txt
```

Case B의 dual-wide 1280x360 RGB565 frame을 독점 capture하는 예다. gstApp이 노드를
점유하므로 이 검사는 서비스 중단이 허용된 qualification 구간에서만 수행한다.

```bash
systemctl stop cam-operate.service
pkill -9 gstApp 2>/dev/null || true
v4l2-ctl -d /dev/video4 \
  --set-fmt-video=width=1280,height=360,pixelformat=RGBP \
  --stream-mmap=4 --stream-count=1 \
  --stream-to=/root/camtest/handoff-camera1-20260831/evidence/dual-1280x360.rgb565
/opt/pim/bin/rgb565_frame_check.py \
  --width 1280 --height 360 --bytesperline 2560 \
  /root/camtest/handoff-camera1-20260831/evidence/dual-1280x360.rgb565
/opt/pim/bin/cam_hard_reset.sh -s -S
```

필수 결과는 `constant=0`, `mostly_green=0`, `pass=1`이다. `--get-fmt-video`의
bytesperline이 2560과 다르면 checker에는 장비가 보고한 실제 값을 사용한다.

### 9.5 커널 오류

```bash
dmesg --color=never | grep -Ei \
  'max9296|ap1302|mipi|isi|overflow|underflow|i2c|exposure|EBUSY' | tail -n 300
```

30 FPS 정상 case에서 신규 overflow, I2C write 실패, module error가 없어야 한다.

## 10. 권장 최종 설정

시험 완료 후 기본 상태는 다음과 같다.

- ch0/ch1 enabled, ch2/ch3 disabled
- `cam_width=640`, `cam_height=360`, `fps=30`
- `crop_enable=false`, `dz=100`
- 각 채널 `dz_x=32768`, `dz_y=32768`
- `app="gstApp"`

시험 직전의 unrelated 운영값을 잃지 않도록 Case B 시험 파일을 그대로 재사용하지
않는다. 승인된 production JSON이 따로 없으면 설치 전 백업을 다시 live 파일로
복원하고 새 schema를 backfill한 뒤, 합의된 카메라 필드만 원자적으로 바꾼다.

```bash
set -e
BACKUP=/root/pim-handoff-backup-20260831
EDGE=/root/shared_v/edgeconf_pim.json
TMP=/root/shared_v/edgeconf_pim.json.handoff.tmp
install -m 0640 "$BACKUP/edgeconf_pim.json" "$EDGE"
/opt/pim/bin/update_edgeconf.sh
jq '
  .VHL_CAM.app = "gstApp"
  | .VHL_CAM.cam_width = 640
  | .VHL_CAM.cam_height = 360
  | .VHL_CAM.fps = 30
  | .VHL_CAM.i2c2.crop_enable = false
  | .VHL_CAM.i2c2.dz = 100
  | .VHL_CAM.i2c2.ch0.enable = true
  | .VHL_CAM.i2c2.ch1.enable = true
  | .VHL_CAM.i2c1.ch2.enable = false
  | .VHL_CAM.i2c1.ch3.enable = false
  | .VHL_CAM.i2c2.ch0.dz_x = 32768
  | .VHL_CAM.i2c2.ch0.dz_y = 32768
  | .VHL_CAM.i2c2.ch1.dz_x = 32768
  | .VHL_CAM.i2c2.ch1.dz_y = 32768
' "$EDGE" > "$TMP"
jq empty "$TMP"
install -m 0640 "$TMP" "$EDGE"
rm -f "$TMP"
/opt/pim/bin/cam_hard_reset.sh -s -S
media-ctl -p | grep -E 'max9296 2-0048|1280x360@1/30'
/opt/pim/bin/cam_fps_stack.sh -c ch01 -d 20 -i 2 -D -L FINAL_640X360_30 -R 30
pgrep -a gstApp
```

## 11. 롤백

기존 DEB와 백업 설정이 모두 있을 때만 아래 절차를 수행한다.

```bash
set -e
BACKUP=/root/pim-handoff-backup-20260831
test -f "$BACKUP/previous-pim-mp.deb"
test -f "$BACKUP/edgeconf_pim.json"
test -f "$BACKUP/ord_vcm_conf.json"
test -f "$BACKUP/defaultconf.json"

systemctl stop cam-operate.service
dpkg -i "$BACKUP/previous-pim-mp.deb"
cp -a "$BACKUP/edgeconf_pim.json" /root/shared_v/edgeconf_pim.json
cp -a "$BACKUP/ord_vcm_conf.json" /root/shared_v/ord_vcm_conf.json
cp -a "$BACKUP/defaultconf.json" /etc/defaultconf.json
jq empty /root/shared_v/edgeconf_pim.json
jq empty /root/shared_v/ord_vcm_conf.json
depmod -a
ldconfig
/opt/pim/bin/cam_hard_reset.sh -s -S

dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' pim-mp
sha256sum /root/shared_v/edgeconf_pim.json \
  /root/shared_v/ord_vcm_conf.json /etc/defaultconf.json
pgrep -a gstApp
```

모듈 refcount가 음수이거나 `cam_hard_reset.sh`가 종료코드 2를 반환하면 반복 실행하지
말고 재부팅한다.

## 12. 결과 회신 양식

| Case | 채널 | 요청 출력/FPS | 실제 media 출력 | sensor/ISP/CSI/ISI FPS | crop/배율/중심 | RTSP decode | RGB565 | CPU/RSS/DDR/온도 | 신규 dmesg 오류 | 결과 | 증적 경로 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A | ch0 | 640x360@30 |  |  | off/100/center |  |  |  |  |  |  |
| B | ch0+ch1 | 각 640x360@30 |  |  | off/100/center |  |  |  |  |  |  |
| E | ch0+ch1 | 각 1280x720@30 |  |  | on/150/center+runtime |  |  |  |  |  |  |
| H | ch0+ch1 | Case H H.264 VPU |  |  | off/100/center |  |  |  |  |  |  |

회신 시 아래 정보도 포함한다.

- 보드 식별자, OS, 커널
- 설치 전후 `pim-mp` 버전
- DEB 및 설치 핵심 파일 SHA-256
- 적용한 edgeconf 사본과 SHA-256
- `cam_fps_stack.sh`, `cam_360p_resource.sh`, gstApp journal, dmesg 결과
- 실패한 경우 수행한 롤백 단계와 최종 복구 상태

## 13. 공급자 검증 결과

### 13.1 로컬 패키지 검증

전달 DEB는 최신 패키징 원본에서 생성한 뒤 다음 검사를 통과했다.

- binary manifest strict 검사 통과
- 640x360/crop 기본 JSON 계약 검사 통과
- FPS/resource/UYVY/RGB565 도구 계약 검사 통과
- 패키지 실행권한 검사 통과
- maintainer script `bash -n` 통과
- `max9296.ko` vermagic 일치
- source 파일 시각이 달라도 고정된 `SOURCE_DATE_EPOCH`로 2회 빌드한 DEB가
  byte-for-byte 및 SHA-256까지 일치
- DEB 재추출 후 전체 data payload의 파일 유형, 권한, symlink target, SHA-256 일치
- DEB 권한 분포: regular `644/755`, directory `755`, symlink `777`

### 13.2 공급자 타겟 보드 실측

2026-08-31에 다음 환경에서 이 문서의 DEB 자체를 설치하고 검증했다.

| 항목 | 실측값 |
|---|---|
| board registry / hostname | `pim` / `pim-camera-v016` |
| SoC / OS | i.MX8MP / Ubuntu 20.04.2 LTS |
| kernel | `5.10.35-lts-5.10.y+g2fce14defc04` |
| 설치 전 package | `pim-mp 0.6.2 arm64` |
| 설치 후 package | `pim-mp 0.6.3+jhw.camera1 arm64`, `install ok installed` |
| 최종 설치 DEB SHA-256 | `901c4caa93a0aee817e6f51bbd74f20e3c07d5046e2eeeda979d54a13a1c2bd7` |
| 설치 결과 | `dpkg` exit 0, `dpkg --audit` 출력 없음 |
| evidence root | `/root/camtest/handoff-camera1-20260831/` |

실측 결과:

| Case | 실제 capture / RTSP | sensor/ISP/CSI/ISI 평균 FPS | crop | CPU / RSS / DDR / 온도 | RGB565 | 결과 |
|---|---|---|---|---|---|---|
| A | `640x360 RGBP`; ch0 HEVC `640x360@30` | ch0 `29.9/29.9/29.8/29.9`, 손실 0.3% | off, 1.0x, center | 14.7%; 24712→24748 KiB; 미지원; CPU/SOC 54/56→53/54°C | green ratio 0, `pass=1` | PASS |
| B | `1280x360 RGBP`; ch0/ch1 HEVC 각 `640x360@30` | ch0 `30.0/29.9/29.9/29.9`, ch1 `30.0/29.9/29.8/29.8`; 손실 0.2/0.4% | off, 1.0x, center | 17.6%; 41584 KiB 유지; 미지원; 54/56→53/55°C | green ratio 0.000503, `pass=1` | PASS |
| E | `2560x720 RGBP`; ch0/ch1 HEVC 각 `1280x720@30` | ch0 `30.0/30.0/29.8/29.9`, ch1 `29.9/29.9/29.7/29.8`; 손실 0.5/0.7% | on, 1.5x, center; ch0 40000→32768 런타임 성공 | 25.5%; 71208→73216 KiB; 미지원; 56/58°C 유지 | green ratio 0, `pass=1` | PASS |
| H | `1280x360 RGBP`; ch0 H.264 Main, ch1 H.264 Baseline, 각 `640x360@30` | ch0 `30.0/29.9/29.8/29.9`, ch1 `30.0/29.9/29.7/29.8`; 손실 0.4/0.6% | off, 1.0x, center | 18.5%; 38456 KiB 유지; 미지원; 54/56→54/55°C | green ratio 0, `pass=1` | PASS |

위 A/B/E/H 전체 시험 후 패키지 아카이브 타임스탬프를 결정적으로 만드는 수정과
저장소 권한 정리가 들어갔다. 권한 커밋은 전체 301개 중 패키지 tree 59개 regular
file(data 58개와 `DEBIAN/templates` 1개)을 `100644`에서 `100755`로 바꾸며 파일
내용은 변경하지 않는다. 최종 SHA의 전달
DEB를 보드에 다시 설치한 뒤 dual 640x360@30 스모크를 반복한 결과는 ch0
`29.9/29.9/29.7/29.8`, ch1 `30.0/30.0/29.5/29.6` sensor/ISP/CSI/ISI FPS였고,
두 RTSP 모두 HEVC `640x360@30`이었다. 최종 증적은
`/root/camtest/handoff-camera1-20260831/final-permissions-deb/`에 저장했다.

Case H에서 `dualEn=0`, ch0 유효값 `gop=30,30`, `profile=10,10`,
`quant=-1,-1`, `qp_min=10,10`, `qp_max=40,40`과 VPU encoder 4.6.1 / wrapper
3.0.0을 확인했다. `gop=0`은 30 FPS로 해석됐고 RTSP slot은 record slot에 맞춰졌다.

Case A의 AR0234 window는 1920x1080이어서 640x360 crop-off가 sensor native
640x360 readout이 아니라는 점을 확인했다. Case E의 window는 중앙 1280x720으로
바뀌어, digital zoom이 출력 크기는 유지하면서 sensor ROI에도 영향을 줄 수 있음을
확인했다.

모든 case에서 신규 overflow/CRC/ECC/lost-frame/timeout과 녹색 화면은 없었다.
카메라 자격시험과 무관한 LED flash는 MCP4018 미장착 보드 조건에 맞춰 끈 뒤 clean
reset에서 신규 I2C 오류가 없음을 재확인했다.

### 13.3 설치 시 관찰사항과 최종 복원 상태

- 최종 DEB 내부의 권한 변경 파일은 755로 확인했다. 단 `/etc/defaultconf.json`은
  `postinst`가 644인 `edgeconf_pim_base.json`에서 다시 생성하므로 설치 완료 후에는
  644가 된다. 함께 확인한 service, CIS script, crontab, firmware archive와 modules
  파일은 755였다.
- 각 설치 중 `/opt/cis/bin/init.py power_on`에서 Python `serial` module 부재
  traceback이 1회씩 발생했다. `dpkg`는 exit 0으로 구성 완료됐고 camera/VPU 시험에는 영향이
  없었지만, 수신 환경에서 이 CIS 초기화 경로가 필요하면 `python3-serial` 제공 여부를
  별도 확인한다.
- 공급자 보드에서는 `restart_app.sh`가 선택적 `vcm`/`ord` command를 찾지 못하는
  journal 로그가 반복됐다. gstApp, RTSP, 녹화 파일 완료와 camera FPS에는 영향이
  없었으며, 수신 환경의 해당 실행 파일 제공 여부를 별도 확인한다.
- DDR PMU counter는 이 보드에서 지원되지 않아 DDR 값은 `na`였다. CPU/RSS/온도는
  정상 수집됐다.
- rollback은 실제로 실행하지 않았다. 설치 전 `pim-mp 0.6.2` DEB
  (SHA-256 `c0dfc79d46dbe4650ede53dbf5eb700ddac1ee9fe54298f99c0cfdf0934907a0`)와
  edgeconf/ord-vcm/defaultconf 백업의 존재·문법·체크섬을 확인해 복구 입력을 확보했다.
- 시험 후 설치 직후의 운영 JSON을 byte-for-byte 복원했다. 최종 SHA-256은
  `87f9bbb1910f1dd385aef96496d03e5a94feace9ac3acb7bc2197e2d6400ad03`이며,
  ch0/ch1 enabled, ch2/ch3 disabled, 640x360@30, crop off, `dz=100`, center
  32768, `enc=h265`, gstApp active 상태다.

상대 팀은 공급자 결과를 대체하지 말고 12장의 양식으로 독립 결과를 회신한다.
