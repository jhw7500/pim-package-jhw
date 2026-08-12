# MAX9296 read-only health producer rollout

## 배포 범위

`max9296_health_export.py`는 max9296 driver 2.4의
`/sys/bus/i2c/devices/*-0048/health_raw`를 읽어
`/run/pim-camera/max9296.json`을 원자적으로 publish한다.

이 package 단계에는 다음만 포함한다.

- `/opt/pim/bin/max9296_health_export.py`
- static unit `camera-max9296-health.service`
- health-v1 schema/registry/aggregator 호환 테스트

unit에는 `[Install]`이 없고 `postinst`도 enable/start하지 않는다. 기존
`cam-operate`, `restart_app.sh`, `init_cam.sh`, `kill_test.sh`, legacy flag 및 recovery
ladder는 변경하지 않는다.

## 의존 버전과 현재 한계

- max9296 driver: `SW_VERSION=2.4`, ABI `max9296-health-raw-v1`
- pim-package: camera health schema 1 및 현재 error-code registry
- gstApp producer는 이 단계의 필수 조건이 아니다. 없으면 aggregator에서 해당
  producer만 stale/unknown이다.

shallow driver ABI는 AR0234 deep DMA를 실행하지 않는다. 따라서 정상 링크에서도
Sensor observation은 `UNKNOWN/PRODUCER_STALE`이고 aggregate는 `DEGRADED`일 수 있다.
이를 장애나 reset 조건으로 사용하면 안 된다.

## 오프보드 완료 기준

다음 항목까지는 카메라 보드 없이 완료할 수 있다.

1. package 경로의 exporter가 synthetic dual raw snapshot을 변환한다.
2. output이 `health-v1.schema.json`과 error-code registry를 통과한다.
3. shadow aggregator가 snapshot과 세 channel mask를 수용한다.
4. busy/invalid sample이 마지막 정상 output을 덮어쓰지 않는다.
5. unit은 systemd syntax 검사를 통과하지만 enable link를 만들지 않는다.
6. 전체 `test/camera_health/run_all.sh`가 통과한다.

여기까지 통과하면 package commit은 가능하지만 production enable은 아직 금지한다.

## 보드 Gate A: 수동 one-shot

driver 2.4 module이 올라오고 기존 카메라가 정상 동작하는 상태에서 수행한다.

```bash
cat /sys/bus/i2c/devices/1-0048/health_raw | jq .
cat /sys/bus/i2c/devices/2-0048/health_raw | jq .

/opt/pim/bin/max9296_health_export.py --once
jq . /run/pim-camera/max9296.json

/opt/pim/bin/camera_healthd.py --once
jq . /run/pim-camera/aggregate-shadow.json
```

통과 조건:

- 두 sysfs read와 exporter가 3초 안에 끝난다.
- producer `boot_id`, sequence, 세 mask가 유효하다.
- configured channel과 RX3 A/B physical mapping이 실제 구성과 일치한다.
- `legacy_write=false`, `recovery_requested=false`다.
- 실행 전후 camera PID, stream, GPIO power/reset 상태가 변하지 않는다.
- 새 I2C retry/journal flood가 없다.

Gate A 실패 시 unit을 시작하지 않고 raw JSON, `dmesg`, adapter별 read latency만
수집한다.

## 보드 Gate B: 수동 shadow soak

Gate A 통과 후에만 enable하지 않고 현재 boot에서 수동 시작한다.

```bash
systemctl start camera-max9296-health.service
systemctl start camera-health-shadow.service
systemctl status camera-max9296-health.service camera-health-shadow.service
```

최소 시험:

1. idle 30분, streaming 30분 동안 1초 cadence와 producer age를 확인한다.
2. STREAMON/OFF 및 V4L2 control 반복 중 busy가 hardware FAIL로 바뀌지 않는지
   확인한다.
3. dual pair의 각 cable을 10회씩 제거/재연결하고 origin link와 peer physical
   evidence, shared `stream_domain_active_mask=0`을 확인한다.
4. producer 실행 중 max9296 module unbind/rebind 후 다시 publish되는지 확인한다.
5. read latency p50/p95/p99와 GStreamer FPS 변화를 비교한다.
6. 시험 전체에서 reset, reinitialize, reboot, legacy flag write가 0건인지 확인한다.

종료:

```bash
systemctl stop camera-health-shadow.service camera-max9296-health.service
systemctl is-enabled camera-max9296-health.service  # static 예상
```

## 이번 단계의 정지점

Gate B 결과를 검토할 때까지 다음 작업은 시작하지 않는다.

- unit 자동 enable 또는 `cam-operate` dependency 편입
- producer 상태를 기존 error counter/recovery 입력으로 사용
- cable reconnect 감지에 따른 full initialization
- module reset/hard reset 자동 escalation
- AR0234 deep DMA를 1초 shallow poll에 포함

Gate B가 안정적이면 다음 change에서 장시간 fault matrix와 counter-only shadow
판정을 추가한다. destructive recovery 전환은 각 link fault 100회, module
unbind/rebind, dual-wide pair 영향 및 설정 reload lifecycle까지 별도로 통과해야 한다.
