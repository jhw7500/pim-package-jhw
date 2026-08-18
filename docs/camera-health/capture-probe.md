# i.MX8MP CSI2/ISI shadow probe

`camera_capture_probe.py`는 `/proc/interrupts` 두 snapshot의 delta와 video-node presence를
읽어 `/run/pim-camera/pim-probe.json`을 만든다. V4L2 device를 open하거나 STREAMON하지
않고 legacy flag/recovery도 쓰지 않는다.

## 고정 mapping

`camera_capture_map_v1.json`은 `cam_fps_stack.sh`에서 검증한 target mapping을 사용한다.

| domain | channels | CSI IRQ | ISI IRQ | node |
|---|---|---|---|---|
| ch01 | 0,1 | `32e50000.csi` | `32e02000.isi` | `/dev/video4` |
| ch23 | 2,3 | `32e40000.csi` | `32e00000.isi` | `/dev/video3` |

- CSI2 frame rate는 raw CSI IRQ delta를 2로 나눠 계산한다.
- ISI IRQ는 activity evidence다. raw CSI/ISI ratio가 1.6–2.4 범위일 때만 현재
  mapping에서 frame-like evidence로 신뢰한다.
- 범위 밖 ISI activity는 `UNKNOWN/ISI_ACTIVITY_UNRELIABLE`이며 CSI2 OK를 지우지 않는다.

## 판정 제한

- 기대 stream domain이 명시되지 않은 IRQ 0은 `NO_STREAM_EXPECTATION`이다.
- 기대 domain도 단일 zero window만으로 CSI2 root cause를 확정하지 않고
  `UNKNOWN/CSI2_NO_PROGRESS`로 낸다.
- CSI IRQ가 증가하지만 ISI가 0이면 `CAPTURE_PATH_STALL/UNRESOLVED`다. 향후 gstApp
  quiesce 뒤 bounded STREAMON/DQBUF probe가 성공/실패해야 capture와 GStreamer를
  확정한다.
- 기대 video node가 없으면 `CAPTURE_NODE_MISSING`이다. 이때도 CSI IRQ evidence는
  독립적으로 유지한다.
- counter 감소는 reset/rebind 가능성이 있으므로 `IRQ_COUNTER_RESET/UNKNOWN`이다.

## 보드 실측: 1초 창에서 ISI 비율 게이트가 자주 이탈한다 (2026-08-18)

`ISI_ACTIVITY_UNRELIABLE` 은 예외 상황이 아니라 이 보드의 상시 상태에 가깝다.
4채널 정상 스트리밍 중 480초 관측에서 **474샘플 중 203샘플**이 이 사유만으로
aggregate 를 `DEGRADED` 로 떨어뜨렸다.

원인은 하드웨어가 아니라 통계다. 실측 프레임률이 낮아 1초 창의 IRQ delta 가 한 자릿수이고,
그 상태에서는 양자화만으로 비율이 1.6–2.4 밖으로 나간다.

| domain | csi_irq_delta | isi_irq_delta | 비율 | 판정 |
|---|---|---|---|---|
| csi1 | 13 | 8 | 1.625 | 게이트 안(간신히) |
| csi0 | 9 | 7 | 1.286 | 게이트 밖 → `UNKNOWN` |

`csi_irqs_per_frame=2` 기준 4.5–6.5 fps 다. delta 가 9 일 때 ±1 만 흔들려도 비율은
1.14–1.43 을 오간다. 창이 1초인 한 이 잡음은 없어지지 않는다.

여기에 계약상의 모순이 겹친다. 위 "판정 제한" 절은 *"범위 밖 ISI activity 는
`UNKNOWN/ISI_ACTIVITY_UNRELIABLE` 이며 CSI2 OK 를 지우지 않는다"* 고 선언하는데,
aggregator 는 관측 하나라도 `UNKNOWN` 이면 전체를 `DEGRADED` 로 내린다. 즉 CSI2 OK 는
살아남지만 **시스템 전체 판정은 이미 무너진 뒤**다. 이 producer 는 "모르겠다"의 값이
비싸다는 점을 반영하지 못하고 있다.

선택지(결정 전까지 소비자 전환 보류):

1. 샘플 창을 늘린다(예: 5초). delta 가 5배가 되어 양자화 잡음이 줄어든다.
2. 연속 K회 이탈에만 `UNKNOWN` 을 낸다(디바운스).
3. `capture` 를 `UNKNOWN` 으로 내리지 않고 evidence 에 비신뢰 사실만 기록한다.
   이 문서가 이미 선언한 의도에 가장 가깝다.

## enable 금지 조건

`camera-capture-probe.service`에는 `[Install]`이 없다. `/tmp/config`의 enabled channel과
single/dual topology를 domain expectation으로 변환하는 consumer 계약이 배포되기 전에는
target에서 daemon으로 enable하지 않는다. 오프라인 또는 수동 `--once`만 허용한다.
