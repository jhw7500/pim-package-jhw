# Camera health shadow aggregator

`camera_healthd.py`는 producer snapshot을 읽어 상세 상태와 root-cause 후보를 만드는
read-only 준비 단계다. 현재 package에서는 unit을 enable/start하지 않는다.

## 입력

| 파일 | producer | 예상 블록 |
|---|---|---|
| `/run/pim-camera/max9296.json` | max9296 | Sensor, ISP, SER, GMSL, DES |
| `/run/pim-camera/gstApp.json` | gstApp | GStreamer, recording, 일부 capture evidence |
| `/run/pim-camera/pim-probe.json` | pim-healthd probe | CSI2, capture preflight |

파일 누락, boot ID 불일치, 3초 TTL 초과, malformed schema/error code는 producer를
`UNKNOWN`으로 만들고 해당 evidence를 root cause에 사용하지 않는다.

## 출력

기본 `/run/pim-camera/aggregate-shadow.json`에 atomic rename으로 쓴다.

- 원본 observation을 제거하지 않는다.
- `root_causes`는 cascade를 억제하되 독립 동시 fault를 배열로 유지한다.
- `legacy_write=false`, `recovery_requested=false`를 항상 명시한다.
- `/tmp/bg_chk_flag.bin`, `err_camN.log`, recovery request를 쓰지 않는다.
- missing/stale producer만 있을 때 overall은 `DEGRADED`, hardware FAIL로 만들지 않는다.

## root-cause 경계

- GMSL failure는 동일 scope의 CSI/capture/GStreamer cascade보다 우선한다.
- storage read-only/full은 camera fault와 독립 동시 root로 보존한다.
- DES local I2C/control failure는 독립 CSI2/capture evidence를 억제하지 않는다.
- DES MIPI dataplane failure만 CSI2/capture/GStreamer cascade를 설명할 수 있다.
- `AMBIGUOUS_*`, stale, config divergence는 destructive root가 아니다.
- producer가 명시한 `root_cause=true/false`를 우선 보존한다.

## 실행 예

```bash
/opt/pim/bin/camera_healthd.py --once
cat /run/pim-camera/aggregate-shadow.json
```

## 세 producer 를 모두 채운 보드 결과 (2026-08-18, pim-camera-v016)

`HEALTHY` 는 도달 가능한 상태다. 420초 중 417초가 `HEALTHY` 였고 세 producer 가 모두
`OK/NONE` 이었다. 그전까지 aggregate 가 상시 `DEGRADED` 였던 것은 열화가 아니라 gstApp /
pim-healthd producer 부재로 인한 `PRODUCER_STALE` 이었다.

주의할 점 둘:

- 실제로 관측되는 블록은 9개가 아니라 **8개**다. `sensor` 는 shallow ABI 가 해석할 수 없을
  때 관측을 내지 않는다. 이 producer 가 `UNKNOWN` 을 냈다면 `HEALTHY` 는 원리적으로 도달
  불가였다 — **`UNKNOWN` 은 한 건이라도 전체를 `DEGRADED` 로 만든다.**
- 그 비용을 아직 못 치른 producer 가 하나 남았다. `camera_capture_probe.py` 의
  `ISI_ACTIVITY_UNRELIABLE` 이 474샘플 중 203샘플에서 나온다.
  [`capture-probe.md`](capture-probe.md) 참조.

수치와 재현 절차는 [`max9296-producer.md`](max9296-producer.md) 의 "3-producer 실측 결과".

`camera-health-shadow.service`에는 의도적으로 `[Install]`이 없다. max9296와 gstApp
producer가 배포되고 보드 soak가 승인된 뒤에만 별도 change로 enable한다.

MAX9296 producer package와 수동 보드 gate는
[`max9296-producer.md`](max9296-producer.md)를 따른다. 현재
`camera-max9296-health.service`도 static이며 package 설치만으로 시작되지 않는다.
