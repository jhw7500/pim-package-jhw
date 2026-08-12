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

## enable 금지 조건

`camera-capture-probe.service`에는 `[Install]`이 없다. `/tmp/config`의 enabled channel과
single/dual topology를 domain expectation으로 변환하는 consumer 계약이 배포되기 전에는
target에서 daemon으로 enable하지 않는다. 오프라인 또는 수동 `--once`만 허용한다.
