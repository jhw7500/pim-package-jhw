# `edgeconf_pim_base.json` 설정값 가이드

**대상 파일**: `/opt/pim/config/edgeconf_pim_base.json` (공장 기본값 템플릿)
**런타임 파일**: `/root/shared_v/edgeconf_pim.json` (부팅 시 base를 보강해 사용)
**작성일**: 2026-05-07

> 깊은 동작·코드 매핑(레지스터, V4L2 CID, AP1302 AWB 매핑 등)은 `RELEASE_NOTES_version_0.6.1.md` 참조. 이 문서는 운영자가 설정값을 고를 때 보는 **요약 가이드**입니다.

---

## 1. 전체 구조

```json
{
  "NETWORK": { "used", "WLAN0", "ETH0", "ETH1" },
  "SENSORS": { "ACC", "ADC", "ETHERCAT" },
  "VHL_CAM": {
    "<top-level: cam_*, fps, paths, ...>",
    "queue_tune", "capture", "rtsp_tune",
    "i2c2": { "exp_time", "ch0", "ch1" },
    "i2c1": { "exp_time", "ch2", "ch3" }
  }
}
```

세 그룹으로 나뉘며 카메라 관련은 모두 `VHL_CAM` 아래에 있습니다.

---

## 2. NETWORK

```
┌──────────────────────────┬───────────────────┬──────────────────────────────────────────────────┐
│ 키                       │ 가능한 값         │ 설명                                             │
├──────────────────────────┼───────────────────┼──────────────────────────────────────────────────┤
│ used                     │ "WLAN0" / "ETH0"  │ 메인 인터페이스 선택                             │
│ WLAN0.security           │ "PSK" 등          │ Wi-Fi 보안 모드                                  │
│ WLAN0.ssid               │ 문자열            │ Wi-Fi SSID                                       │
│ WLAN0.passwd             │ 문자열            │ Wi-Fi 패스프레이즈 (배포 전 변경 필수)           │
│ WLAN0.method             │ "DHCP" / "static" │ IP 할당 방식                                     │
│ WLAN0.address/netmask/gw │ IPv4              │ method=static일 때만 사용                        │
│ WLAN0.bgscan             │ "simple:3:-65:30" │ wpa_supplicant 백그라운드 스캔 파라미터          │
│ WLAN0.chmask             │ true/false        │ true면 mask_freq 채널만 스캔 허용                │
│ WLAN0.mask_freq          │ MHz 배열          │ 허용 주파수 화이트리스트 (chmask=true)           │
│ ETH0.method              │ "DHCP" / "static" │ ETH0 IP 모드                                     │
│ ETH0.address/netmask/gw  │ IPv4              │ ETH0 정적 IP                                     │
│ ETH1.method              │ "static" 권장     │ ETH1 IP 모드                                     │
│ ETH1.address             │ IPv4              │ ETH1 자체 IP                                     │
│ ETH1.ping_check_enable   │ true/false        │ ping 감시 활성화                                 │
│ ETH1.client_ip_addr      │ IPv4              │ ping 대상 (보통 사내 PLC/센서)                   │
│ ETH1.ping_max_fail_count │ 정수 (예: 2)      │ 연속 실패 허용 횟수, 초과 시 ETH1 재초기화       │
└──────────────────────────┴───────────────────┴──────────────────────────────────────────────────┘
```

**예시 — Wi-Fi (DHCP)**:
```json
"WLAN0": { "security": "PSK", "ssid": "MyAP", "passwd": "secret",
           "method": "DHCP" }
```

**예시 — ETH1 ping 감시**:
```json
"ETH1": { "method": "static", "address": "199.10.100.21",
          "ping_check_enable": true, "client_ip_addr": "199.10.100.20",
          "ping_max_fail_count": 3 }
```

---

## 3. SENSORS

세 종류의 센서 데이터 수집기 설정입니다.

```
┌─────────────────────┬────────────────────┬───────────────────────────────────────────────────┐
│ 키                  │ 가능한 값          │ 설명                                              │
├─────────────────────┼────────────────────┼───────────────────────────────────────────────────┤
│ ACC.use             │ true/false         │ 가속도 센서 수집                                  │
│ ACC.samplerate      │ Hz (예: 1000)      │ 샘플링 주파수                                     │
│ ACC.scale           │ 정수               │ 스케일 인자                                       │
│ ACC.targetX/Y/Z     │ "x"/"y"/"z"        │ 물리 축 → 논리 축 매핑                            │
│ ACC.offset          │ 8개 정수 배열      │ 채널별 영점 오프셋                                │
│ ACC.use_filter      │ true/false         │ FIR 필터 적용                                     │
│ ACC.ntaps/cutoff    │ 정수               │ FIR 탭 수, cutoff(Hz)                             │
│ ACC.decimation      │ 정수               │ 다운샘플 비율                                     │
│ ACC.dataframe       │ "ACC"              │ Redis 채널/프레임 태그                            │
│ ADC.use             │ true/false         │ ADC 수집                                          │
│ ADC.samplerate      │ Hz                 │ ADC 샘플링                                        │
│ ADC.cnv_unit        │ 16개 숫자 배열     │ 채널별 환산 계수                                  │
│ ADC.use_filter      │ true/false         │ FIR 적용                                          │
│ ADC.ntaps/cutoff    │ 정수               │ FIR 탭 수, cutoff                                 │
│ ADC.decimation      │ 정수               │ 다운샘플                                          │
│ ETHERCAT.use        │ true/false         │ EtherCAT 수집                                     │
│ ETHERCAT.samplerate │ Hz                 │ 폴링 주파수                                       │
│ ETHERCAT.direction  │ "RX"/"TX"/"BOTH"   │ 데이터 방향                                       │
│ ETHERCAT.PDO_len    │ 바이트             │ PDO 패킷 길이                                     │
│ ETHERCAT.motN_sp/tq │ [fmt, s, e, gain]  │ 모터 1~4 속도/토크 (struct format, 오프셋, 게인) │
└─────────────────────┴────────────────────┴───────────────────────────────────────────────────┘
```

> SENSORS 섹션은 별도 데몬이 읽어 Redis로 송출합니다. 장비 사양이 정해지면 보통 건드리지 않습니다.

---

## 4. VHL_CAM 최상위

카메라 파이프라인 전반의 메타·동작 설정.

```
┌──────────────────────┬───────────────────┬────────────────────────────────────────────────────┐
│ 키                   │ 가능한 값         │ 설명                                               │
├──────────────────────┼───────────────────┼────────────────────────────────────────────────────┤
│ cam_width            │ 정수 (예: 1280)   │ 카메라 해상도 가로                                 │
│ cam_height           │ 정수 (예: 720)    │ 카메라 해상도 세로                                 │
│ fps                  │ 정수 (예: 15)     │ 프레임 레이트                                      │
│ recording_time       │ 분 (1~)           │ 한 녹화 세그먼트 길이                              │
│ event_auto_remove    │ true/false        │ 디스크 한계 초과 시 오래된 이벤트 자동 삭제        │
│ event_storage_size   │ % (예: 10)        │ 마운트 디스크 크기 대비 이벤트 영역 비율           │
│ vhl_name             │ 문자열            │ 장비 식별자                                        │
│ floor / line         │ 문자열            │ 설치 위치 메타                                     │
│ id                   │ 문자열            │ RTSP 서버 인증 ID (예: "user")                     │
│ app                  │ "gstApp"          │ 카메라 앱 (현재 gstApp만 사용)                     │
│ muxer                │ "mp4" / "mkv"     │ 출력 컨테이너                                      │
│ tmp_path             │ 경로              │ 임시 녹화 경로 (예: "/dev/shm")                    │
│ sd_tmp_path          │ 경로              │ SD 카드 보조 tmp                                   │
│ final_path           │ 경로              │ 최종 저장 경로 (예: "/mnt/sd_cam")                 │
│ log_level            │ 0~7               │ VHL_CAM 계열 로그 레벨                             │
│ debug_level          │ 0~                │ 디버그 레벨                                        │
└──────────────────────┴───────────────────┴────────────────────────────────────────────────────┘
```

**팁**: SD 카드가 빠진 상태로 부팅하면 자동으로 `tmp_path`가 `/dev/shm`로 임시 변경되고, 마운트 복구 시 원래 값으로 돌아갑니다.

---

## 5. VHL_CAM.queue_tune

GStreamer 파이프라인 큐 튜닝.

```
┌──────────────────────┬──────────┬─────────┐
│ 키                   │ 기본값   │ 단위    │
├──────────────────────┼──────────┼─────────┤
│ main_src_time_ms     │ 300      │ ms      │
│ enc_src_time_ms      │ 300      │ ms      │
│ rec_sink_time_ms     │ 500      │ ms      │
│ cap_src_time_ms      │ 500      │ ms      │
└──────────────────────┴──────────┴─────────┘
```

값을 키우면 일시적인 디스크 stall에 강해지지만 메모리/지연이 증가합니다. 보통 기본값을 둡니다.

---

## 6. VHL_CAM.capture

스틸 캡처 설정.

```
┌──────────────┬────────────────────┬───────────────────────────────────────────────┐
│ 키           │ 가능한 값          │ 설명                                          │
├──────────────┼────────────────────┼───────────────────────────────────────────────┤
│ enable       │ true/false         │ 캡처 기능 활성화                              │
│ delay        │ ms                 │ 캡처 트리거 지연                              │
│ timeout      │ ms (예: 1000)      │ 캡처 응답 타임아웃                            │
│ record       │ true/false         │ 캡처와 동시에 녹화                            │
│ rtsp         │ true/false         │ 캡처 결과를 RTSP로도 노출                     │
│ encoder      │ "turbo"            │ JPEG 인코더 (libjpeg-turbo)                   │
│ quality      │ 1~100 (예: 85)     │ JPEG 품질                                     │
│ response     │ true/false         │ 클라이언트에 캡처 응답 전송                   │
│ path         │ 경로               │ 캡처 임시 저장 경로                           │
│ queue_size   │ 정수 (예: 30)      │ 캡처 큐 크기                                  │
│ instant      │ 0 / 1 / 2          │ 위상지연 제거 모드 (0=off,1=ref,2=copy) ↓     │
└──────────────┴────────────────────┴───────────────────────────────────────────────┘
```

**예시 — 캡처 + 녹화 + RTSP**:
```json
"capture": { "enable": true, "delay": 0, "timeout": 1000,
             "record": true, "rtsp": true,
             "encoder": "turbo", "quality": 85 }
```

### instant — 캡처 위상 지연 제거 (0/1/2)

캡처 명령→첫 프레임 사이의 **위상 대기**(다음 카메라 프레임까지 0~1프레임주기 대기)를 없애는 옵션. valve 상류 probe가 최신 raw 프레임을 상시 보관하다가 단발 캡처 시 즉시 주입한다. gstApp이 `.VHL_CAM.capture.instant`를 직접 읽음. **기본 0(off)** — 미사용 시 기존 동작과 동일.

| 값 | 모드 | 첫 프레임 지연 | 유휴 CPU (1코어) | 공유 G2D 풀 |
|---|---|---|---|---|
| **0** | off | 다음 프레임 대기 (온타겟 baseline ~2~100ms) | 3.2% (기준) | 무영향 |
| **1** | ref-hold | **위상대기 제거 (~10ms)** | 3.4% (≈off) | 버퍼 1칸 상시 점유 |
| **2** | deep-copy | **위상대기 제거 (~10ms)** | 47.5% (+44%p) | 무영향 (안전) |

- **효과(지연):** 1·2 동일하게 위상 대기 소거. 온타겟 실측(15fps, **turbojpeg 인코더**=`--capenc turbo` 기준) first-frame이 off ~100ms → 1/2 ~10ms, `elapsed`(명령→파일 저장)도 위상대기만큼 함께 감소. (elapsed = 위상대기 + 인코딩·쓰기이며, 인코딩·쓰기 바닥값 ~50~60ms는 turbojpeg 기준 — 인코더가 다르면 달라짐.)
- **이미지 내용:** 주입 프레임은 명령 **직전**(0~1주기 과거)의 최신 프레임. 정적 장면엔 무관하나 빠른 움직임/이벤트 정밀 동기화 시 유의.
- **트레이드오프:** `1(ref)`=유휴 CPU 없음+지연 0, 단 공유 풀 1칸 점유(하드캡 풀에서 record+RTSP 고부하 시 드롭/watchdog 리스크 → soak 확인 필요). `2(copy)`=풀 무영향(안전), 단 매 프레임 uncached G2D 버퍼 복사로 유휴 CPU ~12% SoC.
- **권장:** `1(ref)` 우선(풀 안전성 온타겟 soak 확인 후), 풀이 빠듯하면 `2`. CLI `--capinstant=0|1|2`로도 override 가능. capinstant 기능이 포함된 gstApp이라야 동작.

---

## 7. VHL_CAM.rtsp_tune

RTSP 스트림 튜닝.

```
┌────────────────────────────────┬──────────┬─────────┐
│ 키                             │ 기본값   │ 단위    │
├────────────────────────────────┼──────────┼─────────┤
│ rtsp_factory_latency_ms        │ 200      │ ms      │
│ rtsp_appsink_max_buffers       │ 3        │ 개      │
│ rtsp_factory_queue_max_buffers │ 3        │ 개      │
│ rtsp_bin_queue_max_time_ms     │ 100      │ ms      │
└────────────────────────────────┴──────────┴─────────┘
```

지연이 크면 latency_ms를 줄이고, 끊김이 잦으면 buffer 수를 늘립니다.

---

## 8. VHL_CAM.i2c1 / i2c2 — 카메라 채널

채널 매핑:

```
┌──────┬────────────┐
│ 그룹 │ 채널        │
├──────┼────────────┤
│ i2c2 │ ch0, ch1   │
│ i2c1 │ ch2, ch3   │
└──────┴────────────┘
```

### 8.1 그룹 공통 키

```
┌────────────┬──────────┬─────────┬──────────────────────────────────────────┐
│ 키         │ 기본값   │ 단위    │ 설명                                     │
├────────────┼──────────┼─────────┼──────────────────────────────────────────┤
│ exp_time   │ 10000    │ μs      │ AR0234 노출 시간 (그룹 내 4채널 공통)    │
└────────────┴──────────┴─────────┴──────────────────────────────────────────┘
```

### 8.2 채널별 키 (ch0~ch3 공통 스키마)

```
┌──────────────────────┬─────────────────┬──────────────────────────────────────────────────┐
│ 키                   │ 가능한 값       │ 설명                                             │
├──────────────────────┼─────────────────┼──────────────────────────────────────────────────┤
│ enable               │ true/false      │ 채널 활성화                                      │
│ vflip                │ true/false      │ 수직 플립                                        │
│ hflip                │ true/false      │ 수평 플립                                        │
│ ae_on                │ true/false      │ 자동 노출(AE) 활성화                             │
│ ae_gain              │ 정수 (예: 256)  │ AE 게인 타겟                                     │
│ bps                  │ [main, sub] kbps│ 비트레이트 [메인, 서브] (예: [2048, 2048])       │
│                      │ 0 = 자동(VBR)   │ 0이면 해상도·fps로 자동 산출(고정 레이트 없음).  │
│                      │                 │ 상·하한 검사 없음 — 0 이상이면 통과. 10kbps      │
│                      │                 │ 미만은 VPU가 자동값으로, 60000kbps 초과는        │
│                      │                 │ wrapper가 클램프                                 │
│ gop                  │ [rec,rtsp] 0~300│ 키프레임 간격(프레임). 기본 [0, 0].              │
│                      │ 0 = fps 연동    │ 0이면 그 스트림 fps로 치환 = 1초 간격.           │
│                      │                 │ 300 초과분은 VPU wrapper가 300으로 자름          │
│ profile              │ [rec,rtsp] 9~12 │ H.264 프로파일. 9=Baseline 10=Main               │
│                      │                 │ 11=High 12=High10 (프로파일명 문자열 아님)       │
│ quant                │ [rec,rtsp] -1~51│ 초기 QP. -1=자동. 고정 QP가 아니라               │
│                      │                 │ 레이트컨트롤의 시작점                            │
│ qp_min               │ [rec,rtsp] 0~51 │ QP 하한. 0 = 미설정(HW 기본값 유지)              │
│ qp_max               │ [rec,rtsp] 0~51 │ QP 상한. 0 = 미설정(HW 기본값 유지)              │
│ awb                  │ §8.3 표 참조    │ 화이트밸런스 프리셋                              │
│ led_flash.enable     │ true/false      │ LED 플래시 사용 여부 (false면 wiper도 미적용)    │
│ led_flash.wiper      │ 0~127 (7-bit)   │ MCP4018T-503E 디지털 포텐셔미터 wiper step.      │
│                      │ 기본 63 (mid)   │ 50kΩ 128단계. 밝기/저항 방향은 보드 LED 회로에   │
│                      │                 │ 따라 다름 — 0/127이 양 끝값                       │
│ led_flash.flash_delay│ 0~255 (8-bit)   │ AR0234 R0x3270 bit7:0 DELAY 필드. 단위는 센서    │
│                      │ 기본 128        │ row-time 기반. 0이면 노출 시작과 동시에 발광.    │
│                      │ (§9 참조)       │ 누락 시 128, 명시값은 migration에서 보존         │
└──────────────────────┴─────────────────┴──────────────────────────────────────────────────┘
```

### 8.3 `awb` 가능한 값

11종 키워드를 쓸 수 있습니다. (드라이버 내부 모드는 9종, `off`/`manual`은 같은 모드)

```
┌─────────────┬──────────────────────────────────────────────────────┐
│ 값          │ 의미                                                 │
├─────────────┼──────────────────────────────────────────────────────┤
│ "auto"      │ 기본값. 자동 화이트밸런스                            │
│ "off"       │ AWB 비활성, 수동 게인 사용                           │
│ "manual"    │ off와 같은 모드 (수동 게인)                          │
│ "horizon"   │ Horizon (저색온, ~2300K)                             │
│ "a"         │ Illuminant A (백열등, ~2856K)                        │
│ "cwf"       │ Cool White Fluorescent (냉백색 형광등, ~4150K)       │
│ "d50"       │ D50 주광 (~5000K)                                    │
│ "d65"       │ D65 주광 (~6500K)                                    │
│ "d75"       │ D75 주광 (~7500K)                                    │
│ "temp"      │ 사용자 색온도                                        │
│ "measure"   │ One-shot 측정                                        │
└─────────────┴──────────────────────────────────────────────────────┘
```

> Android 카메라 류 키워드(`incandescent`, `fluorescent`, `daylight`, `cloudy` 등)는 **지원하지 않습니다.** 자세한 매핑은 `RELEASE_NOTES_version_0.6.1.md` §3.1 참조.

### 8.4 채널 설정 예시

**예시 1 — 4채널 모두 사용, AE 자동, 기본 LED 끔**
```json
"i2c2": {
  "exp_time": 10000,
  "ch0": { "enable": true, "vflip": false, "hflip": false,
           "ae_on": true, "ae_gain": 256, "bps": [2048, 2048],
           "awb": "auto",
           "led_flash": { "enable": false, "wiper": 63, "flash_delay": 0 } },
  "ch1": { ... 동일 ... }
},
"i2c1": {
  "exp_time": 10000,
  "ch2": { ... },
  "ch3": { ... }
}
```

**예시 2 — ch0만 사용 (single mode), LED 켬, 형광등 환경**
```json
"i2c2": {
  "exp_time": 8000,
  "ch0": { "enable": true, "vflip": false, "hflip": false,
           "ae_on": true, "ae_gain": 256, "bps": [4096, 2048],
           "awb": "cwf",
           "led_flash": { "enable": true, "wiper": 80, "flash_delay": 0 } },
  "ch1": { "enable": false, ... }
}
```

**예시 3 — 천장 설치(상하 반전), AE 끄고 수동 노출**
```json
"ch0": { "enable": true, "vflip": true, "hflip": true,
         "ae_on": false, "ae_gain": 128, "bps": [2048, 2048],
         "awb": "d65" }
```

**예시 4 — ch1만 화질 우선(High 프로파일 + QP 범위 제한)**
```json
"ch1": { "enable": true, "vflip": false, "hflip": false,
         "ae_on": true, "ae_gain": 256, "bps": [4096, 2048],
         "gop": [30, 30],
         "profile": [11, 11],
         "quant": [-1, -1],
         "qp_min": [22, 22],
         "qp_max": [38, 38] }
```

> **배열은 반드시 원소 2개**여야 합니다. 길이가 다르면 gstApp이 해당 키를 통째로
> 버리고 기본값을 씁니다. JSON 자체는 valid하므로 파일만 봐서는 알 수 없고,
> 부팅 로그에서 두 종류의 라인으로 확인합니다:
> 키별로 `<키이름>: array length mismatch (expected 2), keep defaults`,
> 마지막에 요약으로 `!!! N config error(s) in edgeconf ...`.
>
> single-encoder 모드(프로덕션 기본)에서는 인코더 하나가 녹화와 RTSP를 함께 먹이므로
> **rtsp 슬롯(두 번째 원소)이 rec 값으로 강제 정렬됩니다.** 위 예시의 `[4096, 2048]`처럼
> 서로 다르게 적어도 실제로는 둘 다 rec 값이 쓰이고, 로그에 `single-enc: align rtsp ...`
> 라인이 남습니다.

### 8.5 채널 enable 조합과 동작 모드

```
┌──────────────────────────────┬──────────────────────────────────────────┐
│ enable 조합                  │ 동작                                     │
├──────────────────────────────┼──────────────────────────────────────────┤
│ ch0 + ch1 + ch2 + ch3 = true │ dual mode (i2c1 / i2c2 양쪽 그룹 활성)   │
│ 한 그룹만 (예: ch0+ch1)       │ single mode (해당 i2c 그룹만)            │
│ 단일 채널만 (예: ch3=true)    │ single mode global                       │
│ 전체 false                   │ 카메라 미사용                            │
└──────────────────────────────┴──────────────────────────────────────────┘
```

---

## 9. 누락 키 자동 보강

부팅 시 시스템이 base 파일을 보강합니다. 다음 키는 누락되면 자동으로 채워지므로 직접 안 적어도 됩니다:

- `awb` 누락 → `"auto"`
- `gop` 누락 → `[0, 0]` (= fps 연동, 키프레임 1초 간격)
- `profile` 누락 → `[9, 9]` (Baseline)
- `quant` 누락 → `[-1, -1]` (자동)
- `qp_min` / `qp_max` 누락 → `[0, 0]` (미설정 = HW 기본값)
- `led_flash` 객체 누락 → `{ "enable": false, "wiper": 63, "flash_delay": 128 }`
- `led_flash.flash_delay`가 누락되면 128을 넣지만 **명시된 값은 보존합니다.**
  640x360@120에서는 제공된 high-FPS fragment가 활성 채널 호환값 0을 설정한다.
  이 보드의 활성 AR0234에서 128은 실제 CSI 전달률을 크게 낮췄으므로 설치/보강이
  운영자가 지정한 0을 덮어쓰지 않는다.
- `i2c[12].exp_time` 누락 → `10000`
- `queue_tune` / `rtsp_tune` / `capture`의 누락 키 → 기본값 자동 채움
- `app` → `"gstApp"`로 강제

구식 평탄 키(`bitrate`, `cam_chN`, `chN.exp_time`, `vflip`/`hflip` 최상위 등)는 부팅 시 자동 삭제됩니다 — 적어도 사라집니다.

---

## 10. 변경 후 확인

설정을 바꾸고 카메라 파이프라인 재시작 후, 보통 다음을 확인합니다:

- **enable / 모드** — 시스템 로그에서 채널 활성화 라인
- **bps** — 녹화 파일의 실제 비트레이트 (`mediainfo`, `ffprobe`)
- **gop / profile / quant / qp_min / qp_max** — 다섯 개 모두 **적용 성공 로그는 없습니다.**
  파싱된 값은 기동 시 채널별 요약 라인
  `ch<N> gop:..,.. profile:..,.. quant:..,.. qp_min:..,.. qp_max:..,..` 에서 확인합니다.
  이 라인은 "edgeconf에서 이렇게 읽었다"는 뜻이지 "인코더에 먹었다"는 뜻은 아닙니다.
- **적용 실패는 경고로만 드러납니다** — `profile`/`qp-min`/`qp-max`가 플러그인에 없으면
  `encoder has no '<속성>' property, <값> not applied` 경고가 남습니다. 이 경고가 보이면
  `gst-inspect-1.0 vpuenc_h264 | grep -E 'qp-min|qp-max|profile'` 로 확인하세요 —
  `profile`은 i.MX8MP에서만, `qp-min`/`qp-max`는 i.MX8MP와 i.MX8MM에서 노출됩니다
- **실측 확인** — 프로파일은 `ffprobe -show_streams` 의 `profile` 필드,
  gop은 녹화 파일의 키프레임 간격(`ffprobe -select_streams v -show_frames` 의
  `key_frame=1` 간격)으로 봅니다
- **VBR(자동 비트레이트) 확인** — `bps`를 `[0, 0]`으로 두면 기동 로그에
  `ch<N> rec bps 0: encoder rate control is automatic (VBR)` 이 남습니다.
  이 모드에서는 VPU가 해상도·fps로 목표 레이트를 산출하므로(1280×720@15 기준 약
  2.2 Mbps) 화면 복잡도에 따라 실제 파일 비트레이트가 변합니다 —
  `ffprobe -show_format` 의 `bit_rate` 를 장면을 바꿔가며 비교하면 고정 레이트와
  구분됩니다
- **vflip / hflip** — RTSP 스트림 또는 캡처 이미지 시각 확인
- **ae_on / ae_gain / exp_time** — 조도 변경 시 노출 적응
- **awb** — 조명색 변경 시 화이트밸런스 응답
- **led_flash** — 플래시 발광 + 밝기(wiper) 변화
- **NETWORK** — 네트워크 인터페이스 IP / ping 감시 동작
- **capture** — 트리거 → 응답 + 녹화/RTSP 부수효과

---

## 11. `edgeconf_cis_base.json`과의 차이

CIS 모델은 별도 base 파일(`edgeconf_cis_base.json`)을 사용합니다. 두 파일의 주요 차이는 `SENSORS` 섹션과 디바이스 매핑 일부이며, **VHL_CAM의 카메라 채널 스키마(awb / led_flash / 인코더 튜닝 키 포함)는 동일**합니다.
