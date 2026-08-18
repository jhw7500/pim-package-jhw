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
- 범위 밖 ISI activity는 `capture` 판정을 바꾸지 않는다. 비신뢰 사실은
  `isi_frame_semantics_reliable` evidence 로만 나간다. 아래 "ISI 비율 게이트는 카메라가
  아니라 부하를 잰다" 절 참조 — 예전에는 여기서 `UNKNOWN/ISI_ACTIVITY_UNRELIABLE` 을 냈다.

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

## 보드 실측: ISI 비율 게이트는 카메라가 아니라 부하를 잰다 (2026-08-18)

`ISI_ACTIVITY_UNRELIABLE` 은 예외 상황이 아니라 이 보드의 상시 상태에 가깝다.
4채널 정상 스트리밍 중 480초 관측에서 **474샘플 중 203샘플**이 이 사유만으로
aggregate 를 `DEGRADED` 로 떨어뜨렸다.

원인은 **게이트의 전제가 틀린 것**이다. 게이트는 ISI IRQ 가 프레임당 정확히 1회라고
가정하고 `csi/isi ≈ 2` 를 기대한다. 이 보드에서 그 가정은 **한가할 때만** 성립한다.

`/proc/interrupts` 카운터를 직접 1Hz 로 기록해 구성별로 비교했다(2026-08-18, 각 구간
180–300초, 4채널 스트리밍).

| 구성 | csi/s | isi/s | 누적 csi/isi | 1초 창 통과 | 10초 창 통과 |
|---|---|---|---|---|---|
| producer 없음 (원본 gstApp) | 30 | 15 | **1.943** | 100% | 100% |
| producer 없음 (health producer 포함 gstApp) | 30 | 16 | 1.894 | 96% | 100% |
| 위와 동일 구성, 다른 세션 | 30 | 16 | 1.776 | 81% | 94–97% |
| + `max9296_health_export.py` 하나만 | 30 | 18 | 1.629 | 54–60% | 72–73% |
| + `camera_capture_probe.py` 하나만 | 30 | 18 | 1.630–1.652 | 56–63% | 86–90% |
| + `camera_healthd.py` 하나만 | 30 | 18 | 1.627–1.636 | 55–60% | 72–76% |
| + 3종 전부 | 30 | 18 | 1.630–1.643 | 57% | 72–83% |

읽어야 할 것 세 가지다.

1. **프레임률은 전 구성에서 14.98–14.99 fps 로 완전히 불변이다.** CSI delta 는 언제나
   30/s 다. 카메라는 아무 영향도 받지 않았다.
2. 늘어나는 것은 **ISI 쪽뿐**이다. 15/s(프레임당 1.0회) → 18/s(프레임당 1.2회). 커널
   로그에는 overflow/underrun/drop 기록이 전혀 없다.
3. **어느 producer인지는 무관하다.** 셋 중 아무거나 하나만 돌려도 효과가 같고 포화된다.
   즉 producer 고유의 결함이 아니라 **1Hz 유저스페이스 프로세스 하나면 충분**하다.

결론: 이 게이트는 카메라 건강이 아니라 **시스템 부하**를 재고 있다. 부하가 조금만 붙어도
중심이 1.94 → 1.63 으로 내려가 게이트 하한 1.6 에 걸터앉는다.

**창을 늘려도 해결되지 않는다.** 분산이 아니라 중심이 이동하기 때문이다. 10초 창에서도
72–90% 다. 디바운스도 부분적이다 — 이탈 구간이 최대 12초까지 이어진다.

**늘어난 ISI 인터럽트는 프레임 손실이 아니다.** gstApp 이 publish 하는
`enc_queue_input`(인코더 큐에 실제로 도달한 버퍼 누적)으로 확인했다. 같은 세션 안에서
producer 유무만 바꿔 각 240초를 쟀다.

| 구간 | CSI | ISI | 프레임당 ISI | 채널별 enc 도달 |
|---|---|---|---|---|
| producer 없음 | 14.99 fps | 15.37/s | 1.025 | 14.94/s |
| producer 3종 | 14.98 fps | 16.55/s | 1.104 | 14.94/s |

ISI 인터럽트가 프레임당 7.7% 늘어나는 동안 **인코더에 도달한 프레임은 4채널 모두
동일**했다(변화 +0.03%). ISI 는 프레임당 인터럽트를 더 올릴 뿐 프레임을 흘리지 않는다.

주의 — 위 480초 soak 당시 probe 가 기록한 `csi_irq_delta` 는 9–13(4.5–6.5 fps)이었다.
그건 이 보드의 정상 상태가 아니라 **관측 하니스가 만든 인공물**이다. 그 soak 의 샘플러는
초당 python3 프로세스를 새로 띄우거나 10Hz 로 JSON 을 파싱했고, 그 부하가 프레임률을
1/3 로 눌렀다. 가벼운 샘플러로 다시 재면 같은 producer 구성에서도 CSI 는 30/s 다.
게이트 통과율(57%)만은 양쪽에서 일치하므로 결론은 유지된다. 보드 계측에서 샘플러 자신의
비용을 빼놓으면 안 된다는 사례로 남긴다.

여기에 계약상의 모순이 겹친다. 위 "판정 제한" 절은 *"범위 밖 ISI activity 는
`UNKNOWN/ISI_ACTIVITY_UNRELIABLE` 이며 CSI2 OK 를 지우지 않는다"* 고 선언하는데,
aggregator 는 관측 하나라도 `UNKNOWN` 이면 전체를 `DEGRADED` 로 내린다. 즉 CSI2 OK 는
살아남지만 **시스템 전체 판정은 이미 무너진 뒤**다. 이 producer 는 "모르겠다"의 값이
비싸다는 점을 반영하지 못하고 있다.

선택지(결정 전까지 소비자 전환 보류). 위 실측이 앞의 둘을 배제한다:

1. ~~샘플 창을 늘린다~~ — **무효.** 중심이 이동한 것이라 10초 창에서도 72–90% 다.
   게다가 창과 publish 주기가 같은 변수(`:457`)라 창을 5초로 늘리면 aggregator TTL
   3000ms 를 넘겨 `PRODUCER_STALE` 이 된다. 창만 늘리려면 롤링 창으로 분리해야 한다.
2. ~~연속 K회 이탈에만 `UNKNOWN`(디바운스)~~ — **부분적.** 이탈 구간이 최대 12초까지
   이어져 K 를 그만큼 키우면 진짜 정지 감지도 함께 둔해진다.
3. **`capture` 를 `UNKNOWN` 으로 내리지 않고 evidence 에 비신뢰 사실만 기록한다.**
   → **채택했다.** 유일하게 원인에 맞는 선택지다 — 이 값은 카메라 건강이 아니라 부하를
   재고 있고, `isi_delta > 0` 자체가 capture 경로가 프레임을 나른다는 증거이며(위 표),
   진짜 정지(`isi_delta == 0`)는 바로 위 분기에서 이미 `CAPTURE_PATH_STALL` 로 잡힌다.
   확신도는 `isi_frame_semantics_reliable` evidence 로 그대로 나가므로 정보는 잃지 않는다.

   `ISI_ACTIVITY_UNRELIABLE` 코드 자체는 레지스트리에 남긴다. 세 저장소를 동시에 교체할
   수 없으므로([`version-compatibility-v1.md`](version-compatibility-v1.md)), 아직 그
   코드를 내는 probe 버전의 snapshot 이 레지스트리 미등록으로 통째로 거부되면 안 된다.

## enable 금지 조건

`camera-capture-probe.service`에는 `[Install]`이 없다. `/tmp/config`의 enabled channel과
single/dual topology를 domain expectation으로 변환하는 consumer 계약이 배포되기 전에는
target에서 daemon으로 enable하지 않는다. 오프라인 또는 수동 `--once`만 허용한다.
