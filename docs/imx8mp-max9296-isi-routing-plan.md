# i.MX8MP MAX9296 CSI-ISI 채널 라우팅 변경 계획

> **상태: 계획(미적용).** 이 문서는 현재 dual-camera 경로를 기준으로
> DTS와 애플리케이션 매핑을 함께 교환하여, 물리 카메라 위치와 논리
> `ch0`~`ch3` 순서는 유지하면서 `ch0/ch1`을 ISI0에 할당하기 위한
> 변경 계획이다. 문서의 목표 구성을 현재 배포 상태로 해석하지 않는다.

## 1. 문서 목적

본 문서는 i.MX8MP에서 MAX9296이 출력하는 `3840x1080` UYVY 영상을
수신할 때의 현재 MIPI CSI-2/ISI 연결 구조를 기록하고, 다음 목표를
만족하는 변경 절차와 검증 기준을 정의한다.

- 물리 카메라 위치와 논리 채널 `ch0`~`ch3` 순서를 유지한다.
- 현재 `ch0/ch1`의 물리 입력인 CSI1을 ISI0으로 라우팅한다.
- 현재 `ch2/ch3`의 물리 입력인 CSI0을 ISI1으로 라우팅한다.
- DTS 라우팅, gstApp V4L2 장치 매핑, PIM 상태 감시 매핑을 한 변경
  단위로 취급한다.

현재 제품은 커널을 업데이트할 수 없으며, 본 문서의 운용
방안은 현재 배포된 Linux `5.10.35` 커널과 Device Tree를 유지하는
것을 전제로 한다.

Yocto 커널 트리에도 `drivers/media/i2c/max9296.c`가 있지만, 실제
제품 이미지에는 본 저장소 밖의 MAX9296 외부 모듈 소스로 빌드한
`max9296.ko` 패키지가 설치된다. 따라서 MAX9296 동작을 분석하거나
수정할 때는 배포 패키지와 대응하는 외부 모듈 revision을 실제 운용
코드로 확인한다. 개발자 PC의 절대 경로를 배포 계약으로 사용하지 않는다.

2~9절은 변경 전 기준 구조와 제약이고, 10절은 아직 적용되지 않은 목표
구성과 실행 절차다.

## 2. 현재 영상 경로

```text
MAX9296 (I2C2에서 제어)
  -> MIPI CSI-2.0
  -> ISI0 bypass
  -> /dev/video3
  -> 논리 ch2/ch3

MAX9296 (I2C3에서 제어)
  -> MIPI CSI-2.1
  -> ISI1 bypass
  -> /dev/video4
  -> 논리 ch0/ch1
```

이 현재 매핑은 본 저장소의
`dist/pim/opt/pim/config/camera_capture_map_v1.json`에도 다음과 같이
기록되어 있다.

| 논리 채널 | CSI IRQ | ISI IRQ | V4L2 node |
|---|---|---|---|
| ch0/ch1 | `32e50000.csi` | `32e02000.isi` | `/dev/video4` |
| ch2/ch3 | `32e40000.csi` | `32e00000.isi` | `/dev/video3` |

현재 media graph에서 두 MAX9296 출력은 모두 다음 포맷이다.

```text
UYVY8_2X8 / 3840x1080 / 15 fps
```

`I2C2`/`I2C3`는 MAX9296 레지스터 설정을 위한 **제어 버스**이다.
영상 데이터는 I2C를 통과하지 않고 MIPI CSI-2를 통해 ISI로
전달된다. 따라서 "I2C3에 ISI0을 연결한다"는 표현보다
"CSI-2.1 출력을 ISI0으로 라우팅한다"는 표현이 정확하다.

## 3. 현재 ISI 동작 상태

스트리밍 중 확인한 `CHNL_CTRL` 값은 다음과 같다.

```text
ISI0 @ 0x32e00000: CHNL_CTRL=0xE0000000
  EN=1, CLK=1, BYPASS=1, CHAIN=0, source=CSI0

ISI1 @ 0x32e02000: CHNL_CTRL=0xE0000001
  EN=1, CLK=1, BYPASS=1, CHAIN=0, source=CSI1
```

두 채널 모두 ISI의 출력 DMA는 사용하지만 CSC, scaling 등의
픽셀 처리는 수행하지 않는 bypass 상태이다.

### 3.1 MIPI CSI 내부 클럭

dual camera 운용에서는 NXP 기준에 따라 CSI0과 CSI1을 모두
266 MHz로 설정한다. SoC 공통 `imx8mp.dtsi`의 기본값을 직접
변경하지 않고 제품 DTS에서 다음과 같이 오버라이드한다.

```dts
&mipi_csi_0 {
	clock-frequency = <266000000>;
	assigned-clock-parents = <&clk IMX8MP_SYS_PLL1_266M>;
	assigned-clock-rates = <266000000>;
};

&mipi_csi_1 {
	clock-frequency = <266000000>;
	assigned-clock-parents = <&clk IMX8MP_SYS_PLL1_266M>;
	assigned-clock-rates = <266000000>;
};
```

이 클럭은 i.MX8MP 내부 CSI 처리 클럭이며 MAX9296 MIPI lane 속도,
GMSL 속도 또는 센서 FPS를 직접 변경하지 않는다.

### 3.2 ISI1의 `no-reset-control`

현재 `ISI1`에는 다음 커스텀 속성이 있다.

```dts
no-reset-control;
```

구형 ISI 드라이버는 ISI0과 ISI1이 공유하는 MediaMix reset을
exclusive 방식으로 획득한다. 두 채널이 같은 reset을 요청하면
ISI1 probe가 실패할 수 있기 때문에 ISI1의 다음 동작을 생략한
우회 설정이다.

- ISI PROC/APB reset 획득 및 assert/deassert
- MediaMix ISI PROC/APB/BUS gate clock 획득 및 enable/disable

ISI1은 ISI0이 관리하는 공유 reset/gate clock에 의존한다. 따라서
현재 커널에서는 `no-reset-control`만 제거해서는 안 되며, ISI0은
dual 구성에서 계속 활성화해야 한다. 향후 커널 수정이 가능하면
NXP의 shared reset 방식(`devm_reset_control_get_optional_shared()`)
적용 후 이 우회를 제거하는 것이 정식 해결 방법이다.

## 4. Bypass와 chain의 차이

### 4.1 Bypass

bypass에서는 ISI line buffer를 사용하는 픽셀 처리가 없으므로
ISI0과 ISI1이 각각 `3840x1080` 입력을 독립적으로 캡처할 수
있다.

```text
3840 bypass on ISI0 + 3840 bypass on ISI1: 가능
```

### 4.2 Chain

chain은 성능을 높이는 일반적인 최적화 기능이 아니다. 입력 폭이
2048 pixel을 넘는 영상에 CSC, scaling, crop 등을 적용할 때
두 ISI 채널의 line buffer를 합쳐 사용하는 방식이다.

```text
ISI0 -> ISI1 chain: 가능
ISI1 -> ISI0 chain: 불가능
```

ISI0가 ISI1을 chain buffer로 사용하는 동안 ISI1은 별도의 캡처
채널로 사용할 수 없다.

bypass 상태에서 CSI-2.1을 ISI0으로 옮겨도 chain은 사용되지
않으며, 성능, 화질, 메모리 대역폭 측면의 이득도 없다. 오히려
기존 CSI-2.0 -> ISI0 경로와 충돌하여 dual capture 구성을 어렵게
만든다.

## 5. 제품 모델별 운용 방안

| 제품 요구사항 | 운용 방안 | 현재 커널에서 가능 여부 |
|---|---|---:|
| 3840 영상 2개 단순 캡처 | ISI0/ISI1 각각 bypass | 가능 |
| 3840 영상 1개 단순 캡처 | 필요한 video node만 스트리밍 | 가능 |
| 3840 영상 1개 ISI 처리 | ISI0 -> ISI1 chain 필요 | 현재 커널에서 사용하지 않음 |
| 3840 영상 2개 ISI 처리 | 각 영상에 2채널 필요 | ISI 자원상 불가능 |
| 3840 입력을 1920 좌/우 두 출력으로 crop | 두 개의 독립 ISI 처리 필요 | ISI 자원상 불가능 |

3840 영상을 하나만 사용하는 제품도 라우팅을 바꾸지 않고
필요한 `/dev/videoX`만 열어서 사용한다. 사용하지 않는 채널은
스트리밍하지 않으면 된다.

## 6. 3840x1080을 1920x1080 두 영상으로 분리하는 방법

현재 커널에서는 하나의 `3840x1080` 입력을 ISI로 crop하여
두 개의 독립적인 `/dev/videoX` 출력으로 만들 수 없다.

커널을 변경하지 않는 조건에서는 `3840x1080` 영상을 bypass로
한 번 캡처한 뒤 사용자 공간에서 좌/우 영역을 분리한다.

UYVY 16-bit/pixel 기준의 메모리 배치는 다음과 같다.

```text
원본 stride      = 3840 * 2 = 7680 bytes
왼쪽 ROI offset  = 0 bytes
오른쪽 offset = 1920 * 2 = 3840 bytes
ROI 크기         = 1920x1080
```

후단 소비자가 stride와 buffer offset을 지원하면 같은 DMA-BUF의
좌/우 영역을 복사 없이 참조할 수 있다. 각 영상이 독립적인
연속 `1920x1080` 버퍼여야 하면 CPU, GPU 또는 G2D로 행 단위
복사가 필요하다.

## 7. 현재 커널에서의 금지 사항

현재 소스에는 다음 커스텀 수정이 적용되어 있다.

```c
#define ISI_2K 4096U /* original: 2048U */
#define ISI_4K 8192U /* original: 4096U */
```

이 수정은 `3840x1080` bypass 캡처 시 불필요한 chain 진입을
억제하여 현재 dual capture를 가능하게 한다. 하지만 실제 ISI
line buffer의 물리적인 폭이 늘어난 것은 아니다.

따라서 `3840x1080` 입력에 다음 기능을 활성화하지 않는다.

- ISI crop
- ISI scaling
- ISI CSC/format conversion
- ISI deinterlace
- 기타 non-bypass 픽셀 처리

이 기능들은 non-bypass 동작과 2048 pixel 초과 입력에 대한 정상적인
chain 자원 관리가 필요하므로 현재 커널에서 정상 동작을 보장할
수 없다.

## 8. 업스트림 드라이버 조사 결과

NXP `lf-6.6.y` 이상과 mainline Linux에는 기존
`drivers/staging/media/imx` 대신 다음 위치의 새 ISI 드라이버가
사용된다.

```text
drivers/media/platform/nxp/imx8-isi/
```

새 드라이버에는 다음 자원 관리 개선이 포함된다.

- 입력/출력 크기와 encoding에 따른 bypass 판단
- bypass 시 line buffer를 점유하지 않음
- non-bypass이고 입력 폭이 2048을 넘을 때만 chain 사용
- 다음 ISI 채널의 점유/충돌 검사
- crossbar routing, crop/compose, scaling, CSC, flip 지원

다만 기존 5.10 드라이버의 deinterlace 코드는 스트리밍 경로와
V4L2 control에 완성된 형태로 연결되어 있지 않다. 새 NXP/mainline
드라이버에서도 사용 가능한 deinterlace 기능이 확인되지 않았다.
따라서 deinterlace를 현재 제품에 적용할 수 있는 단순한 upstream
패치는 없다.

업스트림 구조는 향후 커널 변경이 가능해졌을 때의 참고용이며,
현재 배포 방안에는 적용하지 않는다.

### 8.1 참고 자료

- [NXP lf-6.12 ISI pipeline/bypass 구현](https://github.com/nxp-imx/linux-imx/blob/lf-6.12.y/drivers/media/platform/nxp/imx8-isi/imx8-isi-pipe.c)
- [NXP lf-6.12 ISI channel/chain 구현](https://github.com/nxp-imx/linux-imx/blob/lf-6.12.y/drivers/media/platform/nxp/imx8-isi/imx8-isi-hw.c)
- [NXP lf-6.12 ISI crossbar 구현](https://github.com/nxp-imx/linux-imx/blob/lf-6.12.y/drivers/media/platform/nxp/imx8-isi/imx8-isi-crossbar.c)
- [Mainline i.MX8 ISI 드라이버 병합 커밋](https://github.com/torvalds/linux/commit/cf21f328fcafacf4f96e7a30ef9dceede1076378)
- [NXP AN13857: i.MX 8M Series MIPI Capture System](https://community.nxp.com/pwmxy87654/attachments/pwmxy87654/imx-processors/241658/1/AN13857%28i.MX%208M%20Series%20MIPI%20Capture%20System%29.pdf)

## 9. 운용 점검 방법

### 9.1 Media graph 확인

```sh
media-ctl -p
```

다음 경로와 포맷을 확인한다.

```text
max9296 -> mxc-mipi-csi2.0 -> mxc_isi.0 -> capture
max9296 -> mxc-mipi-csi2.1 -> mxc_isi.1 -> capture
UYVY8_2X8/3840x1080
```

`/dev/videoX` 번호는 probe 순서에 따라 바뀌 수 있으므로 고정 번호보다
`media-ctl -p` 결과의 entity 연결을 기준으로 판단한다.

### 9.2 스트리밍 중 ISI 상태 확인

```sh
devmem2 0x32e00000 w
devmem2 0x32e02000 w
```

정상적인 dual-bypass 운용에서는 두 ISI 모두 다음 상태여야
한다.

```text
EN=1, CLK=1, BYPASS=1, CHAIN=0
```

### 9.3 운용 원칙

1. dual model은 ISI0과 ISI1을 각각 bypass로 사용한다.
2. single model은 필요한 video node만 스트리밍한다.
3. `3840x1080` 입력에 ISI crop/scaling/CSC를 활성화하지 않는다.
4. 좌/우 FHD 분리는 사용자 공간 또는 G2D/GPU에서 수행한다.
5. CSI-ISI 라우팅을 교환할 때는 video node의 물리 카메라 매핑도
   반드시 함께 교환한다.

## 10. Dual CSI-ISI 라우팅 변경 계획

### 10.1 목적과 상태

다음 변경은 두 MAX9296, 두 CSI, 두 ISI를 모두 활성화한 dual DTS에서
현재 논리 `ch0/ch1`인 i2c3/CSI1 영상을 reset/chain 관리의 기준
채널인 ISI0에 배치하기 위한 계획이다. single DTS 생성은 범위에
포함하지 않는다.

변경의 불변 조건은 다음과 같다.

- 전방/후방 또는 좌/우로 정의된 물리 카메라 위치를 바꾸지 않는다.
- 논리 `ch0/ch1`과 `ch2/ch3`의 이름, 녹화 채널, RTSP 채널을 바꾸지 않는다.
- 각 `3840x1080` 입력 내부의 좌우 FHD crop 순서를 바꾸지 않는다.
- CSI0/CSI1과 MAX9296의 물리 연결 및 I2C 제어 버스는 바꾸지 않는다.
- DTS의 CSI→ISI 입력 선택과 그 결과로 달라지는 V4L2 node 매핑만
  애플리케이션 설정과 함께 교환한다.

현재 이 변경은 적용되지 않았다. 실제 DTS의 `interface`, gstApp
`v4l_map`, PIM capture map을 모두 변경하고 검증하기 전까지 2절의
기준 경로를 현재 상태로 본다.

### 10.2 변경 전후 경로

변경 전:

```text
i2c2 MAX9296_0 -> CSI0 -> ISI0 -> /dev/video3
                         -> 논리 ch2/ch3
i2c3 MAX9296_1 -> CSI1 -> ISI1 -> /dev/video4
                         -> 논리 ch0/ch1
```

변경 후:

```text
i2c3 MAX9296_1 -> CSI1 -> ISI0 -> /dev/video3
                         -> 논리 ch0/ch1
i2c2 MAX9296_0 -> CSI0 -> ISI1 -> /dev/video4
                         -> 논리 ch2/ch3
```

`/dev/video3`과 `/dev/video4` 번호 자체가 교환되는 것이 아니라,
각 video node 뒤에 연결된 물리 MAX9296 영상이 교환된다. 애플리케이션은
video node가 아니라 논리 채널을 기준으로 같은 물리 카메라를 계속
제공해야 한다.

### 10.3 DTS 변경 항목

제품 DTS의 ISI 입력만 다음과 같이 교환한다.

```dts
&isi_0 {
	interface = <3 0 2>; /* MIPI CSI1, VC0, memory */
	status = "okay";

	cap_device {
		status = "okay";
	};

	m2m_device {
		status = "okay";
	};
};

&isi_1 {
	interface = <2 0 2>; /* MIPI CSI0, VC0, memory */
	status = "okay";

	cap_device {
		status = "okay";
	};
};
```

`interface`의 세 값은 차례대로 입력, virtual channel, 출력을
나타낸다.

```text
입력 2 = MIPI CSI0
입력 3 = MIPI CSI1
VC  0 = VC0
출력 2 = memory capture
```

다음 항목은 변경하지 않는다.

- `max9296_0`의 `csi_id = <0>`
- `max9296_1`의 `csi_id = <1>`
- MAX9296와 MIPI CSI 사이의 `remote-endpoint`
- I2C2/I2C3 노드 및 GPIO
- CSI0/CSI1의 266 MHz 설정
- ISI1의 `no-reset-control`
- 공유 전원 및 FSYNC 소유권

### 10.4 애플리케이션 영향

기존과 같은 물리 카메라와 논리 채널을 유지하려면 DTS와 같은 배포
단위에서 애플리케이션 매핑을 다음과 같이 교환한다.

| 논리 채널 | 물리 입력 | 변경 전 | 변경 후 |
|---|---|---|---|
| ch0/ch1 | i2c3 MAX9296, CSI1 | `/dev/video4` | `/dev/video3` |
| ch2/ch3 | i2c2 MAX9296, CSI0 | `/dev/video3` | `/dev/video4` |

#### 10.4.1 gstApp

gstApp의 `csi0`과 `csi1` 이름은 이 제품에서 각각 논리 채널 그룹
`ch0/ch1`과 `ch2/ch3`을 선택한다. 하드웨어의 MIPI CSI0/CSI1 이름과
혼동해서는 안 된다. 현재 기본값은 `csi0_video=4`, `csi1_video=3`이며,
`videoBin.cpp`는 이 값을 각 `v4l2src`의 `device`로 사용한다.

라우팅 변경 DTS와 함께 배포하는 JSON에는 다음 override를 적용한다.

```json
"v4l_map": {
  "csi0_subdev": 2,
  "csi1_subdev": 3,
  "csi0_video": 3,
  "csi1_video": 4
}
```

`csi0_subdev`와 `csi1_subdev`는 기존 물리 카메라 제어 경로를 유지하므로
교환하지 않는다. `csi0_video`와 `csi1_video`만 교환한다. gstApp 시작
로그에서 다음 최종값을 확인한다.

```text
v4l_map subdev(csi0=2,csi1=3) video(csi0=3,csi1=4)
```

기존 DTS를 사용하는 제품에 새 video 기본값을 적용하면 채널이 뒤바뀐다.
따라서 모든 제품 DTS를 동시에 전환하기 전에는 `parser.h`의 전역 기본값을
바꾸지 않고, 라우팅 변경 DTS와 결합된 제품 JSON에서 명시적으로 override한다.

#### 10.4.2 PIM capture health map

`dist/pim/opt/pim/config/camera_capture_map_v1.json`은 다음과 같이
갱신한다. CSI IRQ는 물리 CSI 연결이 그대로이므로 유지하고, ISI IRQ와
V4L2 node만 교환한다.

| domain | CSI IRQ | 변경 후 ISI IRQ | 변경 후 node |
|---|---|---|---|
| ch01 | `32e50000.csi` | `32e00000.isi` | `/dev/video3` |
| ch23 | `32e40000.csi` | `32e02000.isi` | `/dev/video4` |

`docs/camera-health/capture-probe.md`의 고정 mapping 표도 같은 커밋에서
갱신한다. DTS만 바꾸고 이 map을 유지하면 health probe가 정상 경로를
반대 채널의 상태로 해석할 수 있으므로 배포를 허용하지 않는다.

#### 10.4.3 채널 의미 유지

다음 항목이 video 번호를 기준으로 관리된다면 같은 물리 카메라를
따라 함께 교환해야 한다.

- 노출, gain, FPS, rotate, enable 등 카메라별 설정
- 카메라 보정값과 전방/후방 또는 좌/우 의미
- 스티칭 순서와 녹화 채널명
- 상태 감시 및 오류 복구 대상
- media entity/pad를 직접 지정하는 `media-ctl` 스크립트

MAX9296 subdevice와 I2C sysfs 경로는 물리 CSI 연결이 그대로이므로
라우팅 교환만으로 바뀌지 않는다. 다만 애플리케이션이 video node와
subdevice의 대응표를 갖고 있다면 그 대응표는 갱신해야 한다.

공용 카메라 전원과 FSYNC의 소유자는 계속 i2c2의 `MAX9296_0`이다.
라우팅 교환 후에는 이 장치의 영상이 `/dev/video4`로 나오므로,
애플리케이션이 `/dev/video3`을 FSYNC master라고 가정해서는 안 된다.

### 10.5 ISI 기능 및 reset 영향

라우팅 교환 후에도 ISI0과 ISI1은 모두 활성화하므로 공유 reset
구조와 `no-reset-control` 우회는 유지된다. MAX9296 드라이버,
MIPI CSI 드라이버 및 ISI 드라이버의 소스 변경은 필요하지 않다.

i2c3 영상은 ISI0의 chain 가능성을 갖지만 현재는 `BYPASS=1`,
`CHAIN=0`이고 `ISI_2K=4096` 커스텀 패치가 적용되어 있으므로
즉시 얻는 성능 이득은 없다. 반대로 i2c2 영상은 chain을 사용할
수 없는 ISI1으로 이동한다. 현재 dual bypass 용도에서는 두 경로의
출력 형식과 DMA capture 동작이 동일해야 한다.

### 10.6 구현 및 배포 단위

다음 변경은 같은 제품 release로 준비한다.

| 구성요소 | 변경 |
|---|---|
| 제품 DTS | `isi_0.interface=<3 0 2>`, `isi_1.interface=<2 0 2>` |
| 제품용 gstApp JSON | `csi0_video=3`, `csi1_video=4`; subdev 값 유지 |
| PIM capture map | ch01/ch23의 ISI IRQ와 video node 교환 |
| 운영 문서 | camera-health 고정 mapping과 점검 예시 갱신 |

전역 gstApp 기본값과 MAX9296/CSI/ISI 드라이버 소스는 이번 변경에서
수정하지 않는다. DTS만 먼저 배포하거나 애플리케이션 map만 먼저
배포하면 논리 채널 또는 상태 감시 대상이 반대로 해석될 수 있으므로,
부분 배포 상태에서 카메라 서비스를 시작하지 않는다.

배포 순서는 다음과 같다.

1. 변경 전 DTB, 제품 JSON, PIM capture map의 version과 checksum을 기록한다.
2. 변경 후 DTB와 대응하는 두 사용자 공간 map을 하나의 release로 준비한다.
3. 유지보수 구간에서 카메라 서비스를 정상 종료한다.
4. 세 artifact를 배포하고 재부팅한다.
5. gstApp 시작 전에 media graph와 V4L2 node 경로를 확인한다.
6. 경로가 목표 구성과 일치할 때만 gstApp과 health probe를 실행한다.

### 10.7 변경 후 검증

`media-ctl -p`에서 다음 경로를 확인한다.

```text
max9296 on i2c3 -> mxc-mipi-csi2.1 -> mxc_isi.0 -> /dev/video3
max9296 on i2c2 -> mxc-mipi-csi2.0 -> mxc_isi.1 -> /dev/video4
```

`/dev/videoX` 번호만으로 물리 카메라를 추정하지 않고, media entity와
endpoint를 따라 i2c3 입력이 `/dev/video3`, i2c2 입력이 `/dev/video4`에
도달하는지 확인한다. 최종 제품에서는 가능하면 media topology 또는
udev symbolic link로 물리 입력을 식별한다.

두 스트림 시작 순서를 모두 시험한다.

```text
/dev/video3 시작 -> /dev/video4 시작
/dev/video4 시작 -> /dev/video3 시작
```

각 순서에서 다음을 확인한다.

- 두 node 모두 `3840x1080 UYVY`와 요구 FPS로 STREAMON/DQBUF가 진행된다.
- ISI0과 ISI1 모두 `EN=1, CLK=1, BYPASS=1, CHAIN=0`이다.
- MIPI CRC/ECC/FIFO overflow/lost-frame 오류가 새로 발생하지 않는다.
- 반복 stream on/off 후 두 시작 순서 모두 재시작된다.
- gstApp 최종 설정 로그가 `video(csi0=3,csi1=4)`를 출력한다.
- 논리 ch0/ch1이 기존 물리 카메라 위치, crop, control, 녹화 및 RTSP
  채널을 그대로 유지한다.
- 논리 ch2/ch3도 같은 항목을 그대로 유지한다.
- 카메라별 노출, gain, FPS, rotate, enable 및 공용 FSYNC가 기존
  물리 카메라에 적용된다.
- 갱신한 capture map으로 수동 one-shot health probe를 실행했을 때
  ch01은 CSI1/ISI0/video3, ch23은 CSI0/ISI1/video4로 보고된다.
- V4L2 sequence/PTS trace에서 네 논리 채널의 누락·역행 및 지속적인
  1프레임 offset이 없다.

### 10.8 실패 조건과 원복

다음 중 하나라도 발생하면 변경을 합격 처리하지 않는다.

- media graph가 목표 CSI→ISI 경로와 다르다.
- node 하나가 열리지 않거나 시작 순서에 따라 STREAMON이 실패한다.
- 물리 카메라 위치와 논리 채널, crop 또는 control 대상이 바뀐다.
- gstApp 최종 map이나 health probe map이 목표값과 다르다.
- 새 MIPI/ISI 오류, 프레임 누락, sequence 역행 또는 1프레임 offset이
  발생한다.

원복할 때는 카메라 서비스를 종료한 후 변경 전 DTB, 제품 JSON,
PIM capture map을 함께 복원하고 재부팅한다. 일부만 원복하지 않는다.
재부팅 후 2절의 기존 media graph, gstApp
`video(csi0=4,csi1=3)`, ch01=video4/ISI1 및 ch23=video3/ISI0을
다시 확인한 뒤 서비스를 정상 상태로 복귀시킨다.

## 11. 결론

커널을 업데이트할 수 없는 현재 제약에서는 기존
dual-bypass 구조와 `266/266 MHz` CSI 클럭을 사용한다.

목표는 i2c3/CSI1의 기존 논리 ch0/ch1 영상을 ISI0/video3에 배치하고,
i2c2/CSI0의 기존 논리 ch2/ch3 영상을 ISI1/video4에 배치하는 것이다.
교환 자체에는 커널 또는 드라이버 코드 수정이 필요하지 않지만, 물리
카메라와 논리 채널을 유지하려면 DTS, gstApp `v4l_map`, PIM capture
map을 반드시 같은 release에서 함께 변경해야 한다.

ISI chain은 bypass 운용에 즉각적인 성능 이득을 제공하지 않는다.
`3840x1080` 영상의 crop, scaling 또는 좌/우 분리가 필요하면 bypass
캡처 후 사용자 공간에서 처리한다. single DTS 구성은 별도 검토
항목이며 본 변경 범위에서 제외한다.
