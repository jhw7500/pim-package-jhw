# PIM camera4 기동 정책 패키지 전달 및 시험 방법

기준일: 2026-08-31
전달물: 아래 DEB 1개와 이 문서 1개
대상: i.MX8MP, Ubuntu 20.04, 커널 `5.10.35-lts-5.10.y+g2fce14defc04`

## 1. 전달 파일

| 항목 | 값 |
|---|---|
| 파일 | `pim-mp_0.6.3+jhw.camera4_arm64.deb` |
| 크기 | 30,763,678 bytes |
| SHA-256 | `1058ece3675c03cd7c9c3a47de1c4adca0ded6af36e98f9f4137a5721c7a66fc` |
| Package | `pim-mp` |
| Version | `0.6.3+jhw.camera4` |
| Architecture | `arm64` |

빌드 호스트 보관 위치는
`/home/jhw/ai/opencode/projects/max9296/tmp/pim-mp_0.6.3+jhw.camera4_arm64.deb`다.
전달 시에는 DEB와 이 문서만 복사하며 개인 GitHub 저장소는 공유하지 않는다.

```bash
printf '%s  %s\n' \
  '1058ece3675c03cd7c9c3a47de1c4adca0ded6af36e98f9f4137a5721c7a66fc' \
  'pim-mp_0.6.3+jhw.camera4_arm64.deb' | sha256sum -c -
dpkg-deb -f pim-mp_0.6.3+jhw.camera4_arm64.deb Package Version Architecture
```

## 2. camera3 대비 변경점

- 모든 자동 기동 경로의 gstApp `-d`를 싱글/듀얼 CSI 공통 5초로 통일했다.
- `camera_startup_grace_sec` 기본 25초를 추가했다. 이 값은 앱 시작 시각부터 계산하는
  cold-start 오류 무시 총 시간이며 `-d`와 더하지 않는다.
- 기존 `startup_grace_extra_sec` 10초는 FINAL STALL 워밍업 계산에만 유지한다.
- 싱글/듀얼 start-marker timeout 25/35초와 init cooldown 40초는 유지한다.
- JSON 문자열, 불리언, 음수, 소수처럼 잘못된 grace 값은 BG_Check, guardian,
  updater 모두 25초로 정규화한다.
- GPIO power, driver prepare, gstApp 지연 및 health grace의 근거와 로그 해석은
  [`../camera-startup-timing.md`](../camera-startup-timing.md)에 정리했다.

gstApp과 MAX9296 바이너리는 camera3 타겟과 같은 검증본이다. 이번 차이는 기동
스크립트, 감시 정책, 설정 마이그레이션 및 문서다.

## 3. 설치 전 중단 조건과 백업

다음 중 하나면 설치하지 않는다.

- `uname -m`이 `aarch64`가 아님
- `uname -r`이 위 대상 커널과 다름
- 기존 설치 DEB 또는 설정 백업을 확보하지 못함
- 카메라/녹화를 정지할 수 없는 운영 장비

```bash
uname -m
uname -r
dpkg-query -W pim-mp

BACKUP=/root/camtest/pre-camera4-$(date +%Y%m%d_%H%M%S)
install -d -m 0700 "$BACKUP"
install -m 0600 /path/to/current-pim-mp.deb "$BACKUP/previous-pim-mp.deb"
cp -a /root/shared_v/edgeconf_*.json /root/shared_v/ord_vcm_conf.json "$BACKUP/"
```

## 4. 설치

```bash
systemctl stop cam-operate.service
DEBIAN_FRONTEND=noninteractive \
  dpkg -i ./pim-mp_0.6.3+jhw.camera4_arm64.deb
dpkg-query -W pim-mp
jq '.ETC | {camera_startup_grace_sec,startup_grace_extra_sec,init_cooldown_sec}' \
  /root/shared_v/ord_vcm_conf.json
```

필수 결과는 Version `0.6.3+jhw.camera4`, camera startup grace `25`, 기존 extra
`10`, cooldown `40`이다. `update_ordvcmconf.sh`가 기존 설정에 새 키만 보강하며
edgeconf의 해상도/FPS/crop 값은 바꾸지 않는다.

공급자 보드에서는 postinst의 기존 `/opt/cis/bin/init.py`가 `pyserial` 미설치로
`ModuleNotFoundError: serial`을 한 번 출력했지만 dpkg 설정은 완료됐다. 같은 메시지가
나오면 traceback만으로 성공 처리하지 말고 반드시 `dpkg-query -W pim-mp`, 설정 JSON,
서비스 상태를 확인한다. dpkg가 non-zero이면 즉시 rollback한다.

## 5. 시험

> **버전 불일치 경고 (2026-10-03 추가).** 이 절차의 `cam_hard_reset.sh -s -S` 는 **이 문서가
> 핀한 페이로드 기준**이다. 그 패키지의 스크립트는 `-s`/`-S` 를 `--stop-service`/
> `--start-service` 로 해석해 `systemctl stop` → `rmmod` → CSI2/ISI unbind/bind → `modprobe`
> → `systemctl start` 을 직접 수행했고, 그래서 `하드 리셋 완료 (CSI2 + ISI 재바인드 포함)` 이
> 나왔다. 그 동작이 설치 직후 **새 모듈을 실제로 적재**하게 만드는 부분이므로 이 절차에서
> 빼면 안 된다.
>
> **이미 최신 패키지가 깔린 보드에서는 그렇지 않다.** 지금 `cam_hard_reset.sh` 는 전달
> 래퍼이고 `-s`/`-S` 는 **받되 무시**된다 — 서비스를 올려 주지 않고 위 완료 문구도 출력하지
> 않는다. 그 보드에서는 다음을 쓴다.
>
> - 서비스 기동만으로 복구가 된다. `cam-operate` 기동은 같은 부팅 안의 재시작에 대해
>   startup 액션을 스스로 예약한다(`cam_operate_control.sh` 의 `cam_startup_request_reserve`).
>   그래서 보통은 별도 하드 리셋 요청이 필요하지 않다.
> - 하드 리셋을 **따로** 요청해야 하면 owner 가 준비될 때까지 기다린다. `systemctl is-active`
>   로는 부족하다 — 유닛의 `ExecStartPost` 는 런타임 JSON 검증만 기다리고, 그 시점 owner 는
>   아직 `STARTING`/`RECOVERING` 일 수 있다. 요청 수락은 `ACTIVE`/`DEGRADED` 에서만 된다:
>   `/opt/pim/bin/cam-recoveryctl status | jq -r '.owner.lifecycle'` 가 `ACTIVE` 이고
>   `.pending`·`.active` 가 비었는지 본다.
> - 그 뒤 `/opt/pim/bin/cam-recoveryctl request camera_hard_reset --source operator --reason '<사유>' --wait 300`
>   (`--source`·`--reason` 은 **필수**이며 빠지면 64). 판정은 stdout 한 줄
>   `CAM_RECOVERY_RESULT ... status=SUCCEEDED rc=0` 이다.
> - **서비스가 내려가 있으면 이 요청은 69 로 실패한다**(다른 복구가 진행 중이면 75). 즉 그
>   상태에서 래퍼가 0 을 돌려주는 일은 없다. 위험은 종료코드가 아니라, 래퍼가 옛 명령과 같아
>   보이는데 **서비스를 올려 주지 않는다**는 점이다.
> - `status=FAILED rc=70` 은 **일반 소프트웨어 실패**다. lock 획득 실패·요청 스키마 검증 실패·
>   owner 종결이 모두 70 을 쓰므로 owner stale 로 단정하지 않는다 — 그 판정에는 요청 이력의
>   `interrupted=true` 와 `interrupted_reason="owner_stale"` 이 필요하고, 두 필드는 위 한 줄에
>   들어 있지 않다.
>
> 어느 쪽 보드인지 먼저 확인한다. **1 차 신호는 `test -x /opt/pim/bin/cam-recoveryctl`** 이다 —
> 실제로 중요한 사실(그 CLI 를 호출할 수 있는가)을 직접 재기 때문이다. `dpkg-query -W
> -f='${Version}\n' pim-mp` 는 보조로 본다: 두 파일은 같은 `dist/pim` 페이로드로 한 `dpkg -i`
> 트랜잭션에 묶여 정상 경로에서는 갈라지지 않지만, unpack 이 중단된 `half-installed` 상태나
> `/opt/pim/bin` 을 패키지 밖에서 손으로 교체한 경우에는 버전 문자열과 실제 파일이 어긋날 수
> 있다. `rc=70` 은 lock 획득 실패·요청 스키마 검증 실패·owner 종결에 모두 쓰인다.

### 5.1 일반 서비스 재시작

```bash
systemctl start cam-operate.service
pgrep -a gstApp
cat /tmp/pim_cam_start_delay
cat /tmp/cam_state/last_start_ts
journalctl --since '-2 min' --no-pager | \
  grep -E 'cam app cmd|MAX9296_PREPARE|delay 5 sec|playing :|Got stream-start|no start marker|init_cam'
```

gstApp 명령은 `gstApp -d 5 -m 4`여야 한다. 첫 스트림은
`Got stream-start message`로 판정한다. `/tmp/start_video_time_chk`는 첫 세션 완료 때
늦게 갱신될 수 있어 cold-start 첫 스트림 timestamp로 사용하지 않는다.

### 5.2 계층 FPS

```bash
/opt/pim/bin/cam_fps_stack.sh \
  -d 10 -i 2 -L camera4-service-start -R 30
```

현재 공급자 보드의 640x360@30, ch0/ch1 결과는 sensor 30.0, ISP 29.9,
CSI2 29.7~29.8, ISI 29.6~29.8 FPS였고 최대 손실은 0.9%였다.

### 5.3 CSI2/ISI 포함 하드 리셋

```bash
timeout 45 /opt/pim/bin/cam_hard_reset.sh -s -S
systemctl is-active cam-operate.service
pgrep -a gstApp
```

공급자 보드에서는 32초, 종료코드 0, video0~4 재생성, 앱 시작부터 stream-start
18초였다. 순수 모듈 reload만으로는 built-in CSI2/ISI 상태를 복구하지 못할 수 있으므로
qualification에는 `cam_hard_reset.sh`를 사용한다.

### 5.4 재부팅

```bash
PRE_BOOT=$(cat /proc/sys/kernel/random/boot_id)
systemctl reboot
# SSH 복귀 후
cat /proc/sys/kernel/random/boot_id
dpkg-query -W pim-mp
systemctl is-active cam-operate.service
pgrep -a gstApp
journalctl -b -o short-monotonic --no-pager | \
  grep -E 'start_fw_load|end_fw_load|MAX9296_PREPARE|delay 5 sec|playing :|Got stream-start|no start marker|init_cam'
```

공급자 보드의 1회 smoke 결과는 boot→stream-start 31.018초, 앱 시작→stream-start
약 18초, 복구 오탐과 서비스 재시작 0건이었다. 양산 반복성 판정에는 별도의 다회
reboot 시험이 필요하다.

### 5.5 녹색 화면 원시 프레임 검사

서비스 정지가 허용된 qualification 보드에서만 실행한다.

```bash
systemctl stop cam-operate.service
pkill -9 gstApp 2>/dev/null || true
v4l2-ctl -d /dev/video4 \
  --set-fmt-video=width=1280,height=360,pixelformat=RGBP \
  --stream-mmap=4 --stream-count=1 \
  --stream-to=/root/camtest/camera4-1280x360.rgb565
/opt/pim/bin/rgb565_frame_check.py \
  --width 1280 --height 360 --bytesperline 2560 \
  /root/camtest/camera4-1280x360.rgb565
timeout 45 /opt/pim/bin/cam_hard_reset.sh -s -S
```

필수 결과는 실제 크기 921600 bytes, `constant=0`, `mostly_green=0`, `pass=1`이다.
공급자 보드 실측은 `green_ratio=0.000000`이었다. video4는 RGB565이므로 UYVY로
해석하면 녹색으로 보일 수 있다.

## 6. 합격 및 rollback

합격 조건:

- 서비스 active, gstApp `-d 5`, 25초 grace
- journal의 stream-start가 앱 시작 후 25초 이내
- `no start marker`, 불필요한 init/kill/reboot 및 음수 module refcount 없음
- sensor/ISP/CSI2/ISI FPS가 요청값 범위에서 유지
- RGB565 checker `pass=1`

실패 시 반복 하드 리셋하지 말고 이전 패키지와 설정을 복원한다.

```bash
systemctl stop cam-operate.service
dpkg -i "$BACKUP/previous-pim-mp.deb"
cp -a "$BACKUP"/edgeconf_*.json "$BACKUP"/ord_vcm_conf.json /root/shared_v/
systemctl daemon-reload
systemctl start cam-operate.service
```

모듈 refcount가 음수이거나 `cam_hard_reset.sh`가 종료코드 2이면 반복 실행하지 않고
재부팅한다.
