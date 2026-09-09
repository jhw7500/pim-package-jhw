# Camera configuration consumer inventory

## 경로 분류

| 분류 | 권한 경로 | 책임 |
| --- | --- | --- |
| source authority | `/root/shared_v` | 영구 설정 작성·검증 |
| cam-operate builder | `/root/shared_v` -> `/run/pim-camera/config/pim_runtime.json` | startup/`apply-config`에서만 선택·병합·검증·원자 교체 |
| camera runtime consumer | `/run/pim-camera/config/pim_runtime.json` | process 시작 또는 명시적 policy reload 때 읽기 |
| network-side input consumer | `/root/shared_v` | camera runtime에 포함되지 않는 `NETWORK` 등 읽기 |
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
후퇴하지 않는다. ord document 전체를 유지하고 선택한 edgeconf의 `VHL_CAM`을 적용한다.
source 변경만으로 running camera가 바뀌지는 않으며 `apply-config` 또는 cam-operate
restart가 필요하다.

## B. camera runtime consumer

| consumer | 읽기 시점 / 역할 | 재적용 경계 |
| --- | --- | --- |
| `chk_cam_operate.sh` + control/liveness/action library | daemon startup, policy reload, recovery | startup 또는 `apply-config` |
| `start_cam.sh`, `BG_Check_for_pim.sh` | managed gstApp/BG 시작 | `gstapp_restart` 또는 상위 reset |
| `cam_channel_resolve.sh`와 camera diagnostic helper | 각 invocation | 다음 invocation |
| `pim_guardian.py` | daemon 시작 | guardian restart 또는 관련 apply |
| `camera_config_expectation.py` | probe `ExecStartPre` | probe restart |
| `camera_capture_probe.py` | 생성된 expectation | probe restart |
| gstApp | process 시작 | gstApp restart 또는 상위 reset |
| ORD | process 시작 | ORD restart 또는 상위 reset |
| VCM | process 시작 | VCM restart 또는 상위 reset |
| compatibility wrapper | runtime을 직접 읽거나 고치지 않고 recovery request만 전달 | executor transaction |

이 목록의 consumer는 source wildcard를 검색하거나 source ord document를 직접 열지 않는다.
invalid runtime은 `CONFIG_INVALID`로 실패하며 source repair 또는 hardware escalation을
시도하지 않는다.

## C. network-side source input

`chk_wifi.sh`와 `chk_eth1.sh`는 camera config consumer가 아니다. camera runtime에는
edgeconf의 `VHL_CAM`만 포함되고 `NETWORK`는 포함되지 않으므로, 두 script는 의도적으로
`/root/shared_v` source를 계속 읽는다. source/config writer allowlist와 함께 유지하여
camera 경로 감사가 이 network 계약을 잘못 금지하지 않게 한다.

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
| `ORD` | ORD | ORD 재기동 |
| `VCM` | VCM | VCM 재기동 |
| cam-operate `ETC` | daemon | in-memory policy reload |
| script-only key | 해당 script | 다음 실행부터 읽기 |

## 감사 기준과 외부 경계

1. source authority, network-side consumer, startup/`apply-config` builder 외에는
   `/root/shared_v` camera JSON open이 없어야 한다.
2. 세 native app과 camera script는 고정 runtime path 또는 두 compatibility alias만
   사용해야 한다.
3. 두 alias는 실제 runtime과 같은 파일을 가리켜야 한다.
4. 자동 recovery와 wrapper는 source를 재검색하지 않아야 한다.
5. source 재적용 뒤 관련 process가 restart되어 새 값을 읽어야 한다.

저장소 밖의 `pim-check` source/deployment가 새 recovery request와 terminal sentinel을
소비하는지는 별도 integration 경계다. 외부 구현과 배포본을 확인하기 전에는 완료로
분류하지 않는다.
