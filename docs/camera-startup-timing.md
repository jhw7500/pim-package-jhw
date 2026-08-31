# 카메라 기동 시간 정책과 타겟 검증

기준일: 2026-08-31
범위: MAX9296/AP1302 드라이버, gstApp, 카메라 상태 감시, 모듈 재로드 및 재부팅

## 결론

gstApp의 `-d`는 드라이버 전원 시퀀스 전체를 기다리는 값이 아니다. gstApp이 V4L2
준비를 동기적으로 마친 뒤 PLAYING으로 넘어가기 전의 애플리케이션 지연이다. 따라서
싱글/듀얼 CSI 모두 `-d 5`를 사용하고, cold-start 오탐 방지는 앱 시작 시각부터 총
25초인 `camera_startup_grace_sec`로 별도 관리한다.

`rst_time`(싱글 25초, 듀얼 35초)은 녹화 start marker가 끝내 생기지 않는 경우를
판정하는 timeout이므로 유지한다. `init_cooldown_sec` 40초도 연속 모듈 재초기화를
막는 별도 정책이므로 유지한다. 하드 리셋 검증은 앱 지연값을 키우는 대신 40초 이상의
외부 timeout으로 수행한다.

## 서로 다른 네 가지 시간

| 구간 | 의미 | 현재 정책 |
|---|---|---:|
| 드라이버 board power | PWDN/RESET GPIO와 안정화 대기 | 약 5.02초 |
| 드라이버 prepare | AP1302 초기화부터 CSI 출력까지 | 경로·펌웨어 상태에 따라 변동 |
| gstApp `-d` | 준비 완료 후 PLAYING 전환 지연 | 5초 |
| camera startup grace | BG_Check와 guardian의 cold-start 오류 무시 총 시간 | 25초 |

이 값들은 직렬로 단순 합산하는 같은 종류의 timeout이 아니다. 특히 드라이버 prepare는
gstApp의 V4L2 상태 전환 안에서 동기적으로 실행되며, 그 뒤에 `-d`가 적용된다.

## 드라이버 GPIO 근거

MAX9296 드라이버의 첫 board-power 전환은 카메라별이 아니라 공유 보드 전원 사용자
수명에 맞춰 한 번 수행된다. `max9296_reset()`의 순서는 다음과 같다.

1. PWDN 비활성 후 1초 대기
2. active-low RESET assert 후 2초 대기
3. RESET release 후 1초 대기
4. PWDN 활성 후 1초 대기

각 PWDN 전환에 10~11ms 안정화가 더해지므로 코드상 대기는 약 5.02초다. 이는
`max9296.c`의 `max9296_power()`와 `max9296_reset()`에서 확인하며, 앱 옵션으로
대체하거나 생략할 수 없다.

## 기존 타겟 로그에서 확인한 값

아래 값은 정책 변경 전 동일 계열 타겟에서 수집한 기준선이다. 새 패키지의 최종 합격
판정은 다음 절의 반복 시험으로 다시 수행한다.

| 관측 구간 | 표본/결과 |
|---|---:|
| power request → CSI output | 33회 median 14.508초, p95 14.548초, max 14.552초 |
| power request → `s_power` 진입 | 약 12.205초 |
| `s_power` → CSI output | max 2.330초 |
| full hard reset remove → CSI output | median 34.005초, max 34.114초 |
| 직접 모듈 재로드 remove → CSI output | 단일 표본 16.095초 |

GPIO 5초와 `s_power` 이후 2.33초만 더해 전체 기동 시간을 계산하면 안 된다. probe,
펌웨어 준비, 미디어 그래프 재생성 및 서비스 기동 구간이 별도로 존재한다. 또한 직접
모듈 재로드만으로는 SoC D-PHY/CSI2가 걸린 상태를 항상 복구하지 못한다.

기존 재부팅 로그는 커널 uptime 기준 CSI 출력이 약 26.7초에 나타난 단일 표본이라
반복성 근거로 사용하지 않는다. 아래 camera4 시험에서 새 reboot smoke 1회를 추가했지만,
양산 반복성 판정에는 별도의 다회 reboot qualification이 필요하다.

## camera4 타겟 qualification 결과

2026-08-31 `pim-camera-v016`에 `pim-mp 0.6.3+jhw.camera4`를 설치하여
ch0/ch1, 카메라당 640x360@30(dual-wide V4L2 1280x360)으로 검증했다. 설치 전
camera3 rollback DEB와 edgeconf/ord 설정을 보존했고, 설치 후 설정값은 유지됐다.

| 경로 | 결과 |
|---|---|
| cam-operate 서비스 재시작 | gstApp 프로세스 1초, 첫 녹화 marker 8초, `gstApp -d 5 -m 4` |
| CSI2/ISI 포함 hard reset | 32초, 종료코드 0, video0~4 재생성, 앱 시작→stream-start 18초 |
| reboot | boot ID 변경, boot→stream-start 31.018초, 앱 시작→stream-start 약 18초 |
| hard reset 후 FPS | ch0 sensor/ISP/CSI2/ISI 30.0/29.8/29.8/29.8, ch1 30.0/29.9/29.6/29.7 |
| reboot 후 FPS | ch0 30.0/30.0/29.8/29.9, ch1 30.0/29.9/29.6/29.7 |
| RGB565 원시 프레임 | 1280x360, 921600 bytes, `green_ratio=0`, `constant=0`, `mostly_green=0`, `pass=1` |
| 복구 오탐 | `no start marker`, `request init_cam`, `kill_test`, recovery flag 모두 0건; `NRestarts=0` |

reboot monotonic 로그의 주요 시점은 다음과 같다.

| uptime | 사건 |
|---:|---|
| 19.983615초 | AP1302 firmware load 시작 |
| 23.702106초 | firmware load 종료 |
| 24.954751초 | MAX9296 prepare 완료 (`elapsed_ms=12168`) |
| 24.972835초 | gstApp `delay 5 sec for play` |
| 29.974765초 | PLAYING 전환 |
| 31.018415초 | GStreamer stream-start |

이 결과는 `-d 5`가 드라이버 prepare 뒤에 적용되고, 앱 시작부터 stream-start까지
약 18초가 걸려 총 25초 grace 안에 들어온다는 것을 확인한다. hard reset 직후
`/tmp/start_video_time_chk`의 mtime은 첫 세션 완료 때 늦게 갱신될 수 있으므로,
첫 스트림 판정은 journal의 `Got stream-start message`를 정본으로 사용한다.

타겟 증거는 `/root/camtest/startup-timing-camera4-20260831`에 보존했고, 시험 호스트에는
`max9296/tmp/evidence-camera4-20260831`로 회수했다. hard reset을 두 차례 수행한 뒤에도
모듈 refcount는 정상이고 서비스는 active 상태로 복구됐다.

## 구현

- `/opt/pim/lib/cam_start_policy.sh`
  - `CAM_APP_PLAY_DELAY_SEC_DEFAULT=5`
  - `CAMERA_STARTUP_GRACE_SEC_DEFAULT=25`
- `start_cam.sh`, `chk_cam_operate.sh`, `init_cam.sh`, `cam_enable.sh`
  - gstApp 시작 인자는 공통 5초를 사용한다.
- `BG_Check_for_pim.sh`, `pim_guardian.py`
  - `/tmp/cam_state/last_start_ts`부터 총 `camera_startup_grace_sec`를 계산한다.
  - `/tmp/pim_cam_start_delay`는 진단 정보로 남지만 grace 계산에는 사용하지 않는다.
- `ord_vcm_conf.json`, `update_ordvcmconf.sh`
  - 기존 설치에도 `camera_startup_grace_sec: 25`를 보강한다.

`startup_grace_extra_sec: 10`은 이름이 유사하지만 FINAL STALL 워밍업
(`recording_time * 2 + file_check_delay + startup_grace_extra_sec`)용이다.

## 타겟 검증 절차

시험 전 타겟을 예약하고 같은 edgeconf, 같은 채널 구성, 같은 저장 경로를 유지한다.
각 케이스는 최소 10회, cold boot는 가능하면 20회 이상 수행한다.

### 1. 서비스 재시작

```bash
systemctl restart cam-operate.service
journalctl -u cam-operate.service -b --since '-2 min' --no-pager
journalctl -k -b --since '-2 min' --no-pager | grep -E 'max9296|AP1302|CSI|STREAM'
```

로그에서 gstApp 명령이 `-d 5 -m`인지, 앱 시작 후 25초 전에 발생한 일시적 camera
error가 복구를 유발하지 않는지, 25초 이후 정상 프레임과 녹화 marker가 유지되는지
확인한다.

### 2. 전체 카메라 하드 리셋

```bash
timeout 45 /opt/pim/bin/cam_hard_reset.sh -s -S
journalctl -k -b --since '-2 min' --no-pager | grep -E 'max9296|AP1302|CSI|STREAM'
```

`cam_hard_reset.sh`는 MAX9296/미디어 모듈뿐 아니라 built-in CSI2와 ISI를
unbind/bind한다. 종료코드 0, video node 재생성, CSI frame counter 증가 및 gstApp
재기동을 모두 확인한다. 종료코드 2 또는 음수 module refcount가 보이면 반복하지 않고
재부팅한다.

### 3. 재부팅

재부팅 전 로그 수집 시작 시각과 boot ID를 기록한다. 부팅 후 다음을 저장한다.

```bash
cat /proc/sys/kernel/random/boot_id
systemctl is-active cam-operate.service
pgrep -a gstApp
journalctl -b -o short-monotonic --no-pager | grep -E 'max9296|AP1302|CSI|gstApp|cam-operate'
```

### 합격 기준

- 모든 gstApp 자동 기동 경로가 싱글/듀얼 구성 모두 `-d 5`를 사용한다.
- 25초 grace 안의 일시적 링크/heartbeat 오류가 `init_cam`이나 reboot를 유발하지 않는다.
- grace 종료 후 실제 링크 단절은 기존 감지·복구 사다리로 진입한다.
- hard reset은 45초 timeout 안에 CSI 출력과 video node를 복구한다.
- reboot 반복에서 녹색 프레임, 정지 프레임, 음수 module refcount 및 무한 복구 루프가
  없어야 한다.
- 실패가 있으면 `-d`를 늘리기 전에 power request, `s_power`, CSI output, gstApp
  PLAYING 및 첫 marker의 다섯 timestamp를 분리해 원인을 판정한다.
