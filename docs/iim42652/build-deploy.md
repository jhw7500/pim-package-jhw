# IIM-42652 패키지 반영 및 수동 활성화

## 적용 범위

`pim-package`는 IIM-42652 드라이버 모듈 3개와 IIM 지원 DTB를 포함한다.
IIM 지원 DTB는 `imx8mp-evk.dtb` 기본 이름으로 배포하지만 모듈은 자동으로
적재하지 않는다. 이전 기본 DTB는 `imx8mp-evk-pre-iim42652.dtb`로 보존하며
테스트용 `12m/16m/18m` DTB는 교체하지 않는다.

| 항목 | 값 |
|---|---|
| 커널 소스 기준 | `dc2d778fd210fe829b5e2973cbc6bfc9b246a929` |
| 기준 커널 | `e002bd363671fb43269987a4b08ca2ecb082ebaa` (CSI0/CSI1 266 MHz) |
| 패치 보관 저장소 | `jhw7500/iim42652` (`9132465533ca5be3253c3935af827182753d56aa`) |
| 대상 커널 릴리스 | `5.10.35-lts-5.10.y+g2fce14defc04` |
| 빌드 명령 | `iim42652/scripts/build.sh --dtb` |

## 패키지 산출물

| 파일 | SHA-256 |
|---|---|
| `inv-icm42600.ko` | `b2f791f4fd51efc4ed02ac91db5ae431cd6764baa12b797ad38a0d33e48c43de` |
| `inv-icm42600-i2c.ko` | `d43a86296fb306f5779dd09c1f1feaf37fbd09637a5583a103927b1ef599bee6` |
| `inv_sensors_timestamp.ko` | `072048d96efe1afd968785841dc4943f0bb0a46d1c635c1f0a5764d4509313af` |
| `imx8mp-evk.dtb` | `10b46b0c6f912f52b950211c2973270d1b3984f4a992382cc5a33874b0bd6ce1` |
| `imx8mp-evk-pre-iim42652.dtb` | `a387929b7ef501eaa9f21c36ba2a262c2ab14156786cf93f191592ad0cca4fdc` |

세 모듈은 struct 및 symbol CRC가 결합된 한 빌드 세트다. 일부만 교체하면
`disagrees about version of symbol`로 적재가 거부될 수 있다.

## 패키지 설치 동작

패키지 `postinst`는 다음 작업만 수행한다.

1. dpkg가 모듈 3개를 `/lib/modules/5.10.35-lts-5.10.y+g2fce14defc04/updates/pim-iim42652/`에 직접 설치한다.
2. 각 모듈의 vermagic이 대상 커널 릴리스와 정확히 일치하는지 확인한다.
3. `depmod -a`를 실행한다.
4. 새 기본 DTB와 이전 기본 DTB 롤백 사본을 부트 파티션에 복사한다.

모듈 경로는 dpkg가 소유하므로 제거하거나 IIM 미포함 버전으로 다운그레이드하면
파일도 함께 제거되고 `postrm`이 `depmod`를 갱신한다. `modprobe`를 실행하거나 IIM
모듈을 `/etc/modules`에 추가하지 않는다.
`/etc/modprobe.d/iim42652-manual.conf`가 DT modalias를 통한 자동 적재도 차단한다.
패키지 준비 단계는 고정 대상 커널의 모듈을 검증하고, 실제 수동 load 단계는 현재
실행 중인 커널이 그 대상과 정확히 같을 때만 허용한다.

## 기본 DTB와 실제 부트 파일 선택

새 기본 DTB는 다음 값을 사용한다.

```text
compatible = "invensense,iim42652"
I2C5 clock-frequency = 400000
CSI0 clock-frequency / assigned-clock-rates = 266000000
CSI1 clock-frequency / assigned-clock-rates = 266000000
ISI0 interface = <2 0 2>
ISI1 interface = <3 0 2>
```

기준 커널 커밋 `e002bd363671fb43269987a4b08ca2ecb082ebaa`가 두 CSI를
`IMX8MP_SYS_PLL1_266M` 부모의 266 MHz로 설정한다. 교체 전 기본 DTB는 CSI0
500 MHz, CSI1 266 MHz였으며 `imx8mp-evk-pre-iim42652.dtb` 이름으로 보존한다.
새 기본 DTB는 IIM 노드뿐 아니라 CSI0 클락도 266 MHz로 전환한다. CSI1→ISI0
라우팅 교환은 아직 적용하지 않아 ISI interface는 기존 값을 유지한다.

패키지 `postinst`는 DTB 파일들을 부트 파티션에 복사하지만 bootloader의 활성
파일명은 바꾸지 않는다. `fdtfile=imx8mp-evk.dtb`인 보드는 새 기본 DTB를 사용한다.
현재 확인된 보드처럼 `/dev/mmcblk2p1/imx8mp-evk-test.dtb`를 사용한다면, 기존
활성 파일을 백업한 뒤 패키지가 복사한 `imx8mp-evk.dtb`를 활성 파일명으로
복사하고 재부팅한다.

이전 패키지에서 부트 파티션으로 복사된 `imx8mp-evk-iim42652.dtb`는 업그레이드
후에도 남을 수 있다. bootloader가 그 이름을 참조하지 않는지 확인하기 전에는
삭제하지 않는다.

활성 파일을 바꾸기 전 다음을 반드시 확인한다.

```bash
fw_printenv fdtfile
mount /dev/mmcblk2p1 /mnt/boot1
ls -l /mnt/boot1/imx8mp*.dtb
```

## 후속 TODO: CSI1 → ISI0 라우팅 교환

> 상태: **미적용**. 현재 기준 커밋 `b3263cf`의 기본 DTB는
> `ISI0=<2 0 2>`, `ISI1=<3 0 2>` 기존 매핑을 유지한다.

상세 설계와 검증 정본은 `pim-package-jhw` 커밋
`3167f26b9c57d0170e288354bb269b4e7678d4b9`의
`docs/imx8mp-max9296-isi-routing-plan.md`다. 후속 릴리스에서는 다음 네 항목을
같은 커밋과 배포 단위로 변경한다.

| 구성요소 | 현재 | 변경 목표 |
|---|---|---|
| 제품 DTS ISI0 | `interface=<2 0 2>` | `interface=<3 0 2>` (CSI1 → ISI0) |
| 제품 DTS ISI1 | `interface=<3 0 2>` | `interface=<2 0 2>` (CSI0 → ISI1) |
| gstApp video map | `csi0=video4`, `csi1=video3` | `csi0=video3`, `csi1=video4` |
| PIM capture map | ch01=ISI1/video4, ch23=ISI0/video3 | ch01=ISI0/video3, ch23=ISI1/video4 |

gstApp의 subdevice 값 `csi0=2`, `csi1=3`과 MAX9296 I2C/CSI 물리 연결은
변경하지 않는다. 새 DTB도 IIM-42652 노드, I2C5 400 kHz, CSI0/CSI1 266 MHz를
유지해야 한다. DTS, gstApp `v4l_map`, PIM capture map 중 일부만 배포하면 논리
채널과 health 판정 대상이 뒤바뀌므로 부분 배포 상태에서는 카메라 서비스를
시작하지 않는다.

보드에서는 `media-ctl -p`로 CSI1→ISI0→video3 및 CSI0→ISI1→video4를 확인하고,
두 video node의 양방향 시작 순서, 물리 카메라 위치, crop/control, 공용 FSYNC,
녹화·RTSP 채널, MIPI/ISI 오류와 지속적인 1프레임 offset을 검증한다.

이 작업 이후에는 ISI 폭 하드코딩(`ISI_2K=4096`, `ISI_4K=8192`) 검토,
single/dual LED flash 확인, 타임워치 기반 최종 프레임 싱크 검증, RTSP H.265
Frame ID 정렬을 순서대로 수행한다.

## 모듈 수동 제어

IIM 지원 기본 DTB로 부팅한 뒤 다음 명령으로 적재한다.

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

검증 실패 시 모듈을 해제하고 `imx8mp-evk-pre-iim42652.dtb` 또는 별도로 백업한
활성 DTB를 복원한 뒤 재부팅한다. 패키지 제거 또는 다운그레이드는 모듈 파일과
depmod 색인을 정리하지만, 운영자가 수동으로 활성 파일명에 복사한 DTB는 자동
복원하지 않는다.

## 재현 및 정적 검증

```bash
./test/test_iim42652_package.sh
python3 tools/verify_binaries.py --strict
```

모듈을 다시 빌드하면 세 `.ko`와 DTB, `.github/binary-manifest.json`, 이 문서를
같은 커밋에서 함께 갱신한다. `bitbake -c configure -f`는 `.scmversion`을 바꿔
vermagic을 깨뜨릴 수 있으므로 모듈 배포 빌드에는 사용하지 않는다.
