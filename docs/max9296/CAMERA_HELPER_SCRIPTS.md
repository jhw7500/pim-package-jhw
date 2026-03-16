# Camera Helper Scripts Guide

이 문서는 현재 유지하는 `cam_ap1302*.sh`, `cam_ar0234*.sh` 스크립트의 목적과 사용법을 정리한다.

기준은 다음과 같다.

- 현재 검증된 센서 접근 경로는 **AP1302 DMA 기반 raw register access**다.
- 구형 `SIPM` 실험 스크립트는 정리했다.
- 범용 read/write는 `cam_ap1302_dma_verify.sh`를 기준으로 하고, 나머지는 안전장치나 의미 해석을 더하는 래퍼다.
- 첫 번째 인자는 **채널 번호(0,1,2,3)** 다.
- 스크립트가 내부에서 `ch0/ch1 -> i2c2`, `ch2/ch3 -> i2c1`를 적용한다.
- AP1302 주소는 `edgeconf_pim.json`을 우선 사용하고, 없으면 `i2cdetect`로 single/dual을 판단해 `0x3c/0x11/0x12` 중에서 자동 결정한다.

---

## 1. 핵심 스크립트

### `cam_ap1302_dma_verify.sh`

목적:

- AP1302 DMA 경유로 AR0234 임의 레지스터를 읽는다.
- 값을 주면 write 후 readback까지 검증한다.

인자 순서:

- `channel`
- `register`
- `value` (`read`에서는 생략)

예시:

```bash
# 읽기
./cam_ap1302_dma_verify.sh 0 0x3000

# 쓰기 + 검증
./cam_ap1302_dma_verify.sh 0 0x3070 0x0001
```

비고:

- 대부분의 나머지 스크립트는 이 스크립트를 내부적으로 호출한다.
- 임의 레지스터를 다룰 때 가장 먼저 고려할 기본 엔진이다.

### `cam_ap1302_diag_regs.sh`

목적:

- AP1302 진단 레지스터를 직접 읽는다.
- `SIPM_ERR_0/1`, `SENSOR_SELECT`, `PRIMARY_SENSOR_SIP`, `SECONDARY_SENSOR_SIP` 상태를 확인한다.

인자 순서:

- `channel`

예시:

```bash
./cam_ap1302_diag_regs.sh 0
./cam_ap1302_diag_regs.sh 3
```

사용 시점:

- 센서 접근 경로가 맞는지 확인할 때
- AP1302가 어느 sensor port를 선택했는지 볼 때

---

## 2. 범용 레지스터 접근

### `cam_ap1302_dma_verify.sh`

목적:

- AR0234 임의 레지스터를 읽는다.
- 값을 주면 write 후 readback까지 검증한다.

예시:

```bash
# read
./cam_ap1302_dma_verify.sh 0 0x3000
./cam_ap1302_dma_verify.sh 0 0x3070

# write + verify
./cam_ap1302_dma_verify.sh 0 0x3070 0x0001
./cam_ap1302_dma_verify.sh 0 0x3036 0x0008
```

주의:

- 상태 비트가 섞인 레지스터에는 exact readback이 맞지 않을 수 있다.
- `0x3270` 같은 LED flash control은 전용 스크립트를 권장한다.

---

## 3. LED Flash 전용 스크립트

### `cam_ar0234_led_flash_read.sh`

목적:

- `0x3270` 값을 읽고 `enable/delay` 필드로 해석한다.

인자 순서:

- `channel`

예시:

```bash
./cam_ar0234_led_flash_read.sh 0
```

출력 예:

```text
raw=0x0103 masked=0x0103 enable=1 delay=3 extra=0x0000
```

### `cam_ar0234_led_flash_write.sh`

목적:

- `0x3270`를 쓰고 `0x01ff` 마스크 기준으로 검증한다.
- 단순 exact readback이 아닌 LED 전용 검증을 제공한다.

인자 순서:

- `channel`
- `value`

예시:

```bash
./cam_ar0234_led_flash_write.sh 0 0x0000
./cam_ar0234_led_flash_write.sh 0 0x0103
```

의미:

- `bit8`: enable
- `bit7:0`: delay

---

## 4. Clock 관련 스크립트

### `cam_ar0234_dma_clock_dump.sh`

목적:

- clock/serial-format 관련 주요 레지스터를 한 번에 읽는다.

인자 순서:

- `channel`

조회 레지스터:

- `0x31ae`
- `0x302a`
- `0x302c`
- `0x302e`
- `0x3030`
- `0x3036`
- `0x3038`
- `0x30ba`

예시:

```bash
./cam_ar0234_dma_clock_dump.sh 0
```

### `cam_ar0234_dma_clock_safe.sh`

목적:

- 위 clock 레지스터들을 backup/set/restore로 안전하게 다룬다.

인자 순서:

- `backup <channel>`
- `set <channel> <reg> <value>`
- `restore <channel>`

예시:

```bash
./cam_ar0234_dma_clock_safe.sh backup 0
./cam_ar0234_dma_clock_safe.sh set 0 0x3036 0x0008
./cam_ar0234_dma_clock_dump.sh 0
./cam_ar0234_dma_clock_safe.sh restore 0
```

사용 시점:

- divider 값을 바꿔 실험할 때
- 실험 후 원래 값으로 복구할 때

## 5. 권장 사용 순서

1. 경로 확인: `cam_ap1302_diag_regs.sh`
2. 범용 읽기/쓰기: `cam_ap1302_dma_verify.sh`
3. 일반 레지스터 작업: `cam_ap1302_dma_verify.sh`
4. LED flash 제어: `cam_ar0234_led_flash_read.sh`, `cam_ar0234_led_flash_write.sh`
5. clock 실험: `cam_ar0234_dma_clock_dump.sh`, `cam_ar0234_dma_clock_safe.sh`

---

## 6. 정리된 스크립트

다음 스크립트는 정리했다.

- `cam_ar0234_sipm_verify.sh`
- `cam_ar0234_sipm_matrix.sh`
- `cam_ar0234_sipm_scan.sh`
- `cam_ar0234_sipm_probe_candidate.sh`
- `cam_ar0234_reg_read.sh`
- `cam_ar0234_reg_write.sh`
- `cam_ar0234_dma_test_pattern.sh`
- `cam_ar0234_dma_clock_sweep.sh`

이유:

- 현재 문서와 실측 결과 기준으로 정답 경로는 DMA다.
- SIPM window 기반 실험 스크립트는 운영 경로로 쓰지 않는다.
- 일반 read/write와 test pattern, clock sweep은 핵심 스크립트 조합으로 충분히 대체된다.
