# pim-package-jhw 외부 팀 DEB 전달 설계

> 작성일: 2026-08-31  
> 상태: 구현 전 설계 승인본  
> 내부 코드 기준: `pim-package-jhw` `749bd0aea613deeb6f7764daaa39d2561347f91a` 이후 문서 전용 커밋  
> 전달 대상: 동일 i.MX8MP / Ubuntu 20.04 / `5.10.35-lts-5.10.y+g2fce14defc04`

## 1. 결정

상대 팀에는 개인 GitHub 저장소나 소스를 공유하지 않는다. 전달물은 다음 두 파일로
제한한다.

1. `pim-mp_0.6.3+jhw.camera1_arm64.deb`
2. `PIM_PACKAGE_JHW_CAMERA_VPU_HANDOFF_2026-08-31.md`

체크섬, 빌드 식별자, 설치 및 롤백 정보는 두 번째 문서에 포함한다. GitHub Release,
전체 업그레이드 ZIP/TAR, GitLab 반영은 이번 범위가 아니다.

## 2. 배경과 현재 상태

최신 코드와 패키징 원본은 `dist/pim`에 반영돼 있지만 기존
`release/pim-mp-0.6.3.deb`는 최신 통합 전에 생성된 로컬 산출물이다. `release/`는 Git
추적 대상이 아니므로 코드 머지로 자동 갱신되지 않는다.

감사 결과는 다음과 같다.

| 구성요소 | 최신 `dist/pim` | 기존 DEB | 판정 |
|---|---|---|---|
| `gstApp` | `c816f84094f7...` | `b20bfd1cdaf7...` | 불일치 |
| `max9296.ko` | `b27ae021fe4c...` | `26cff9097b4e...` | 불일치 |
| `update_edgeconf.sh` | `086b971fac74...` | `6e5e5d08a5ba...` | 불일치 |
| VPU plugin/wrapper | 최신과 동일 | 최신과 동일 | 일치 |
| 360p/FPS/프레임 검사 도구 | 포함 | 누락 | 불일치 |
| 640x360 JSON fragment | 포함 | 누락 | 불일치 |

따라서 기존 DEB를 재사용하지 않고 최신 `dist/pim`을 입력으로 새 DEB를 만든다.

## 3. 목표와 비목표

### 목표

- 상대 팀이 기존 GitLab 기반 장비 한 대에서 최신 카메라/VPU 동작을 독립적으로 설치하고
  검증할 수 있게 한다.
- DEB 하나로 최신 `gstApp`, MAX9296 드라이버, VPU 라이브러리, edgeconf 마이그레이션,
  360p 진단 도구를 함께 전달한다.
- 설치 전 상태를 보존하고 실패 시 기존 DEB와 설정으로 복구할 수 있게 한다.
- 1920x1080, 1280x720, 640x360 출력과 독립적인 digital crop 동작을 구분해 검증한다.

### 비목표

- GitLab `pim-package`와의 소스 통합 또는 브랜치 머지
- 개인 GitHub 저장소, 커밋 링크 또는 빌드 환경 공유
- 센서 native 640x360 readout 지원 선언
- 120 FPS를 production 지원값으로 선언
- 수동 WB 레지스터 `0x510a` 신규 사용
- 운영 장비 전체 배포

## 4. 전달 패키지 식별

DEB 메타데이터는 다음을 사용한다.

| 필드 | 값 |
|---|---|
| Package | `pim-mp` |
| Version | `0.6.3+jhw.camera1` |
| Architecture | `arm64` |
| 대상 커널 | `5.10.35-lts-5.10.y+g2fce14defc04` |

기존 `0.6.3`과 구분하기 위해 Debian local-version 형태의
`0.6.3+jhw.camera1`을 사용한다. 설치 후 `dpkg-query`만으로 전달본 여부를 확인할 수
있고, 향후 정식 `0.6.4`는 이 시험 버전보다 높은 버전으로 자연스럽게 교체할 수 있다.

외부 문서에는 개인 저장소 주소를 넣지 않는다. 내부 추적용 소스 기준과 구성요소
SHA-256은 전달 문서의 "공급자 추적 정보" 절에 저장소 링크 없이 기록한다.

## 5. 패키징 설계

패키징은 현재 `dist/pim`을 임시 staging 디렉터리로 복사한 뒤 수행한다. 원본
`dist/pim/DEBIAN/control`의 정식 제품 버전은 변경하지 않고 staging 사본에서만 시험
버전을 적용한다.

패키징 게이트는 다음 순서다.

```text
최신 dist/pim
  -> tracked 파일과 working tree 내용 일치 확인
  -> binary manifest strict 검증
  -> 임시 staging + Version override
  -> dpkg-deb --root-owner-group --build
  -> DEB metadata/file list 검사
  -> DEB 재추출 후 dist와 핵심 파일 SHA-256 비교
  -> lint/maintainer-script 정적 검사
  -> 대상 보드 설치 및 동작 검증
  -> 최종 DEB SHA-256을 전달 문서에 고정
```

핵심 비교 대상은 아래 파일이다.

- `/usr/local/bin/gstApp`
- `/opt/pim/driver/max9296.ko`
- `/usr/lib/gstreamer-1.0/libgstvpu.so`
- `/usr/lib/libfslvpuwrap.so.3.0.0`
- `/opt/pim/bin/update_edgeconf.sh`
- `/opt/pim/bin/cam_fps_stack.sh`
- `/opt/pim/bin/cam_360p_resource.sh`
- `/opt/pim/bin/uyvy_frame_check.py`
- `/opt/pim/bin/rgb565_frame_check.py`
- `/opt/pim/config/edgeconf_pim_base.json`
- `/opt/pim/config/max9296_640x360_fragment.json`

## 6. 설치 안전 정책

`pim-mp`의 `postinst`는 카메라 파일만 교체하지 않는다. 커널 모듈, systemd 서비스,
시스템 설정, 네트워크 관련 파일, 기본 edgeconf 및 심볼릭 링크도 처리한다. 따라서
다음 조건을 모두 만족할 때만 설치한다.

1. 지정된 시험 보드일 것
2. `aarch64`, Ubuntu 20.04, 정확한 대상 커널일 것
3. 현재 `pim-mp` 버전과 기존 설치 DEB를 확보할 것
4. `/root/shared_v/edgeconf*.json`, `ord_vcm_conf.json`, `/etc/defaultconf.json`을 백업할 것
5. 설치 중 카메라 및 녹화 중단이 허용될 것

커널 문자열이 다르면 설치를 중단한다. `max9296.ko`의 vermagic 불일치 상태에서
강제 로드하지 않는다.

## 7. 설정 모델

### 7.1 출력 해상도

`VHL_CAM.cam_width`, `VHL_CAM.cam_height`는 AP1302/CSI 출력 크기를 고른다.

| 카메라당 출력 | single V4L2 | dual-wide V4L2 | production FPS |
|---|---|---|---:|
| 1920x1080 | 1920x1080 | 3840x1080 | 30 |
| 1280x720 | 1280x720 | 2560x720 | 30 |
| 640x360 | 640x360 | 1280x360 | 30 |

현재 640x360은 native sensor readout이 아니라 FHD 센서 readout 이후 AP1302/CSI 출력
축소 경로다.

### 7.2 Digital crop

해상도 선택과 crop은 독립이다.

| 키 | 범위/기본값 | 의미 |
|---|---|---|
| `crop_enable` | `false` | false이면 crop 레지스터를 쓰지 않음 |
| `dz` | 100~300, 기본 100 | I2C domain 공통 배율, 100=1.0x, 150=1.5x, 200=2.0x |
| `dz_x`, `dz_y` | 0~65535, 기본 32768 | 채널별 중심 좌표 |

`crop_enable=true`로 prepare된 동안 `dz`, `dz_x`, `dz_y`는 런타임 변경할 수 있다.
스트리밍 중 `crop_enable` 자체를 바꾸는 것은 허용하지 않으며, 설정 변경 후
`cam_hard_reset.sh` 또는 `init_cam.sh`로 다시 prepare한다. FHD, HD, 640x360 모두 같은
crop 인터페이스를 사용할 수 있다.

### 7.3 FPS 및 노출 안전

- production은 모든 출력 모드에서 30 FPS로 검증한다.
- 31~120 FPS는 qualification 범위이며 production 합격 조건이 아니다.
- 30 FPS를 넘는 상태에서 수동 노출 쓰기는 I2C 전에 `-EBUSY`로 거부한다.
- AE, gain 및 안전 범위의 기존 노출 동작은 유지한다.
- 수동 WB `0x510a` 쓰기는 사용하지 않는다.

### 7.4 VPU 설정

채널별 `bps`, `gop`, `profile`, `quant`, `qp_min`, `qp_max`는 `[record, rtsp]` 두
원소 배열이어야 한다. `gop=0`은 해당 stream FPS를 사용해 약 1초 간격으로 설정된다.
single-encoder mode에서는 RTSP slot이 record slot 값에 맞춰진다.

## 8. 대상 팀 작업 흐름

```text
환경/커널 확인
  -> 기존 DEB와 JSON 백업
  -> 전달 DEB SHA-256 검증
  -> dpkg 설치
  -> 설치 버전/핵심 파일/모듈 vermagic 확인
  -> edgeconf에 시험 case 적용
  -> cam_hard_reset 또는 init_cam
  -> gstApp/드라이버/VPU/영상/FPS 검증
  -> 결과와 로그 회신
  -> 실패 시 기존 DEB + JSON 복구
```

설정은 기존 edgeconf 전체를 샘플 파일로 덮어쓰지 않는다. 필요한
`VHL_CAM` 필드만 백업본에 반영한다. `update_edgeconf.sh`는 누락 crop/VPU 키를
backfill하되 운영자가 이미 지정한 값을 보존해야 한다.

## 9. 시험 행렬

| Case | 채널 | 출력 | crop | 핵심 확인 |
|---|---|---|---|---|
| A | ch0 only | 640x360@30 | false | single-channel gstApp, crop register 미사용 |
| B | ch0+ch1 | 각 640x360@30 | false | 1280x360 dual-wide, 양 채널 RTSP |
| C | ch0+ch1 | 각 1280x720@30 | false | HD AP1302/CSI 출력 |
| D | ch0+ch1 | 각 1920x1080@30 | false | FHD AP1302/CSI 출력 |
| E | ch0+ch1 | HD 또는 FHD@30 | true, 150 | 해상도 유지 + 1.5x 확대 |
| F | ch0+ch1 | 640x360@30 | true, 200 | 360p 출력 유지 + 2.0x 확대 |
| G | crop-enabled case | 동일 | runtime center 변경 | 재시작 없이 중심 변경 |
| H | 대표 case | 동일 | false | VPU 기본값 및 지정값 반영 |

각 case에서 다음을 수집한다.

- `uname`, 설치 버전, DEB/핵심 파일 SHA-256
- media graph와 V4L2 실제 포맷/크기
- `cam_fps_stack.sh`의 sensor/ISP/CSI/ISI 결과
- `cam_360p_resource.sh`의 gstApp CPU/RSS, system CPU, DDR, thermal
- gstApp 로그의 채널/해상도/VPU 설정
- 양 채널 RTSP decode와 실제 프레임 크기
- RGB565 frame 검사 결과
- `dmesg`의 overflow, I2C, module 또는 exposure guard 오류

ISI capture node의 실제 포맷은 `RGBP`(RGB565)이고 subdevice media-bus 쪽은 UYVY다.
RAW 파일을 UYVY로 잘못 해석해 생기는 녹색 화면을 제품 결함으로 판정하지 않는다.

## 10. 합격 기준

- 전달 DEB가 문서의 SHA-256과 일치한다.
- `dpkg-query`가 `pim-mp 0.6.3+jhw.camera1 arm64`를 표시한다.
- 대상 커널에서 `max9296.ko`가 오류 없이 로드된다.
- single-channel과 single-CSI dual-channel 모두 gstApp prepare 결과가 실제 구성과 맞다.
- A~F에서 협상된 출력 크기가 요청값과 일치하고 crop이 출력 크기를 바꾸지 않는다.
- 30 FPS case에서 sensor/ISP/CSI가 지속적으로 약 30 FPS를 유지하고 중대한 drop 또는
  overflow가 없다.
- RTSP decode가 정상이고 RGB565 기준 green-frame 검사를 통과한다.
- VPU 설정이 gstApp 로그와 encoder property에 반영된다.
- 재부팅 또는 카메라 재초기화 뒤에도 설정한 출력/crop 상태가 재적용된다.
- 기존 edgeconf의 비관련 설정과 채널 enable 상태가 보존된다.

120 FPS strict 기준은 별도 qualification 결과로만 기록한다. 현재 관측된 약
113~115 FPS를 production 120 FPS 통과로 해석하지 않는다.

## 11. 롤백

실패 시 다음 순서로 복구한다.

1. 카메라 서비스와 gstApp 중지
2. 설치 전 확보한 기존 `pim-mp` DEB 재설치
3. 백업한 edgeconf/ord_vcm/defaultconf 복원
4. `depmod -a`, `ldconfig` 수행
5. 재부팅 또는 `cam_hard_reset.sh`
6. 기존 버전, 모듈, JSON checksum과 기본 스트림 확인

기존 DEB를 확보하지 못했거나 커널/환경 preflight가 실패하면 시험 설치를 시작하지
않는다.

## 12. 구현 완료 조건

- 최신 `dist/pim`에서 식별 가능한 새 DEB가 재현 가능하게 생성됨
- 추출 비교에서 모든 핵심 파일이 최신 `dist/pim`과 일치함
- 패키지 메타데이터와 maintainer script 정적 검사가 통과함
- 지정 보드에서 최소 A, B, E, H case가 통과함
- 외부 전달 문서에 설치, 설정 예시, 시험 명령, 결과 양식, 롤백 및 최종 SHA-256이 포함됨
- 최종 전달 디렉터리에 승인된 DEB와 문서 두 파일만 존재함

