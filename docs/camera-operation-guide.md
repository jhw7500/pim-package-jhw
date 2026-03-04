# PIM 카메라 동작 시나리오 가이드

> **버전**: v0.5.8 | **최종 갱신**: 2026-03-04
> **대상**: pim-package (`/opt/pim/bin/`) 카메라 서브시스템

---

## 목차

1. [아키텍처 개요](#1-아키텍처-개요)
2. [스크립트 역할 정리](#2-스크립트-역할-정리)
3. [정상 동작 시나리오](#3-정상-동작-시나리오)
4. [비정상 동작 시나리오](#4-비정상-동작-시나리오)
5. [SD 카드 시나리오](#5-sd-카드-시나리오)
6. [타이밍 요약표](#6-타이밍-요약표)
7. [/tmp 파일 레퍼런스](#7-tmp-파일-레퍼런스)
8. [상태 머신](#8-상태-머신)

---

## 1. 아키텍처 개요

### 1.1 스크립트 호출 흐름

```
[systemd: cam-operate]
        |
        v
  chk_cam_operate.sh  <--- 메인 감시 루프 (2초 주기, 디스크 정리 30초 주기)
        |
        +---> init_cam.sh ---> kill_test.sh ---> rmmod/modprobe ---> start_cam.sh
        |                                                                |
        |                                                                +---> gstApp / PIMCAM
        |                                                                +---> BG_Check_for_pim.sh
        |                                                                +---> restart_app.sh
        |
        +---> ProcessCompletedSessions()   .part 파일 -> final 경로 이동
        +---> CleanupStalePartFiles()      stale .part 파일 정리
        +---> enforce_sd_retention()       SD 용량 관리
        +---> enforce_ram_cap()            RAM 모드 용량 관리
        +---> maybe_init_cam_on_disconnect() 카메라 분리 시 주기적 복구
```

### 1.2 설정 파일

| 파일 | 경로 | 용도 |
|------|------|------|
| edgeconf_*.json | `/root/shared_v/` | 카메라 앱, 채널, 경로, 녹화 설정 |
| ord_vcm_conf.json | `/root/shared_v/` | 타이밍 파라미터 (grace, cooldown 등) |

### 1.3 커널 모듈

| 모듈 | 역할 |
|------|------|
| `max9296` | GMSL2 디시리얼라이저 + AP1302 ISP 드라이버 |
| `imx8-media-dev` | iMX8MP 미디어 디바이스 드라이버 |

---

## 2. 스크립트 역할 정리

### 2.1 핵심 스크립트

| 스크립트 | 역할 | 호출 주체 |
|----------|------|-----------|
| `chk_cam_operate.sh` | 메인 감시 루프. 파일 검사, 복구 판단, 디스크 관리 | systemd (cam-operate) |
| `start_cam.sh` | 카메라 앱 기동 + BG_Check/restart_app 시작 | init_cam, cam_enable, chk_cam_operate |
| `init_cam.sh` | 커널 모듈 rmmod/modprobe + 고아 파일 정리 + start_cam | chk_cam_operate |
| `kill_test.sh` | 카메라 관련 프로세스 순차 종료 | init_cam, chk_cam_operate |
| `restart_app.sh` | vcm/ord 프로세스 감시 + 카메라 앱 재시작 (3초 루프) | start_cam |
| `BG_Check_for_pim.sh` | 하드웨어 상태 감시 (카메라, WiFi, SD, 온도, 전압) | start_cam |

### 2.2 보조 스크립트

| 스크립트 | 역할 |
|----------|------|
| `chk_cam_connect.sh` | I2C로 MAX9296 레지스터 읽어 카메라 연결 확인 |
| `chk_sd_mount.sh` | SD 카드 마운트 + 쓰기 테스트 |
| `chk_wifi.sh` | WiFi 연결 상태 확인 |
| `chk_cpu_temp.sh` | CPU 온도 확인 |
| `chk_voltage.sh` | 전원 전압 확인 |
| `cam_enable.sh` | 수동 카메라 활성화 (모듈 재로드 + start_cam) |
| `cam_disable.sh` | 수동 카메라 비활성화 (프로세스 종료 + 모듈 언로드) |
| `cam_operate_stop.sh` | 빠른 카메라 중지 (killcam + 플래그 정리) |
| `button_cam_reset.sh` | GPIO 131 버튼으로 카메라 on/off 토글 |
| `cstop.sh` | cam-operate 서비스 + restart_app 강제 종료 |
| `led_ctrl.sh` | BG_Check 결과에 따른 LED 제어 |

### 2.3 공유 라이브러리

| 파일 | 용도 |
|------|------|
| `cam_state.sh` | 카메라 상태 머신 (healthy/degraded/recovering/failed), streak 카운터, 복구 요청 관리 |

---

## 3. 정상 동작 시나리오

### 3.1 부팅 -> 스트리밍 시작

```
[부팅]
  |
  +-- SD 마운트 대기 (최대 5초)
  |
  +-- edgeconf_*.json 설정 로드
  |     +-- 앱 결정: capture.enable=true -> gstApp, 아니면 PIMCAM
  |     +-- 채널 활성화: ch0~ch3 (I2C 버스별)
  |     +-- 경로: tmp_path, sd_tmp_path, final_path
  |
  +-- start_cam.sh 호출
  |     +-- gstApp/PIMCAM 시작 (-d delay -m iomode)
  |     +-- BG_Check_for_pim.sh 시작 (delay초 대기 후 감시)
  |     +-- restart_app.sh 시작 (vcm/ord 감시 + 앱 재시작)
  |
  +-- Startup Grace Window (파일 검사 유예)
  |     +-- 싱글 CSI: 11초 + 10초 = 21초
  |     +-- 듀얼 CSI: 22초 + 10초 = 32초
  |     +-- SD 불량 시: +20초 추가
  |
  +-- 메인 루프 진입
        +-- 2초 주기: 파일 검사, 복구 판단
        +-- 30초 주기: 디스크 정리, stale .part 정리
```

**부팅~스트림 시작 소요 시간:**

| 구성 | SD 정상 | SD 불량 |
|------|---------|---------|
| 싱글 CSI (2채널 이하) | ~32초 | ~52초 |
| 듀얼 CSI (3~4채널) | ~54초 | ~74초 |

### 3.2 녹화 파일 커밋 흐름 (정상)

```
gstApp 녹화 중
  |
  +-- tmp_path에 .part 파일 생성 (예: VD3001_20260304_1430-ch0.mp4.part)
  |
  +-- 세션 완료 시:
  |     +-- /tmp/session_20260304_1430.video_done 생성
  |     +-- /tmp/session_20260304_1430.srt_done 생성
  |     +-- /tmp/session_20260304_1430.all_done 생성
  |
  +-- chk_cam_operate.sh의 ProcessCompletedSessions()
        |
        +-- Stage 1: tmp_path -> sd_tmp_path (cp + sync + rm 원본)
        +-- Stage 2: sd_tmp_path -> final_path (.part 확장자 제거, mv)
        +-- all_done 마커 삭제
        |
        +-- 보호: 현재 분(minute) 세션은 처리 보류
```

---

## 4. 비정상 동작 시나리오

> **카메라 연결 체크의 전제조건**
>
> 카메라 연결 상태(`chk_cam_connect.sh`)는 I2C를 통해 MAX9296 레지스터를 읽어 확인한다.
> 이 체크가 유효하려면 다음 조건이 **모두** 충족되어야 한다:
>
> 1. 커널 모듈(`max9296`, `imx8-media-dev`)이 로드되어 있어야 한다
> 2. 카메라 앱(`gstApp`/`PIMCAM`)이 실행 중이어야 한다
>
> 카메라 앱이 실행되면 채널/설정에 따라 드라이버가 f/w를 다운로드하고 레지스터를 세팅하여
> 비로소 I2C 통신이 의미 있는 값을 반환한다. 따라서 **드라이버 미로드 상태나
> 카메라 앱 미실행 상태에서는 카메라 연결 여부를 판단할 수 없다.**

### 4.1 녹화 파일 검사 실패 (일부 채널 파일 미생성)

> 활성화된 채널의 녹화 파일이 `file_check_delay`초 후에도 존재하지 않을 때

```
파일 검사 실패 감지
  |
  +-- [retry_total 1~3] kill_test.sh (프로세스 정리 -> restart_app이 재시작)
  |     소요: ~5초 (정상 종료) / ~15초 (SIGKILL) / ~30초 (최악)
  |
  +-- [retry_total 4~5] init_cam.sh (모듈 재로드 + 앱 재시작)
  |     소요: ~12~15초 + app_delay(11~22초)
  |
  +-- [retry_total > 5] reboot (file_chk_reboot=true일 때만)
        소요: ~60~90초 (시스템 리부트)
```

**전체 소요 시간 (파일 검사 실패 -> reboot까지):**

| 단계 | 동작 | 누적 시간 (싱글CSI) |
|------|------|---------------------|
| 1회 실패 | kill_test | ~5초 + grace 21초 |
| 2회 실패 | kill_test | ~5초 + grace 21초 |
| 3회 실패 | kill_test | ~5초 + grace 21초 |
| 4회 실패 | init_cam | ~15초 + grace 21초 + cooldown 40초 |
| 5회 실패 | init_cam | ~15초 + grace 21초 + cooldown 40초 |
| 6회 실패 | **reboot** | - |
| **합계** | | **약 3~5분** (싱글CSI) / **약 6~8분** (듀얼CSI) |

### 4.2 시작 실패 (gstApp 기동 후 파일 0개)

> `rst_time`(25/35초) 경과 후에도 녹화 파일이 하나도 없을 때

```
파일 0개 감지 (timer >= rst_time)
  |
  +-- [retry_total <= 1] kill_test.sh
  +-- [retry_total 2~3] init_cam.sh
  +-- [retry_total > 3] reboot (file_chk_reboot=true일 때만)
```

| 단계 | 조건 | 소요 시간 |
|------|------|-----------|
| 1차 | retry_total <= 1 | kill_test ~5초 + rst_time 대기 |
| 2차 | retry_total 2~3 | init_cam ~15초 + app_delay + cooldown |
| 3차 | retry_total > 3 | **reboot** |

### 4.3 gstApp 에러 (gst_err)

> gstApp 비정상 종료 시 `/tmp/gst_err` 파일 생성

```
gstApp 비정상 종료
  |  /tmp/gst_err 생성
  |
  +-- restart_app.sh 감지 (3초 주기)
  |     +-- start_cam.sh 호출
  |           +-- gst_err 발견 -> /tmp/recover_req_init_cam 생성
  |           +-- cam_request_recovery("gst_err")
  |
  +-- chk_cam_operate.sh 감지 (최대 5초 내)
  |     +-- init_cooldown(40초) 확인
  |           +-- 쿨다운 중: 대기
  |           +-- 쿨다운 아님: init_cam.sh 실행
  |
  +-- init_cam.sh 실행 (~12~15초)
  +-- start_cam.sh 실행 (app_delay 11~22초)

총 소요: 약 30~45초 (쿨다운 미적용 시)
         약 70~85초 (쿨다운 적용 시)
```

### 4.4 카메라 물리적 분리 -> 재연결

> 카메라 케이블 분리 시. 드라이버/앱이 정상 동작 중이므로 I2C 체크가 유효하며,
> 이 상태에서는 reboot하지 않고 주기적 복구를 시도한다.

```
카메라 케이블 분리
  |
  +-- BG_Check_for_pim.sh (1초 주기)
  |     +-- chk_cam_connect.sh -> I2C 통신 실패
  |         (드라이버 로드 + 앱 실행 상태이므로 I2C 체크 유효)
  |     +-- /tmp/err_cam{N}.log 생성
  |     +-- streak 카운트 증가
  |     +-- streak >= 2: cam_state -> "degraded"
  |                      /tmp/recover_req_init_cam 생성
  |
  +-- chk_cam_operate.sh: maybe_init_cam_on_disconnect()
  |     +-- 60초 간격으로 init_cam.sh 실행
  |     +-- grace 20초 (첫 감지 후 바로 init 안 함)
  |     +-- 모듈 rmmod -> modprobe -> start_cam
  |
  +-- 카메라 재연결 시
        +-- 다음 init_cam 주기에서 자동 복구
        +-- cam_state -> "healthy", streak -> 0
        +-- 정상 스트리밍 재개

감지 시간: ~2초 (BG_Check 1초 + streak 판단)
복구 주기: 60초 간격 재시도
재연결 후 복구: 최대 60초 대기 + init_cam ~15초 + app_delay
```

### 4.5 드라이버 로드 실패

> `max9296` 또는 `imx8-media-dev` 모듈이 로드되지 않은 상태.
>
> **핵심**: `modprobe max9296`은 probe 과정에서 I2C로 MAX9296 칩과 통신한다.
> 카메라가 물리적으로 연결되어 있지 않으면 I2C 응답이 없어 **modprobe 자체가 실패**한다.
> 즉, 드라이버 로드 실패 = 카메라 미연결의 결과일 수 있다.

```
modules_loaded() 실패
  |
  +-- 원인 판별 불가:
  |     +-- 카메라 미연결 → I2C 실패 → modprobe 실패 (HW 문제)
  |     +-- 커널/모듈 이상 → modprobe 실패 (SW 문제)
  |
  +-- cam_disconnect_flag 확인:
        |
        +-- flag != 0 (이전에 BG_Check가 분리 감지한 적 있음):
        |     +-- retry/reboot 안 함
        |     +-- 5초 대기 후 다음 루프
        |     +-- maybe_init_cam_on_disconnect()가 60초 주기로 재시도
        |
        +-- flag == 0 (콜드 부팅 또는 이전 정상 상태):
              +-- [retry_total <= 5] init_cam.sh 반복
              |     소요: ~15초 + 5초 루프 대기
              +-- [retry_total > 5] reboot (file_chk_reboot=true일 때만)
```

**콜드 부팅 시 카메라 미연결 한계:**

```
카메라 없이 부팅 → cam_disconnect_flag = 0 (BG_Check 실행 이력 없음)
  → modprobe 실패 → init_cam 5회 재시도 → 전부 실패 → reboot
  → 다시 부팅 → 또 modprobe 실패 → 5회 재시도 → reboot → ...
  (무한 reboot 루프 가능)
```

> 이 한계는 현재 구조상 불가피하다. 드라이버 로드 없이는 카메라 연결 상태를
> 확인할 방법이 없고, SW 오류로 인한 로드 실패와 구분할 수 없기 때문이다.
> `file_chk_reboot=false`로 설정하면 reboot 루프를 방지할 수 있다.

| 단계 | 조건 | 소요 시간 |
|------|------|-----------|
| 1~5회 | init_cam.sh (disconnect flag 미설정 시) | 각 ~15초 + 5초 대기 |
| 6회~ | reboot 또는 카운터 리셋 | file_chk_reboot 설정에 따름 |
| **합계 (최악)** | 5회 init 실패 -> reboot | **약 2~3분** |

### 4.6 kill_test.sh 프로세스 종료 실패

> 프로세스가 SIGTERM/SIGKILL에도 종료되지 않을 때.
> **앱 프로세스가 죽지 않는 상황에서는 카메라 연결 여부를 판단할 수 없으므로,
> 카메라 연결 상태와 무관하게 일정 횟수 시도 후 reboot한다.**

```
프로세스 kill 시작 (BG_Check, vcm, gstApp/PIMCAM 순차)
  |
  +-- 0~4초: SIGTERM 후 대기
  +-- 5초~: "limitcnt over" 경고, defunct(좀비) 확인
  +-- 15초~: SIGKILL 전환
  +-- 30초~: 프로세스 kill 불가 -> reboot (무조건)
```

| 상황 | 소요 시간 |
|------|-----------|
| 정상 종료 | 2~5초 |
| 좀비 프로세스 | 15~20초 |
| kill 불가 | **30초 -> reboot (무조건)** |

---

## 5. SD 카드 시나리오

### 5.1 SD 카드 미장착 / 마운트 실패

> 부팅 시 SD 카드가 없거나 마운트에 실패한 경우.
> `automnt_sd_for_emmc_boot.sh`와 `chk_cam_operate.sh`가 **2단계**로 대응한다.

```
부팅
  |
  +-- [1단계] automnt_sd_for_emmc_boot.sh (3초 주기 감시)
  |     +-- /sys/bus/mmc/devices/.../mmcblk1p1 미존재 확인
  |     +-- fallback_to_shm() 호출:
  |           +-- edgeconf JSON의 tmp_path를 /dev/shm으로 영구 변경
  |           +-- prev_tmp_path_before_fallback에 원래 경로 보존
  |           +-- tmp_path_fallback_active = true 설정
  |           +-- systemctl restart cam-operate (cam-operate 재시작)
  |
  +-- [2단계] chk_cam_operate.sh (재시작됨)
  |     +-- JSON에서 tmp_path=/dev/shm 읽음 (automnt가 변경한 값)
  |     +-- SD 마운트 대기 5초 -> 실패
  |     +-- /dev/shm/sd_mount_flag 없거나 값 != 1, 2
  |     +-- apply_storage_mode_overrides():
  |           +-- final_path -> /dev/shm/recordings (런타임 override)
  |           +-- sd_tmp_path -> tmp_path (동일 경로, Stage1 스킵)
  |
  +-- RAM-only 모드 운영
        +-- RAM 용량 캡: 1.6GiB
        +-- startup grace +20초 추가
        +-- 30초 주기 enforce_ram_cap_if_needed()
              +-- /dev/shm/recordings 크기 > 1.6GiB 시
              +-- 오래된 세션부터 삭제 (최근 2세션 보호)
```

**역할 분담:**

| 스크립트 | 변경 대상 | 방식 | 지속성 |
|----------|-----------|------|--------|
| `automnt_sd_for_emmc_boot.sh` | `tmp_path` | JSON 영구 수정 | 영구 (SD 복귀 시 restore_to_sd로 복원) |
| `chk_cam_operate.sh` | `final_path`, `sd_tmp_path` | 메모리 내 런타임 override | 프로세스 수명 동안만 |

> **왜 이중 구조인가?**
> - `automnt`는 SD 물리 상태만 감시하며 `tmp_path`만 변경한다 (`final_path`는 변경하지 않음)
> - `chk_cam_operate`는 `final_path`를 런타임에 override하여 `.part` 커밋 경로를 보호한다
> - SD 용량 98% 초과(`sd_write_disabled`) 시에는 `automnt`가 관여하지 않으므로,
>   `chk_cam_operate`의 런타임 override가 반드시 필요하다

### 5.2 SD 카드 용량 부족

> 운영 중 SD 카드 용량이 임계값을 초과하는 경우.
> 이 시나리오는 `automnt`가 관여하지 않으며, `chk_cam_operate.sh`가 단독 처리한다.

```
30초 주기 CheckDiskSpace()
  |
  +-- 사용률 < 95%:
  |     정상. 아무 동작 안 함.
  |
  +-- 사용률 95~97% (WARN):
  |     +-- enforce_sd_retention_if_needed()
  |     +-- 오래된 세션 삭제 (최근 2세션 보호)
  |     +-- 5개 세션 삭제마다 df 재확인
  |
  +-- 사용률 >= 98% (CRIT):
  |     +-- 오래된 세션 삭제 시도
  |     +-- /tmp/sd_write_disabled 생성
  |     +-- apply_storage_mode_overrides() -> RAM-only 모드 전환
  |     |     final_path -> /dev/shm/recordings (런타임 override)
  |     +-- 이후 녹화는 RAM에만 저장
  |     |
  |     +-- (automnt는 이 상황을 감지하지 않음.
  |     |    SD는 마운트 정상이므로 automnt 개입 없음)
  |
  +-- 사용률 < 95%로 회복 시:
        +-- /tmp/sd_write_disabled 삭제
        +-- apply_storage_mode_overrides() -> SD 쓰기 모드 복귀
        +-- final_path -> 원래 SD 경로 복원
```

### 5.3 SD 카드 런타임 장애 (운영 중 제거/불량)

> 정상 운영 중 SD 카드가 물리적으로 빠지거나 불량이 발생한 경우.
> `automnt`와 `chk_cam_operate`가 **병렬로** 각각 감지하여 대응한다.

```
SD 카드 갑자기 제거/장애
  |
  +-- [경로 A] automnt_sd_for_emmc_boot.sh (3초 주기)
  |     +-- /sys/bus/mmc/devices/.../mmcblk1p1 사라짐 감지
  |     +-- mnt_cnt > 3 후:
  |     |     +-- sd_mount_flag -> 0
  |     |     +-- fuser -TERM으로 SD 점유 프로세스 해제
  |     |     +-- umount -l (lazy unmount)
  |     |     +-- fallback_to_shm(): tmp_path -> /dev/shm (JSON 수정)
  |     |     +-- systemctl restart cam-operate
  |     +-- mnt_state -> 2 (재삽입 감시 모드)
  |
  +-- [경로 B] BG_Check_for_pim.sh (1초 주기, 경로 A보다 먼저 감지)
  |     +-- chk_sd_mount.sh
  |           +-- df로 /dev/mmcblk1p1 확인 -> 실패
  |           +-- 쓰기 테스트 (touch/rm) -> 실패
  |           +-- /tmp/err_sdcard.log 생성
  |     +-- bg_chk_flag.bin의 bit5 = 1
  |
  +-- [경로 B 계속] chk_cam_operate.sh (다음 apply_storage_mode_overrides)
  |     +-- is_sd_ok() -> false
  |     +-- RAM-only 모드 자동 전환 (런타임 override)
  |           +-- final_path -> /dev/shm/recordings
  |           +-- 진행 중이던 .part Stage1(cp) -> 실패 시 마커 유지, 재시도
  |           +-- 이후 새 세션은 RAM에만 저장
  |
  +-- 기존 SD 녹화 파일은 건드리지 않음
  |
  +-- SD 재삽입 시:
        +-- automnt: mnt_state 2 -> 0 전환, 마운트 재시도
        +-- 마운트 성공 시:
              +-- sd_mount_flag -> 1
              +-- restore_to_sd(): tmp_path 원래 SD 경로로 복원 (JSON 수정)
              +-- systemctl restart cam-operate
        +-- chk_cam_operate (재시작):
              +-- is_sd_ok() -> true
              +-- apply_storage_mode_overrides() -> SD 경로 복원
              +-- 자동으로 SD 쓰기 모드 복귀

감지 시간:
  - BG_Check (경로 B): 1~2초 (먼저 감지, 런타임 override)
  - automnt (경로 A): 3~12초 (물리 감지 후 mnt_cnt 대기, JSON 수정 + 서비스 재시작)
```

### 5.4 /dev/shm 메모리 부족 (RAM-only 비상 정리)

> RAM-only 모드에서 /dev/shm 사용률이 높아진 경우

```
init_cam.sh 호출 시 (모듈 재로드 전)
  |
  +-- cleanup_shm_overflow()
  |     +-- /dev/shm 사용률 >= 70% 시 실행
  |     +-- mtime 오래된 파일부터 순차 삭제
  |     +-- 보호 대상: sd_mount_flag, sd_write_disabled, 디렉토리
  |     +-- 70% 미만까지 반복
  |
  +-- cleanup_recording_orphans()
        +-- tmp_path의 .mp4/.ts/.srt/.part 모두 삭제
        +-- gstApp이 죽은 상태이므로 전부 고아 파일
```

---

## 6. 타이밍 요약표

### 6.1 복구 단계별 소요 시간

| 동작 | 내부 절차 | 소요 시간 |
|------|-----------|-----------|
| `kill_test.sh` | SIGTERM -> 대기 -> SIGKILL -> 파일 정리 | 2~30초 |
| `init_cam.sh` | kill_test + rmmod(2초) + modprobe x2(4초) + 정리 | 12~15초 |
| `start_cam.sh` | 앱 기동 + BG_Check + restart_app | 즉시 (앱 딜레이는 별도) |
| app_delay | 싱글 CSI / 듀얼 CSI | 11초 / 22초 |
| startup grace | app_delay + 10초 (+ SD불량 시 +20초) | 21~52초 |
| init cooldown | init_cam 후 중복 실행 방지 | 40초 |
| 시스템 reboot | 전체 재부팅 | 60~90초 |

### 6.2 이벤트별 감지~복구 시간

| 이벤트 | 감지 시간 | 1차 복구 | 2차 복구 | 최종 reboot | 카메라 연결 체크 |
|--------|-----------|----------|----------|-------------|-----------------|
| 파일 검사 실패 (일부) | file_check_delay 후 | kill_test x3 | init_cam x2 | retry > 5 | 유효 (앱 실행 중) |
| 시작 실패 (파일 0개) | rst_time(25/35초) 후 | kill_test x1 | init_cam x2 | retry > 3 | 유효 (앱 실행 중) |
| gst_err | restart_app 3초 주기 | init_cam | - | recovery 5회 초과 | 유효 |
| 카메라 분리 | BG_Check 2초 (streak>=2) | init_cam 60초 간격 | 계속 재시도 | **안 함** | 유효 (드라이버+앱 정상) |
| 드라이버 로드 실패 | 메인 루프 5초 주기 | init_cam x5 | - | retry > 5 | **불가** (이전 flag 있으면 skip) |
| kill 불가 | kill_test 내 1초 주기 | SIGKILL (15초) | - | **30초 후 무조건** | **불가** (무조건 reboot) |
| SD 용량 95% | 30초 주기 | 오래된 세션 삭제 | - | - | - |
| SD 용량 98% | 30초 주기 | 삭제 + RAM-only 전환 | - | - | - |
| SD 장애/제거 | BG_Check 1초 / automnt 3초 | RAM-only 전환 + JSON 수정 | - | - | - |
| /dev/shm 70% | init_cam 호출 시 | 오래된 파일 삭제 | - | - | - |

### 6.3 최악 시나리오 소요 시간

| 시나리오 | 싱글 CSI | 듀얼 CSI |
|----------|----------|----------|
| 파일 검사 실패 -> reboot | 3~5분 | 6~8분 |
| 시작 실패 -> reboot | 2~3분 | 4~5분 |
| 드라이버 로드 실패 -> reboot | **2~3분** (콜드부팅 시) | **2~3분** (콜드부팅 시) |
| kill 불가 -> reboot | **30초** (무조건) | **30초** (무조건) |
| gst_err -> 스트림 재개 | 30~85초 | 45~100초 |
| 카메라 분리 -> 재연결 복구 | 최대 60초 + 27~37초 | 최대 60초 + 37~47초 |

---

## 7. /tmp 파일 레퍼런스

### 7.1 프로세스 상태 플래그

| 파일 | 용도 | 생성 주체 | 삭제 주체 |
|------|------|-----------|-----------|
| `/tmp/init_cam_flag` | init_cam 실행 중 잠금 | init_cam.sh | init_cam.sh (완료 시) |
| `/tmp/restart_flag` | kill_test 실행 중 잠금 | kill_test.sh | kill_test.sh (완료 시) |
| `/tmp/kill_flag` | 프로세스 kill 완료 표시 | kill_test, start_cam | chk_cam_operate |
| `/tmp/gst_err` | gstApp 비정상 종료 표시 | gstApp | init_cam, start_cam |

### 7.2 타이밍 / 쿨다운

| 파일 | 용도 | 값 형식 |
|------|------|---------|
| `/tmp/pim_cam_start_ts` | 카메라 앱 시작 시각 | epoch (초) |
| `/tmp/pim_cam_start_delay` | 시작 딜레이 값 | 정수 (초) |
| `/tmp/pim_cam_stream_start_ts` | 스트림 실제 시작 시각 | epoch (초) |
| `/tmp/last_init_cam_ts` | 마지막 init_cam 실행 시각 | epoch (초) |
| `/tmp/start_video_time` | gstApp 녹화 시작 시각 | "YYYYMMDD HH:MM:SS" |
| `/tmp/start_video_time_chk` | kill_test 파일 정리용 시작 시각 | "YYYYMMDD HH:MM:SS" |

### 7.3 카메라 상태 / 복구

| 파일 | 용도 | 값 형식 |
|------|------|---------|
| `/tmp/bg_chk_flag.bin` | BG_Check 결과 비트맵 | 정수 (비트맵, 아래 참조) |
| `/tmp/err_cam{0..3}.log` | 채널별 연결 에러 로그 | 타임스탬프 + 메시지 |
| `/tmp/err_wifi.log` | WiFi 에러 | 타임스탬프 |
| `/tmp/err_sdcard.log` | SD 카드 에러 | 타임스탬프 |
| `/tmp/err_cpu_temp.log` | CPU 온도 초과 | 타임스탬프 |
| `/tmp/err_voltage.log` | 전압 이상 | 타임스탬프 |
| `/tmp/bg_cam_err_streak` | 카메라 에러 연속 횟수 | 정수 |
| `/tmp/recover_req_init_cam` | init_cam 복구 요청 | "epoch 사유" |

**bg_chk_flag.bin 비트맵:**

| 비트 | 값 | 의미 |
|------|----|------|
| bit 0 | 1 | CAM0 에러 |
| bit 1 | 2 | CAM1 에러 |
| bit 2 | 4 | CAM2 에러 |
| bit 3 | 8 | CAM3 에러 |
| bit 4 | 16 | WiFi 에러 |
| bit 5 | 32 | SD 카드 에러 |
| bit 6 | 64 | CPU 온도 초과 |
| bit 7 | 128 | 전압 이상 |

### 7.4 상태 머신 파일 (cam_state.sh)

| 파일 | 용도 | 값 형식 |
|------|------|---------|
| `/tmp/cam_state.json` | 카메라 상태 머신 전체 | JSON |
| `/tmp/cam_state.state` | state 필드 shadow (빠른 읽기) | 문자열 |
| `/tmp/cam_state.streak` | streak 필드 shadow (빠른 읽기) | 정수 |
| `/tmp/cam_recovery.json` | 복구 요청 상세 | JSON (시도횟수, 최대, 사유) |
| `/tmp/cam_op_lock` | 카메라 작업 잠금 | 작업명 문자열 |

### 7.5 녹화 파일 관리

| 파일 | 용도 |
|------|------|
| `/tmp/session_*.video_done` | 해당 세션 비디오 쓰기 완료 마커 |
| `/tmp/session_*.srt_done` | 해당 세션 자막 쓰기 완료 마커 |
| `/tmp/session_*.all_done` | 모든 파일 완료 -> .part 커밋 트리거 |
| `/tmp/chk_cam_operate.part_state` | stale .part 감시 상태 (경로, 크기, 안정 카운트) |
| `/tmp/sd_write_disabled` | SD 쓰기 금지 플래그 (98% 이상 시 생성) |
| `/tmp/chk_cam_operate.disconnect_state` | 카메라 분리 상태 추적 (첫 감지, 마지막 init) |

### 7.6 /dev/shm 파일

| 파일 | 용도 | 비고 |
|------|------|------|
| `/dev/shm/sd_mount_flag` | SD 마운트 상태 | 1,2=정상 / 그 외=불량. 리부트 시 초기화 |
| `/dev/shm/recordings/` | RAM-only 모드 녹화 저장소 | 1.6GiB 캡 적용 |

---

## 8. 상태 머신

### 8.1 cam_state 상태 전이

```
                          에러 streak >= 2
  +----------+  -------------------------------->  +-----------+
  |          |                                     |           |
  | healthy  |                                     | degraded  |
  |          |  <--------------------------------  |           |
  +----------+    streak 리셋 + init 성공          +-----------+
       ^                                                |
       |                                                |
       |              init_cam.sh 호출                  |
       |          +-------------+                       |
       +--------- | recovering  | <---------------------+
       init 성공  |             |
                  +-------------+
                        |
                        | recovery 5회 실패
                        v
                  +-------------+
                  |   reboot    |
                  +-------------+
```

### 8.2 핵심 보호 규칙

| 규칙 | 설명 |
|------|------|
| 카메라 연결 체크 전제조건 | 드라이버 로드 + 앱 실행 시에만 I2C 체크 유효 |
| 카메라 분리 시 reboot 금지 | 파일 검사 실패, gst_err 등에서 `cam_disconnect_flag` 체크 |
| 드라이버 미로드 시 복구 한계 | modprobe 실패 = 카메라 미연결일 수 있으나 SW 오류와 구분 불가. 이전 disconnect flag 없으면 reboot 루프 가능 (`file_chk_reboot=false`로 방지) |
| kill 불가 시 무조건 reboot | 앱이 죽지 않으면 카메라 상태 판단 불가 → 30초 후 무조건 reboot |
| file_chk_reboot 설정 | `false`이면 retry 카운터만 리셋, reboot 안 함 |
| init cooldown 40초 | 중복 init_cam 호출 차단 |
| 최근 2세션 보호 | 디스크 정리 시 최신 2개 세션은 삭제 안 함 |
| startup grace | 부팅/재시작 직후 파일 검사 실패 무시 |
| 쿨다운 중 에러 무시 | BG_Check에서 grace/cooldown 중 카메라 에러 로그 삭제 |
| SD fallback 이중 구조 | automnt가 `tmp_path` JSON 수정, chk_cam_operate가 `final_path` 런타임 override |
