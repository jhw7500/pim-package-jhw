# IIM-42652 패키지 반영 및 수동 활성화

## 적용 범위

`pim-package`는 IIM-42652 드라이버 모듈 3개와 전용 DTB를 포함하지만 자동으로
활성화하지 않는다. 기존 `imx8mp-evk.dtb`와 테스트용 `12m/16m/18m` DTB는
교체하지 않는다.

| 항목 | 값 |
|---|---|
| 커널 소스 기준 | `dc2d778fd210fe829b5e2973cbc6bfc9b246a929` |
| 기준 커널 | `e002bd363671fb43269987a4b08ca2ecb082ebaa` |
| 패치 보관 저장소 | `jhw7500/iim42652` (`9132465533ca5be3253c3935af827182753d56aa`) |
| 대상 커널 릴리스 | `5.10.35-lts-5.10.y+g2fce14defc04` |
| 빌드 명령 | `iim42652/scripts/build.sh --dtb` |

## 패키지 산출물

| 파일 | SHA-256 |
|---|---|
| `inv-icm42600.ko` | `b2f791f4fd51efc4ed02ac91db5ae431cd6764baa12b797ad38a0d33e48c43de` |
| `inv-icm42600-i2c.ko` | `d43a86296fb306f5779dd09c1f1feaf37fbd09637a5583a103927b1ef599bee6` |
| `inv_sensors_timestamp.ko` | `072048d96efe1afd968785841dc4943f0bb0a46d1c635c1f0a5764d4509313af` |
| `imx8mp-evk-iim42652.dtb` | `10b46b0c6f912f52b950211c2973270d1b3984f4a992382cc5a33874b0bd6ce1` |

세 모듈은 struct 및 symbol CRC가 결합된 한 빌드 세트다. 일부만 교체하면
`disagrees about version of symbol`로 적재가 거부될 수 있다.

## 패키지 설치 동작

패키지 `postinst`는 다음 작업만 수행한다.

1. dpkg가 모듈 3개를 `/lib/modules/5.10.35-lts-5.10.y+g2fce14defc04/updates/pim-iim42652/`에 직접 설치한다.
2. 각 모듈의 vermagic이 대상 커널 릴리스와 정확히 일치하는지 확인한다.
3. `depmod -a`를 실행한다.
4. IIM 전용 DTB를 부트 파티션에 복사한다.

모듈 경로는 dpkg가 소유하므로 제거하거나 IIM 미포함 버전으로 다운그레이드하면
파일도 함께 제거되고 `postrm`이 `depmod`를 갱신한다. `modprobe`를 실행하거나 IIM
모듈을 `/etc/modules`에 추가하지 않는다.
`/etc/modprobe.d/iim42652-manual.conf`가 DT modalias를 통한 자동 적재도 차단한다.
패키지 준비 단계는 고정 대상 커널의 모듈을 검증하고, 실제 수동 load 단계는 현재
실행 중인 커널이 그 대상과 정확히 같을 때만 허용한다.

## DTB 수동 선택

전용 DTB의 IIM 노드는 다음 값을 사용한다.

```text
compatible = "invensense,iim42652"
I2C5 clock-frequency = 400000
```

실제 부트 파일 선택은 보드별 기존 절차로 수동 수행한다. 현재 확인된 보드처럼
`/dev/mmcblk2p1/imx8mp-evk-test.dtb`를 사용한다면, 기존 파일을 백업한 뒤 패키지가
복사한 `imx8mp-evk-iim42652.dtb`를 활성 파일명으로 복사하고 재부팅한다.

활성 파일을 바꾸기 전 다음을 반드시 확인한다.

```bash
fw_printenv fdtfile
mount /dev/mmcblk2p1 /mnt/boot1
ls -l /mnt/boot1/imx8mp*.dtb
```

## 모듈 수동 제어

전용 DTB로 부팅한 뒤 다음 명령으로 적재한다.

```bash
/opt/pim/bin/iim42652_module.sh load
/opt/pim/bin/iim42652_module.sh status
```

명시적인 `modprobe`는 blacklist의 영향을 받지 않는다. load 명령은 I2C transport를
적재하며 `depmod`가 기록한 의존성에 따라 core와 timestamp 모듈도 함께 적재된다.

해제는 다음과 같다.

```bash
/opt/pim/bin/iim42652_module.sh unload
```

## 보드 검증

```bash
uname -r
lsmod | grep -E 'inv_icm42600|inv_sensors_timestamp'
ls /sys/bus/iio/devices/
dmesg | grep -Ei 'iim42652|icm426|unknown symbol|version of symbol'
```

기능 검증 기준은 다음과 같다.

- AAF 자동 선택: ODR 4 kHz에서 1962 Hz, ODR 1 kHz에서 488 Hz
- 가속도 단독 4 kHz: 실측 3700~4100 Hz
- 자이로/가속도 동시 1 kHz: 각 950~1200 Hz
- 타임스탬프 표본 주파수: 설정 ODR ±10%

검증 실패 시 모듈을 해제하고 백업한 DTB를 복원한 뒤 재부팅한다.
패키지 제거 또는 다운그레이드는 모듈 파일과 depmod 색인을 정리하지만, 운영자가
수동으로 활성 파일명에 복사한 DTB는 자동 복원하지 않는다.

## 재현 및 정적 검증

```bash
./test/test_iim42652_package.sh
python3 tools/verify_binaries.py --strict
```

모듈을 다시 빌드하면 세 `.ko`와 DTB, `.github/binary-manifest.json`, 이 문서를
같은 커밋에서 함께 갱신한다. `bitbake -c configure -f`는 `.scmversion`을 바꿔
vermagic을 깨뜨릴 수 있으므로 모듈 배포 빌드에는 사용하지 않는다.
