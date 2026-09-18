# Camera configuration consumer inventory

## 경로 분류

| 분류 | 권한 경로 | 책임 |
| --- | --- | --- |
| source authority | `/root/shared_v` | 영구 설정 작성·검증 |
| cam-operate builder | `/root/shared_v` -> `/run/pim-camera/config/pim_runtime.json` | startup/`apply-config`에서만 선택·병합·검증·원자 교체 |
| camera runtime consumer | `/run/pim-camera/config/pim_runtime.json` | process 시작 또는 명시적 policy reload 때 읽기 |
| runtime directory writer | `/run/pim-camera/config/pim_runtime.json.file-manager-vhl.cache` | runtime에서 파생한 cache를 자신이 소유·발행 (감사된 예외, C절) |
| network source authority | `/root/shared_v` | WLAN 설정 적용처럼 영구 `NETWORK` source를 직접 소유하는 작업 |
| max9296 kernel driver | JSON 없음 | userspace가 전달한 완전한 control set만 소비 |

camera runtime은 `pim_runtime.json` 하나다. `edgeconf_pim.json`과
`ord_vcm_conf.json`은 한 release 동안 같은 inode를 가리키는 상대 symlink로만 제공한다.

## A. source authority와 builder

다음 항목은 source를 만들거나 검증하므로 `/root/shared_v` 접근을 유지한다.

- `config_guard.sh`
- `factory_init.sh`, `factory_init_pim_gate.sh`
- `update_edgeconf.sh`, `update_ordvcmconf.sh`
- `update_network_pim.py`, `update_eap_id.py`, `update_time_sync.sh`
- `camera_config_bootstrap.sh` (directory, fixed ord source, 필수 도구 prerequisite만 검사)
- `camera_runtime_config.py`를 호출하는 cam-operate startup/`apply-config` transaction

builder는 최신 regular `edgeconf_*.json`을 mtime nanosecond 내림차순, 같은 mtime이면
filesystem-byte path 오름차순으로 하나 선택한다. 최신 파일이 invalid이면 이전 파일로
후퇴하지 않는다. ord document 전체를 유지하고 선택한 edgeconf의 `VHL_CAM`과
`NETWORK.ETH1` ping policy 세 필드를 적용한다.
source 변경만으로 running camera가 바뀌지는 않으며 `apply-config` 또는 cam-operate
restart가 필요하다.

## B. camera runtime consumer

| consumer | 읽기 시점 / 역할 | 재적용 경계 |
| --- | --- | --- |
| `chk_cam_operate.sh` + control/liveness/action library | daemon startup, policy reload, recovery | startup 또는 `apply-config` |
| `start_cam.sh`, `BG_Check_for_pim.sh` | managed gstApp/BG 시작; BG는 camera/policy/ETH1 값을 한 번 고정 | `gstapp_restart` 또는 상위 reset |
| `chk_eth1.sh` | BG가 전달한 고정 ETH1 값; 독립 실행 시 runtime을 한 번 읽음 | BG restart 또는 다음 독립 실행 |
| `cam_channel_resolve.sh`와 camera diagnostic helper | 각 invocation | 다음 invocation |
| `pim_guardian.py` | daemon 시작 | guardian restart 또는 관련 apply |
| `camera_config_expectation.py` | probe `ExecStartPre` | probe restart |
| `camera_capture_probe.py` | 생성된 expectation | probe restart |
| gstApp | process 시작 | gstApp restart 또는 상위 reset |
| ORD | process 시작 | ORD restart 또는 상위 reset |
| VCM | process 시작 | VCM restart 또는 상위 reset |
| compatibility wrapper | runtime을 직접 읽거나 고치지 않고 recovery request만 전달 | executor transaction |

이 목록의 consumer는 source wildcard를 검색하거나 source ord document를 직접 열지 않는다.

## C. runtime directory writer (감사된 예외)

runtime configuration 디렉터리의 writer는 원칙적으로 cam-operate builder 하나다.
`file_manager.sh`는 그 원칙의 **유일한 감사된 예외**다.

| writer | 발행 artifact | 소유 범위 |
| --- | --- | --- |
| `file_manager.sh` | `pim_runtime.json.file-manager-vhl.cache` (+ `.tmp.XXXXXX` 형제) | 자신이 만들고 자신만 읽는 파생 cache |

- 이 cache는 runtime document가 아니라 **runtime에서 파생한 값**이며, builder는 이
  파일을 읽지도 쓰지도 않는다. `camera_runtime_config.py`의 atomic publish는
  `pim_runtime.json`과 고정 alias symlink만 다루므로 두 writer는 대상이 겹치지 않는다.
- cam-operate.service가 `RuntimeDirectory=pim-camera`를 선언하므로 unit 정지 시
  디렉터리가 사라진다. cache 소멸은 정상 동작이다 — 다음 invocation이 cache 없이
  동작하고 필요하면 다시 발행한다.
- **이 cache에 쓸 수 있다는 것은 같은 디렉터리의 runtime JSON에도 쓸 수 있다는 뜻이다.**
  따라서 디렉터리 쓰기 권한(0750 root)이 `file_manager.sh` 삭제 prefix의 신뢰 경계이며,
  cache hit 경로는 runtime document를 다시 검증하지 않는다. 이는 수용된 설계다.
- `runtime_consumer_path_test.py`가 이 예외를 양방향으로 강제한다. runtime JSON의
  형제 경로를 파생하는 consumer가 새로 생기면 실패하고, 예외 목록만 남고 실제
  writer가 사라져도 실패한다.
invalid runtime은 `CONFIG_INVALID`로 실패하며 source repair 또는 hardware escalation을
시도하지 않는다.

## C. network source authority

`chk_wifi.sh`는 WLAN 연결 상태와 영구 network source를 함께 다루므로 `/root/shared_v`를
계속 읽는다. 반면 주기 실행되는 `chk_eth1.sh`는 source reader가 아니다. cam-operate가
edgeconf의 `NETWORK`를 runtime에 고정하고, BG가 시작 시 `NETWORK.ETH1`을 한 번 추출해
매 반복마다 값으로 전달한다. 따라서 source 파일이 바뀌어도 running BG에는 반영되지 않으며
`apply-config` 또는 cam-operate restart가 필요하다.

다음 항목도 camera owner로 단정하지 않는 별도 system/config domain이다.

- `automnt_sd_for_emmc_boot.sh`
- `cam_rotate_setting.sh`
- `cpu_limit.sh`
- `file_manager.sh`
- `ncsftp.sh`
- `sd_mount_stop.sh`
- `set_link_speed.py`

## D. 적용 동작 소유권

| 변경 | 읽어야 하는 consumer | owner가 수행할 동작 |
| --- | --- | --- |
| `VHL_CAM` hardware | gstApp, ORD, VCM | hard reset 후 세 consumer 재기동 |
| `VHL_CAM` non-hardware | gstApp, ORD, VCM | 세 consumer 재기동 |
| `NETWORK` | BG/`chk_eth1.sh` | `gstapp_restart`로 managed gstApp/BG 재기동 |
| `ORD` | ORD | ORD 재기동 |
| `VCM` | VCM | VCM 재기동 |
| cam-operate `ETC` | daemon | in-memory policy reload |
| script-only key | 해당 script | 다음 실행부터 읽기 |

## 감사 기준과 외부 경계

1. source authority와 startup/`apply-config` builder 외에는
   `/root/shared_v` camera JSON open이 없어야 한다.
2. 세 native app과 camera script는 고정 runtime path 또는 두 compatibility alias만
   사용해야 한다.
3. 두 alias는 실제 runtime과 같은 파일을 가리켜야 한다.
4. 자동 recovery와 wrapper는 source를 재검색하지 않아야 한다.
5. source 재적용 뒤 관련 process가 restart되어 새 값을 읽어야 한다.

저장소 밖의 `pim-check` source/deployment가 새 recovery request와 terminal sentinel을
소비하는지는 별도 integration 경계다. 외부 구현과 배포본을 확인하기 전에는 완료로
분류하지 않는다.
