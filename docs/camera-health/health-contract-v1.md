# Camera health contract v1

> 상태: Phase 0 초안. 보드 fault injection 결과가 들어오기 전까지 자동 복구에는 사용하지 않는다.
> 예외는 §6 의 하나뿐이다.

## 1. 물리 경계

```text
camera module:  AR0234 Sensor → AP1302 ISP → MAX9295 serializer
                                               │
long cable:                         power + GMSL/control
                                               │
receiver board:                         MAX9296 deserializer
                                               │ board connector pins
i.MX8MP base board:                   CSI2 → ISI/DMA/V4L2
```

공식 블록은 `sensor`, `isp`, `serializer`, `gmsl_link`, `deserializer`,
`csi2`, `capture`, `gstreamer`, `recording`이다. SER와 DES를 하나의
SERDES 상태로 축약하지 않는다.

## 2. 파일 계약

- producer는 `/run/pim-camera/<producer>.json.tmp`에 완전한 JSON을 쓴 뒤
  `/run/pim-camera/<producer>.json`으로 `rename(2)`한다.
- `boot_id`, `sequence`, `observed_monotonic_ms`로 stale/이전 boot를 구분한다.
- 기본 TTL은 3초다. TTL 초과는 `FAIL`이 아니라 `UNKNOWN/PRODUCER_STALE`이다.
- schema는 `health-v1.schema.json`, code 의미는 `error-codes-v1.json`이
  진실원천이다.
- 알 수 없는 schema version은 정상으로 해석하지 않는다.

## 3. 상태 의미

| 상태 | 의미 |
|---|---|
| `OK` | 최근 독립 evidence로 블록 자체가 정상임을 확인 |
| `FAIL` | 블록 자체 실패를 특정할 증거가 있음 |
| `UNKNOWN` | probe 불가, stale, busy 또는 증거 부족 |
| `STARTING` | 명시된 startup/recovery grace 안에서 초기화 중 |
| `BLOCKED` | 선행 조건 장애 때문에 이 블록을 검사할 수 없음 |
| `N/A` | 설정상 비활성 |

`OK`는 `code=NONE`, `N/A`는 `code=DISABLED`를 사용한다. `BLOCKED`는
`blocked_by`와 dependency code를 기록하고 자신의 failure counter를 올리지 않는다.
link/pair/CSI처럼 ID namespace가 다른 scope 사이의 cascade를 비교하려면 scope의
optional `channels`에 실제 global channel 집합을 넣는다. aggregator는 문자열 ID를
추측해 link→CSI mapping을 만들지 않는다.

## 4. probe와 data path

data path와 probe prerequisite는 다르다.

```text
data: sensor → isp → serializer → gmsl_link → deserializer → csi2 → capture

probe:
  local DES
    ├─ DES CTRL3/MIPI
    └─ RX3 link
         └─ remote control tunnel
              ├─ MAX9295 management ID/config
              └─ AP1302 endpoint/HINF → AR0234 static readback
```

MAX9295 ID 실패가 AP1302 probe를 막아서는 안 된다. AP1302 ACK가 성공하고
MAX9295 management만 실패하면 serializer만 `FAIL`로 둔다. 모든 remote endpoint가
NAK이면 serializer를 단정하지 않고 `AMBIGUOUS_GMSL_SER` 또는
`REMOTE_CONTROL_PATH_FAIL`로 둔다.

MAX9296 local control probe가 실패해도 SoC CSI IRQ나 capture buffer evidence가
존재하면 이를 덮어쓰지 않는다. DES MIPI dataplane 실패가 확인된 때만 downstream을
BLOCKED로 전파한다.

## 5. dual-wide 규칙

세 mask를 혼용하지 않는다.

- `configured_channel_mask`: JSON에서 사용하도록 설정한 채널
- `physical_present_mask`: link별 물리 presence evidence
- `stream_domain_active_mask`: 현재 합성 stream domain에서 유효한 채널

dual-wide에서 한쪽 link가 끊기면 origin link를 보존하되 pair downstream 전체를
`BLOCKED/BLOCKED_BY_PAIR`로 둘 수 있다. peer 녹화 지속을 성공 조건으로 삼지 않는다.

## 6. recovery 사용 제한

- 이 계약의 Phase 0/그림자 구현은 기존 error flag나 recovery를 변경하지 않는다.
- 예외(pim-package-jhw#223): legacy 파일검사 사다리(`chk_cam_operate.sh` 의
  `file_check_partial_floor`)는 gstApp producer 파일 하나를 읽어 자기 단계만 앞당긴다.
  조건은 다음과 같다.
  - `/run/pim-camera/gstApp.json` 의 `schema` 가 1 이다.
  - `pid` 가 지금 떠 있는 gstApp 이다.
  - `reason_detail` 이 `MAX9296 prepare failed` 로 시작하는 `gstreamer` 관측이 있다.
  - 그 관측의 `scope.id` 가 이번 파일검사에서 빠진 채널과 겹친다.
  - 사다리가 아직 gstapp_restart 구간에 있다.

  이 조건이 모두 맞으면 module_reload 단계로 올린다. 기동 중 prepare 실패로 꺼진 CSI 는 같은 전원
  epoch 에서 gstapp_restart 로 돌아오지 않기 때문이다(gstApp#148). 새 action 을 만들지 않으며,
  사다리의 순서와 상한은 그대로다. 판정과 복구는 legacy 사다리가 계속 소유한다. boot ID·TTL 검사는
  하지 않고, 지금 떠 있는 pid 와 맞는지만 본다. `/run` 은 부팅마다 비워지고, 실행이 바뀌면 pid 도
  바뀌기 때문이다. producer 의 `reason_detail` 접두나 `scope.id` 형식을 바꾸면 이 소비자도 함께 고친다.
- storage/recording code는 camera module/hard reset을 유발할 수 없다.
- `AMBIGUOUS_*`, `PRODUCER_STALE`, `CONFIG_DIVERGED`만으로 destructive recovery를
  실행할 수 없다.
- 검출 scope와 실제 action scope를 별도 기록한다. 공용 전원/FSYNC 때문에 link
  원인이 camera-domain reset으로 확대될 수 있다.

## 7. 변경 규칙

- 필드 제거/의미 변경은 schema version 증가가 필요하다.
- optional producer extension은 `producer_data` 안에만 추가한다.
- error code 추가 시 registry와 fixture를 같은 change에 포함한다.
- 세 저장소(max9296, gstApp, pim-package)의 consumer/producer 버전 조합을 PR에
  명시한다.
