# PIM Camera/VPU 360p 120 FPS 시험 패키지 가이드

## 1. 전달 범위

전달물은 아래 DEB, 120 FPS JSON fragment와 이 문서다. GitHub 저장소는 공유하지 않는다. 대상은 기존
GitLab `pim-package` main을 사용하는 동일 사양의 i.MX8MP 시험 보드이며, 이번
단계는 소스 통합이 아니라 설치·기능 시험이다.

주요 기능은 다음과 같다.

- gstApp single/dual 카메라 및 채널별 VPU H.264 설정
- AP1302/CSI 1920x1080, 1280x720, 640x360 출력
- 출력 해상도와 독립적인 digital crop, 공통 배율, 채널별 중심
- 일반 max9296 2.10 모듈에서 640x360의 1~120 FPS 요청
- sensor/ISP/CSI/ISI 계층 FPS와 CPU/RSS/DDR/온도 측정 도구

## 2. 전달 파일

| 항목 | 값 |
|---|---|
| 파일 | `pim-mp_0.6.3+jhw.camera3_arm64.deb` |
| 크기 | 30,762,264 bytes |
| SHA-256 | `7b52104318db4e0249137df2954d2b362100d8ab1e7e96514781b8aa9b46c2fe` |
| Package / Version | `pim-mp` / `0.6.3+jhw.camera3` |
| Architecture | `arm64` |
| 대상 커널 | `5.10.35-lts-5.10.y+g2fce14defc04` |
| max9296 | 2.10, srcversion `8EBDAFE29DF1EA7734A71CB` |
| max9296.ko SHA-256 | `7a5e0a330b6992c1d10731d1ba02f415cea6e2c428feb5de76625f0b4d066241` |
| JSON fragment | `max9296_640x360_120_fragment.json` (720 bytes) |
| JSON SHA-256 | `65fcde13661c66d243056c1cb8e1b1d4db47c1681fd3dbc25d0453a929d83c55` |

설치 전 반드시 확인한다.

```bash
printf '%s  %s\n' \
  '7b52104318db4e0249137df2954d2b362100d8ab1e7e96514781b8aa9b46c2fe' \
  'pim-mp_0.6.3+jhw.camera3_arm64.deb' | sha256sum -c -
printf '%s  %s\n' \
  '65fcde13661c66d243056c1cb8e1b1d4db47c1681fd3dbc25d0453a929d83c55' \
  'max9296_640x360_120_fragment.json' | sha256sum -c -
```

## 3. FPS·노출 안전 정책

| 카메라당 출력 | single V4L2 | dual-wide V4L2 | 요청 FPS 상한 | 수동 노출 쓰기 상한 |
|---|---|---|---:|---:|
| 1920x1080 | 1920x1080 | 3840x1080 | 30 | 30 |
| 1280x720 | 1280x720 | 2560x720 | 30 | 30 |
| 640x360 | 640x360 | 1280x360 | 120 | 30 |

`120`은 드라이버가 허용하는 요청 상한이며 실제 전달 FPS 보장은 아니다. 현재
640x360 `KEEP` 경로는 AR0234 native 640x360 readout이 아니라 sensor mode를
유지하고 AP1302/CSI 출력을 640x360으로 바꾼다. 이전 공급자 시험의 실제 전달률은
약 113~115 FPS였고 camera3 재시험도 CSI 113.1~113.3 FPS였으므로 수신 보드에서도
sensor/ISP/CSI/ISI를 직접 측정해야 한다.

30 FPS 초과에서는 `ae_on=true`를 사용한다. `exp_time`, `exp_time_chN` 또는 수동
AE 전환으로 AP1302 `EXP_TIME(0x500c)` 쓰기가 필요하면 드라이버가 I2C 전에
`-EBUSY`로 거부한다. 30 FPS 이하의 AE/gain/exposure 동작은 기존과 같다. SoC
정지 이력이 있는 수동 WB `0x510a` 쓰기는 추가하지 않았다.

패키지의 기본 edgeconf는 회귀 안전성을 위해 `640x360@30`이다. 120 FPS는 별도
qualification 모듈 없이 같은 max9296 2.10 모듈과 제공된 JSON fragment로 시험한다.
fragment는 AE auto와 활성 채널 호환 `led_flash.flash_delay=0`을 함께 적용한다.
이 보드에서 활성 ch0 delay 128은 CSI를 약 46 FPS로 낮췄고 delay 0에서 약
113 FPS로 회복됐다. camera3 migration은 명시된 delay를 128로 덮어쓰지 않는다.

## 4. 해상도와 crop

`cam_width`/`cam_height`는 AP1302/CSI 출력 해상도를 선택하고, `crop_enable`과
`dz`는 선택된 출력 안의 시야를 확대·조준한다. 두 설정은 독립이다.

| 키 | 범위·기본값 | 의미 |
|---|---|---|
| `crop_enable` | false | false이면 crop 레지스터 쓰기 없음 |
| `dz` | 100~300, 기본 100 | 공통 배율: 100=1.00x, 150=1.50x, 200=2.00x |
| 채널별 `dz_x`, `dz_y` | 0~65535, 기본 32768 | 정규화 중심 |

실제 매핑은 `dz` → AP1302 `0x1010`, 중심 → `0x118c`/`0x118e`다. 요구서의
`0x1012`는 중심 X가 아니라 줌 전이 속도라 즉시 적용값 `0x8000`만 사용한다.
`0x1014`는 optical zoom factor이므로 사용하지 않는다. crop-enabled 상태로
prepare한 뒤 배율과 중심은 런타임 변경할 수 있으나 스트리밍 중
`crop_enable` 전환은 `-EBUSY`다. enable 변경은 하드 리셋으로 반영한다.

## 5. VPU 설정

아래 값은 채널별 `[record, rtsp]` 배열이다. single-encoder 모드에서는 실제 RTSP
slot이 record slot 값에 맞춰진다.

| 키 | 범위·기본값 | 의미 |
|---|---|---|
| `bps` | 0 이상, `[2048,2048]` | kbps, 0은 자동 rate control |
| `gop` | 0~300, `[0,0]` | 0은 현재 FPS로 치환 |
| `profile` | 9~12, `[9,9]` | H.264 Baseline/Main/High/High10 |
| `quant` | -1~51, `[-1,-1]` | 초기 QP, -1 자동 |
| `qp_min`, `qp_max` | 0~51, `[0,0]` | 0은 미설정 |

## 6. 설치 전 점검·백업

커널이나 아키텍처가 다르거나 이전 DEB와 설정 백업을 확보하지 못하면 설치하지
않는다. `postinst`는 모듈 외에도 서비스·라이브러리·시스템 설정을 처리하므로 첫
설치는 지정된 시험 보드에서만 한다.

```bash
set -e
test "$(uname -m)" = aarch64
test "$(uname -r)" = '5.10.35-lts-5.10.y+g2fce14defc04'
. /etc/os-release
test "$ID" = ubuntu
test "$VERSION_ID" = 20.04

BACKUP=/root/pim-handoff-backup-camera3-20260831
EDGE=/root/shared_v/edgeconf_pim.json
install -d -m 0700 "$BACKUP"
cp -a "$EDGE" "$BACKUP/edgeconf_pim.json"
cp -a /root/shared_v/ord_vcm_conf.json "$BACKUP/ord_vcm_conf.json"
cp -a /etc/defaultconf.json "$BACKUP/defaultconf.json"
install -m 0600 /path/to/current-pim-mp.deb "$BACKUP/previous-pim-mp.deb"
jq empty "$BACKUP/edgeconf_pim.json"
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' pim-mp
```

## 7. 설치

```bash
set -e
WORK=/root/camtest/handoff-camera3-20260831
cd "$WORK"
printf '%s  %s\n' \
  '7b52104318db4e0249137df2954d2b362100d8ab1e7e96514781b8aa9b46c2fe' \
  'pim-mp_0.6.3+jhw.camera3_arm64.deb' | sha256sum -c -

systemctl stop cam-operate.service
dpkg -i ./pim-mp_0.6.3+jhw.camera3_arm64.deb 2>&1 | tee install-camera3.log
depmod -a
ldconfig
/opt/pim/bin/cam_hard_reset.sh -s -S

dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' pim-mp
modinfo -F version max9296
modinfo -F srcversion max9296
sha256sum /opt/pim/driver/max9296.ko /lib/modules/$(uname -r)/kernel/drivers/media/i2c/max9296.ko
sha256sum /opt/pim/config/max9296_640x360_120_fragment.json
```

필수 기대값은 package `0.6.3+jhw.camera3`, max9296 `2.10`, srcversion
`8EBDAFE29DF1EA7734A71CB`, 두 모듈 파일의 SHA-256 `7a5e0a...6241`, fragment
SHA-256 `65fcde13...3c55`다.

## 8. 640x360@120 설정과 검증

예시는 ch0/ch1 dual-wide, crop off다. live JSON의 다른 장비별 값은 보존하고 필요한
필드만 원자적으로 바꾼다.

```bash
set -e
EDGE=/root/shared_v/edgeconf_pim.json
TMP=${EDGE}.camera3.tmp
EVIDENCE=/root/camtest/handoff-camera3-20260831/evidence
FRAGMENT=/opt/pim/config/max9296_640x360_120_fragment.json
install -d -m 0700 "$EVIDENCE"

jq --slurpfile fragment "$FRAGMENT" '
  .VHL_CAM *= $fragment[0]
  | .VHL_CAM.app = "gstApp"
  | .VHL_CAM.i2c2.ch0.enable = true
  | .VHL_CAM.i2c2.ch1.enable = true
  | .VHL_CAM.i2c1.ch2.enable = false
  | .VHL_CAM.i2c1.ch3.enable = false
' "$EDGE" > "$TMP"
jq empty "$TMP"
install -m 0640 "$TMP" "$EDGE"
rm -f "$TMP"
jq -e '
  .VHL_CAM.fps == 120
  and .VHL_CAM.i2c2.ch0.ae_on == true
  and .VHL_CAM.i2c2.ch1.ae_on == true
  and .VHL_CAM.i2c2.ch0.led_flash.flash_delay == 0
  and .VHL_CAM.i2c2.ch1.led_flash.flash_delay == 0
' "$EDGE" >/dev/null

/opt/pim/bin/cam_hard_reset.sh -s -S
pgrep -a gstApp
media-ctl -p | grep -E 'max9296 2-0048|1280x360@1/120'

/opt/pim/bin/cam_fps_stack.sh \
  -c ch01 -d 60 -i 1 -D -L HANDOFF_640X360_120 -R 120 | \
  tee "$EVIDENCE/fps-120.txt"
/opt/pim/bin/cam_360p_resource.sh \
  -d 60 -v /dev/video4 -o "$EVIDENCE/resource-120.txt"
```

`cam_fps_stack.sh`의 sensor/ISP/CSI 평균을 주 판정으로 사용한다. ISI IRQ는 조건에
따라 프레임당 인터럽트 수가 고정되지 않을 수 있으므로 `*` 표시가 있으면 전달률
판정에서 제외한다. `pass120=0`이면 요청 협상 성공과 실제 120 FPS 전달을 구분하여
결과를 기록한다. dmesg의 overflow/CRC/ECC/lost-frame/timeout도 함께 확인한다.

30 FPS 초과 수동 노출 가드도 별도 확인한다. 아래 명령은 실패해야 하며 커널 로그에
채널, 모드, FPS, 요청 exposure, 안전 상한 30이 남아야 한다.

```bash
if v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl=ae_on_ch0=0; then
  echo 'FAIL: high-FPS manual AE was accepted' >&2
  exit 1
fi
dmesg --color=never | tail -n 100 | grep -E 'exposure|30|EBUSY'
```

## 9. 30 FPS 회귀

같은 JSON에서 FPS만 30으로 복원하고 반드시 하드 리셋한다.

```bash
set -e
EDGE=/root/shared_v/edgeconf_pim.json
TMP=${EDGE}.camera3.tmp
jq '.VHL_CAM.fps = 30' "$EDGE" > "$TMP"
jq empty "$TMP"
install -m 0640 "$TMP" "$EDGE"
rm -f "$TMP"
/opt/pim/bin/cam_hard_reset.sh -s -S

/opt/pim/bin/cam_fps_stack.sh \
  -c ch01 -d 30 -i 2 -D -L HANDOFF_640X360_30 -R 30 | \
  tee /root/camtest/handoff-camera3-20260831/evidence/fps-30.txt
```

sensor/ISP/CSI가 약 30 FPS이고 새 overflow/CRC/ECC/lost-frame/timeout이 없어야
한다. 이 구간에서는 기존 AE와 수동 exposure 동작도 유지되어야 한다.

## 10. crop 런타임 시험

STREAMOFF 상태에서 `crop_enable=true`로 바꾸고 하드 리셋한 다음 배율·중심을
런타임 조절할 수 있다. `dz=200`은 2배 확대이지 640x360 해상도 설정값이 아니다.

```bash
v4l2-ctl -d /dev/v4l-subdev2 \
  --set-ctrl=dz=150,dz_x_ch0=32768,dz_y_ch0=52000,dz_x_ch1=32768,dz_y_ch1=32768
```

crop을 다시 끌 때는 JSON을 false로 바꾼 뒤 하드 리셋해야 기존 hardware crop이
제거된다. gstApp 재시작만으로는 firmware epoch가 바뀌지 않는다.

## 11. 시험 종료와 롤백

시험이 끝나면 백업 edgeconf를 복원하고 하드 리셋한다. 패키지 자체를 되돌릴 때만
백업한 이전 DEB를 설치한다.

```bash
set -e
BACKUP=/root/pim-handoff-backup-camera3-20260831
systemctl stop cam-operate.service
install -m 0640 "$BACKUP/edgeconf_pim.json" /root/shared_v/edgeconf_pim.json
/opt/pim/bin/cam_hard_reset.sh -s -S
systemctl start cam-operate.service

# 패키지 롤백이 필요할 때만 실행
# dpkg -i "$BACKUP/previous-pim-mp.deb"
# depmod -a && ldconfig
# /opt/pim/bin/cam_hard_reset.sh -s -S
```

결과 회신에는 보드 식별자, 커널, 설치 전후 package version, DEB/모듈 체크섬,
적용 edgeconf, `fps-120.txt`, `resource-120.txt`, `fps-30.txt`, 해당 구간 dmesg와
RTSP 육안 결과를 포함한다.

## 12. 공급자 사전 검증

- 호스트 정책 테스트: 기본 120 FPS와 명시적 30 FPS override 각각 29/29 PASS
- max9296 전체 호스트 게이트: PASS
- pim-package-jhw binary manifest 및 camera-health/tools 전체 회귀: PASS
- 타겟 설치: `pim-mp 0.6.3+jhw.camera3`, max9296 2.10,
  `srcversion=8EBDAFE29DF1EA7734A71CB`, 모듈 SHA-256 `7a5e0a...6241`
- 설치 migration: 기존 명시 delay `[0,5,10,15]` 보존 PASS

| 설정 | ch0 sensor/ISP/CSI/ISI | ch1 sensor/ISP/CSI/ISI | 판정 |
|---|---|---|---|
| packaged fragment 640x360@120 | `117.5/114.9/113.3/112.8*` | `118.9/114.4/113.1/112.5*` | 요청/전달 동작, strict 118.8 FPS FAIL |
| 운영 JSON 640x360@30 원복 | `29.9/29.9/29.8/29.9` | `30.0/29.9/29.7/29.8` | PASS |

120 FPS 측정 구간의 overflow/CRC/ECC/lost-frame/timeout은 0, system CPU는 30.0%,
gstApp RSS는 37,096 KiB 유지, CPU/SOC는 54/56 °C였다. `*` ISI는 raw ratio 1.99가
도구의 정확한 2.0 신뢰 경계 밖이라 주 판정에서 제외하고 CSI를 사용했다. 수동 AE
전환은 예상대로 `-EBUSY`로 거부됐다.

공급자 보드에서 검증된 정상 전달률은 약 113~115 FPS다. 따라서 이 패키지는
`fps=120` 요청을 지원하지만 정확한 120 FPS를 보장하지 않는다. 시험 종료 후 원래
edgeconf SHA-256 `87f9bbb1...ad03`, 640x360@30과 active gstApp을 복원했다.
