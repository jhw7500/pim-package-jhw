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

shallow driver ABI는 AR0234 deep DMA를 실행하지 않는다. 따라서 raw sensor
status가 `UNKNOWN`인 enabled 채널에 대해서는 sensor observation을 **아예
내보내지 않는다.** probe가 없다는 사실은 snapshot마다
`producer_data.sensor_probe = "shallow-only"`로 한 번만 선언한다.

**`UNKNOWN`이 아닌 status는 버리지 않는다.** `load_raw()`는 sensor status로
`VALID_RAW_STATUS` 전체를 허용하므로, 센서를 실제로 probe하는 driver revision이
`FAIL`을 보고할 수 있다. 이를 조건 없이 생략하면 진짜 센서 고장이 정상 snapshot으로
둔갑한다. 그래서 해석할 수 없는 status는 `UNKNOWN/PRODUCER_MALFORMED`로 남겨
비교를 `INCONCLUSIVE`에 묶어 둔다. shallow 증거로는 센서 판정을 뒷받침할 수 없으므로
driver의 `FAIL`을 그대로 전달하지는 않는다. exporter가 더 깊은 ABI를 해석할 수 있게
되면 그때 정식 sensor 판정으로 승격한다.

이전 구현은 이 자리에 `UNKNOWN/PRODUCER_STALE`을 넣었는데, `sensor`가 legacy
비교 대상 블록이라 정상 하드웨어에서도 top-level status가 영원히 `UNKNOWN`이
되고 legacy/v1 비교가 영원히 `INCONCLUSIVE`로 고정됐다. 관측하지 않은 것을
"모른다"는 증거로 발행하면 안 된다.

링크가 끊겨 ISP 경로가 막힌 경우에는 sensor observation을
`BLOCKED/REMOTE_PATH_UNAVAILABLE`로 계속 발행한다. 이건 실제 관측 결과다.

producer는 driver sequence가 실제로 진행했을 때만 `sequence`와
`observed_monotonic_ms`를 갱신한다. driver가 읽히지만 갱신을 멈추면 evidence가
나이를 먹어 aggregator TTL이 `PRODUCER_STALE`을 정상적으로 발동시킨다.

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


### Gate A 실행 결과 (2026-08-18, pim-camera-v016)

통과. 도구는 패키지를 설치하지 않고 `/tmp` 에서만 실행했다.

| 기준 | 결과 |
|---|---|
| 두 sysfs read + exporter 3초 이내 | 13.1 ms + 9.9 ms + 324.7 ms = **약 0.35초** (aggregator 282 ms 별도) |
| `boot_id`, sequence, 세 mask 유효 | UUID 36자, seq=1, 세 mask 모두 `15` |
| configured channel / RX3 A/B 물리 매핑 일치 | 아래 표 |
| `legacy_write=false`, `recovery_requested=false` | 둘 다 `false` |
| 전후 camera PID·stream·GPIO 불변 | PID 동일, video 노드 동일, gpio131/132/133 = `0/0/1` 동일 |
| 새 I2C retry / journal flood 없음 | dmesg i2c 오류 `865 → 865`, 라인 수 `1158 → 1158` |

실측 물리 매핑:

| adapter | `configured_global_mask` | 채널 | phy |
|---|---|---|---|
| i2c1 | `0b1100` | ch2 / ch3 | B / A |
| i2c2 | `0b0011` | ch0 / ch1 | B / A |

`rx3=0x66`, `link_a_up`/`link_b_up` 양쪽 true, 합산 mask `0b1111`.

producer snapshot 의 `status` 는 `OK` 였고 **sensor observation 은 발행되지 않았다**(관측 14개 =
deserializer×2 + gmsl_link×4 + isp×4 + serializer×4). shallow ABI 가 AR0234 를 probe 하지
않는다는 사실은 `producer_data.sensor_probe = "shallow-only"` 로만 선언된다. 이전 구현처럼
sensor 에 `UNKNOWN` 을 발행했다면 top-level status 가 영원히 `UNKNOWN` 이 됐을 자리다.

aggregate 는 `DEGRADED` 였다. gstApp / pim-healthd producer 가 없어 `PRODUCER_STALE` 이기
때문이며, 이 단계에서 예상된 상태다. `root_causes` 는 비어 있었다.
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


### Gate B 실행 결과 (2026-08-18, pim-camera-v016)

systemd unit 없이 `/tmp` 바이너리로 수행했다. 패키지는 설치하지 않았다.

**항목 1·5·6 — soak 75분 / 3300 샘플**

| | 구간 A (idle 30분) | 구간 B2 (streaming 25분) |
|---|---|---|
| producer status | `OK` 1800/1800 | `OK` 1500/1500 |
| producer code | `NONE` 1800 | `NONE` 1500 |
| `age_ms` | p50 546 / p99 1020 | p50 518 / p99 1017 |
| TTL(3000) 초과 | 0건 | 0건 |
| adapter1 read | p50 9.95 ms / p99 12.65 ms | p50 12.30 ms / p99 33.17 ms |
| adapter2 read | p50 9.19 ms / p99 11.55 ms | p50 12.22 ms / p99 25.18 ms |

kernel reset 0건, 재부팅 0건.

**legacy flag 미소유는 구간 분리로 확정했다.** 구간 A 는 카메라가 꺼져 있어 legacy 소유자
(`chk_cam_operate.sh`)가 돌지 않는다. 그 30분 동안 `/tmp/bg_chk_flag.bin` 의 고유 mtime 은
**1개**였다. 구간 B2 의 1160회 갱신은 정상 소유자의 몫이다. 파일 내용은 전 구간 `0` 고정.

**항목 2** — `cam_dma_read.sh` 로 V4L2 control set+get 을 반복해 producer 의 sysfs 접근과
같은 I2C 경로에서 경합시켰다. busy 가 hardware FAIL 로 바뀐 샘플은 없었다.

**항목 4 — module unbind/rebind**

`cam_hard_reset.sh -s` (rmmod + SoC CSI2/ISI unbind/bind + modprobe) 를 producer 실행 중에
수행했다. exit 0, exporter 생존, sequence 20 → 122 연속 진행, `health_raw` 경로가 동일하게
(`1-0048`, `2-0048`) 돌아왔다. exporter 는 `discover_inputs()` 로 경로를 시작 시 한 번만
캐시하므로 i2c 번호가 바뀌면 영구히 깨지는데, 그런 일은 없었다.

**항목 3 — cable 제거/재연결 12회**

| 뽑은 채널 | 회차 | 대상+peer `FAIL` | 반대 MAX9296 | 관측 `physical_present_mask` |
|---|---|---|---|---|
| ch0 (i2c2) | 5 | ch0·ch1 | ch2·ch3 **0초** | `14` = `0b1110` |
| ch1 (i2c2) | 3 | ch1·ch0 | ch2·ch3 **0초** | `13` = `0b1101` |
| ch2 (i2c1) | 3 | ch2·ch3 | ch0·ch1 **0초** | `11` = `0b1011` |
| ch3 (i2c1) | 1 | ch3·ch2 | ch0·ch1 **0초** | `7` = `0b0111` |

케이블을 뽑으면 `init_cam.sh` 가 `rmmod`/`modprobe` 로 모듈을 리로드하므로 **4채널이 물리적으로
전부 내려간다.** 그런데도 producer 는 무관한 MAX9296 을 링크 실패로 판정하지 않고
`BLOCKED/REMOTE_PATH_UNAVAILABLE` 만 기록했다. 12회 전체에서 반대 deserializer 의 `FAIL`
오판은 **0초**다. 공유 domain 도 정확히 해제된다(예: ch2 제거 시 `phys=11`, `active=3`).

producer 정상 비율은 93~95% 였고, 나머지는 모듈이 `rmmod` 된 구간의 `PRODUCER_STALE` 이다.
소스가 없으니 정확한 판정이며 모듈 복귀 후 자동 회복했다.

**축소·주의 사항**

- 회차를 doc 원문(각 10회)에서 5·3·3·1회로 줄여 실행했다.
- 이 보드의 journald 는 `Storage=volatile`, `RuntimeMaxUse=1M` 이라 **약 16분치만 보존**한다.
  긴 창을 끝에서 집계하면 앞부분이 이미 회전으로 사라져 과소 집계된다. 실제로 첫 FPS 집계가
  이 때문에 저하처럼 보였고, 분당 히스토그램으로 재확인해 `4/분` 일정(4채널 × 1파일/분)임을
  확인했다. 저널 기반 측정은 창을 짧게 끊거나 즉시 집계해야 한다.
- **항목 5 의 "GStreamer FPS 변화"를 당시에는 잘못된 지표로 봤다.** 분당 녹화 파일 수
  (`4/분`)로 판정했는데, 1분짜리 fragment 는 프레임률과 무관하게 1분마다 닫힌다. 즉 그
  수치는 fps 에 대해 아무것도 말하지 않는다. 2026-08-18 에 `/proc/interrupts` 의 CSI
  카운터로 다시 쟀고, producer 유무와 무관하게 **14.98–14.99 fps 로 불변**임을 확인했다
  (아래 "3-producer 실측 결과" 및 [`capture-probe.md`](capture-probe.md)). 항목 5 는
  이제 제대로 된 지표로 통과했다.

### 3-producer 실측 결과 (2026-08-18, pim-camera-v016)

아래 "남은 조건" 2번을 확인한 실측이다. 질문은 하나였다 — gstApp producer 를 붙이면
aggregate 가 `DEGRADED` 를 벗어나는가.

패키지는 설치하지 않았다. producer 3종은 `/tmp` 에서 실행하고, `/usr/local/bin/gstApp`
만 health producer 를 포함한 빌드로 잠시 교체한 뒤 원본으로 복원했다(sha 앞 16자로
교체·복원 양쪽을 로그에 남겼다).

**`HEALTHY` 도달을 확인했다.** 420초 관측 중 417초가 `HEALTHY` 였다.

```
overall_status = HEALTHY   status = OK   mode = shadow
legacy_write = false   recovery_requested = false
stream_mode = dual-wide
channel_masks = configured 15 / physical 15 / stream_domain_active 15
producers   max9296      OK/NONE  age 369 ms
            gstApp       OK/NONE  age 148 ms
            pim-healthd  OK/NONE  age 817 ms
```

관측된 블록은 9개가 아니라 **8개**다. `sensor` 는 shallow ABI 가 해석할 수 없을 때
관측 자체를 내지 않는다(PR #24 → #25). 이 설계가 아니었다면 `sensor` 가 상시
`UNKNOWN` 이라 `HEALTHY` 는 원리적으로 도달 불가였다.

#### 이 실측이 잡은 gstApp producer 결함

기동 구간에 gstApp 은 `recording` 을 `STARTING` 으로 내면서 최상위 `status` 를 `"OK"`
로 적고 있었다. aggregator 는 `status="OK"` 인데 OK/N/A 아닌 관측이 섞이면 스냅샷을
통째로 `PRODUCER_MALFORMED` 로 버린다. 즉 **첫 녹화 파일이 닫히기 전까지 producer 가
아예 없는 것과 같았다.** 수정본으로 그 구간을 보드에서 직접 확인했다:

```
status = STARTING                       <- 수정 전에는 "OK"
recording  ch0..ch3  STARTING/NONE
gstreamer  ch0..ch3  OK/NONE
observed_monotonic_ms 364682001  vs  /proc/uptime 364682850   (기준 시계 일치)
```

#### 남은 잡음 2건

**(a) `capture` 블록의 `UNKNOWN/ISI_ACTIVITY_UNRELIABLE` — production enable 의 실질 장애물**

`camera_capture_probe.py` 는 raw CSI/ISI IRQ 비율이 1.6–2.4 밖이면 이 코드를 낸다.
2차 실측(480초, 474샘플)에서 **474샘플 중 203샘플이 이 사유로 `DEGRADED`** 였다.
1차에서 2회로 보였던 것은 1Hz 샘플러가 1Hz aggregate 를 앨리어싱해 과소집계한 탓이다.

`/proc/interrupts` 를 직접 재서 원인을 확정했다. 상세 표와 결론은
[`capture-probe.md`](capture-probe.md) 의 "ISI 비율 게이트는 카메라가 아니라 부하를
잰다" 절에 있다. 요약하면:

- **프레임률은 모든 구성에서 14.98–14.99 fps 로 불변**이다. 카메라는 영향받지 않았다.
- 늘어나는 것은 ISI 인터럽트뿐이다. 15/s(프레임당 1.0회) → 18/s(1.2회).
- **producer 3종 중 아무거나 하나만 돌려도 효과가 같다.** producer 고유 결함이 아니라
  1Hz 유저스페이스 프로세스 하나면 충분하다. 즉 이 게이트는 카메라 건강이 아니라
  **시스템 부하**를 재고 있다.
- 그래서 중심이 1.94 → 1.63 으로 이동해 게이트 하한 1.6 에 걸터앉는다. **창을 늘려도
  해결되지 않는다**(10초 창에서도 72–90%).

`capture-probe.md` 는 "ISI 비신뢰가 CSI2 OK 를 지우지 않는다"고 명시하는데, 관측을
`UNKNOWN` 으로 내는 순간 aggregator 규칙상 전체가 `DEGRADED` 가 되어 그 의도가 무너진다.
실측이 창 확대와 디바운스를 배제하므로, 남는 선택지는 `capture` 를 `UNKNOWN` 으로
내리지 않고 evidence 에 비신뢰 사실만 기록하는 것이다(`camera_capture_probe.py:218-219`).
결정 전까지 production enable 은 보류한다.

**(b) gstApp `PRODUCER_MALFORMED` 1회 — 원인 미확정**

1차 420초에서 1초간 발생했다. 2차 480초(474샘플)에서는 재현되지 않았고, 개발 호스트에서
1Hz publisher 와 aggregator 를 239초 경합시킨 재현 시도도 0건이었다. `camera_healthd.py`
가 루프 앞에서 `now_ms` 를 찍고 그 뒤에 파일을 읽으므로 그 사이에 publish 가 끼면
`age_ms < 0` → `future_monotonic_time` 이 되는 경로는 코드상 존재하지만, **이번에
관측된 1회가 그 경로였는지는 확인하지 못했다.** 사유 문자열을 잡는 관측을 다음에
붙여야 한다. 빈도는 약 900샘플 중 1회다.

## 이번 단계의 정지점

Gate A 와 Gate B 는 2026-08-18 에 통과했다(위 결과 참조). 다만 Gate B 는 회차를 축소해
실행했으므로, 아래 작업은 **축소분 보완과 별도 승인 전까지** 시작하지 않는다.

- unit 자동 enable 또는 `cam-operate` dependency 편입
- producer 상태를 기존 error counter/recovery 입력으로 사용
- cable reconnect 감지에 따른 full initialization
- module reset/hard reset 자동 escalation
- AR0234 deep DMA를 1초 shallow poll에 포함

Gate B가 안정적이면 다음 change에서 장시간 fault matrix와 counter-only shadow
판정을 추가한다. destructive recovery 전환은 각 link fault 100회, module
unbind/rebind, dual-wide pair 영향 및 설정 reload lifecycle까지 별도로 통과해야 한다.

production enable 을 검토하기 전에 남은 것:

1. cable 시험 회차를 doc 원문 기준(각 10회)으로 채운다. 현재 ch0 5 / ch1 3 / ch2 3 / ch3 1 회다.
2. ~~gstApp producer 를 붙인 상태에서 aggregate 가 `DEGRADED` 를 벗어나는지 확인한다.~~
   **2026-08-18 확인 완료** — 위 "3-producer 실측 결과" 참조. 세 producer 를 모두 채우면
   `HEALTHY` 에 도달한다(420초 중 417초).
3. `capture` 블록의 `ISI_ACTIVITY_UNRELIABLE` 잡음을 처리한다. 지금은 474샘플 중 203샘플이
   이 사유만으로 `DEGRADED` 라, 이 상태로 소비자를 붙이면 정상 운용이 상시 열화로 보인다.
   위 "남은 잡음 (a)" 의 세 선택지 중 하나를 정해야 한다.
4. gstApp `PRODUCER_MALFORMED` 단발(약 900샘플 중 1회)의 사유를 확정한다. 사유 문자열을
   기록하는 관측을 붙여 재현한다.
5. 위가 끝나야 unit enable 과 `cam-operate` dependency 편입을 논의할 수 있다.
