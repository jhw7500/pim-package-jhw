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
└──────────────┴────────────────────┴───────────────────────────────────────────────┘
```

**예시 — 캡처 + 녹화 + RTSP**:
```json
"capture": { "enable": true, "delay": 0, "timeout": 1000,
             "record": true, "rtsp": true,
             "encoder": "turbo", "quality": 85 }
```

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
│ awb                  │ §8.3 표 참조    │ 화이트밸런스 프리셋                              │
│ led_flash.enable     │ true/false      │ LED 플래시 사용 여부 (false면 wiper도 미적용)    │
│ led_flash.wiper      │ 0~127 (7-bit)   │ MCP4018T-503E 디지털 포텐셔미터 wiper step.      │
│                      │ 기본 63 (mid)   │ 50kΩ 128단계. 밝기/저항 방향은 보드 LED 회로에   │
│                      │                 │ 따라 다름 — 0/127이 양 끝값                       │
│ led_flash.flash_delay│ 0~255 (8-bit)   │ AR0234 R0x3270 bit7:0 DELAY 필드. 단위는 센서    │
│                      │ 기본 0          │ row-time 기반. 0이면 노출 시작과 동시에 발광     │
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
- `led_flash` 객체 누락 → `{ "enable": false, "wiper": 63, "flash_delay": 0 }`
- `i2c[12].exp_time` 누락 → `10000`
- `queue_tune` / `rtsp_tune` / `capture`의 누락 키 → 기본값 자동 채움
- `app` → `"gstApp"`로 강제

구식 평탄 키(`bitrate`, `cam_chN`, `chN.exp_time`, `vflip`/`hflip` 최상위 등)는 부팅 시 자동 삭제됩니다 — 적어도 사라집니다.

---

## 10. 변경 후 확인

설정을 바꾸고 카메라 파이프라인 재시작 후, 보통 다음을 확인합니다:

- **enable / 모드** — 시스템 로그에서 채널 활성화 라인
- **bps** — 녹화 파일의 실제 비트레이트 (`mediainfo`, `ffprobe`)
- **vflip / hflip** — RTSP 스트림 또는 캡처 이미지 시각 확인
- **ae_on / ae_gain / exp_time** — 조도 변경 시 노출 적응
- **awb** — 조명색 변경 시 화이트밸런스 응답
- **led_flash** — 플래시 발광 + 밝기(wiper) 변화
- **NETWORK** — 네트워크 인터페이스 IP / ping 감시 동작
- **capture** — 트리거 → 응답 + 녹화/RTSP 부수효과

---

## 11. `edgeconf_cis_base.json`과의 차이

CIS 모델은 별도 base 파일(`edgeconf_cis_base.json`)을 사용합니다. 두 파일의 주요 차이는 `SENSORS` 섹션과 디바이스 매핑 일부이며, **VHL_CAM의 카메라 채널 스키마(awb / led_flash 포함)는 동일**합니다.
