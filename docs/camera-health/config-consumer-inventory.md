# Camera configuration consumer inventory

> 목적: 부팅 때 검증된 `/root/shared_v`의 canonical JSON을 `/tmp/config`으로 한 번
> publish한 뒤 camera runtime이 shared 경로를 다시 읽지 않게 하기 위한 전환 목록.

## 경로 정책

| 역할 | `/root/shared_v` | `/tmp/config` |
|---|---|---|
| config guard/factory/config writer | 읽기·쓰기 허용 | publish helper를 통한 갱신만 |
| `pim-camera-config.service` | boot당 한 번 읽기 | atomic publish/READY 작성 |
| camera runtime consumer | 금지 | 매 process start 때 parse/schema 검증 |
| 엔지니어 runtime override | 사용하지 않음 | atomic rename으로 직접 변경 허용 |
| max9296 kernel driver | JSON을 읽지 않음 | userspace가 완전한 control set 전달 |

boot source는 `config_guard.sh`가 검증한 canonical
`edgeconf_pim.json`, `ord_vcm_conf.json` 두 개다. `edgeconf_*.json` 중 mtime이
가장 최신인 파일을 임의 선택하지 않는다.

## A. camera lifecycle 필수 전환 대상

| consumer | 현재 source/시점 | 필요한 변경 | 재적용 경계 |
|---|---|---|---|
| `chk_cam_operate.sh` | shared edgeconf/ord JSON, process start | `/tmp/config` canonical 파일 | cam-operate restart |
| `start_cam.sh` | shared 최신 edgeconf, 매 호출 | `/tmp/config/edgeconf_pim.json` | 매 direct/managed start |
| `init_cam.sh` | shared 최신 edgeconf, 매 호출 | `/tmp/config/edgeconf_pim.json` | 매 direct init |
| `kill_test.sh` | shared 최신 edgeconf, 매 호출 | `/tmp/config/edgeconf_pim.json` | 매 direct kill |
| `restart_app.sh` | shared 최신 edgeconf, process start 후 cache | `/tmp/config/edgeconf_pim.json` | supervisor start |
| `BG_Check_for_pim.sh` | shared edgeconf+ord, process start | `/tmp/config` 두 파일 | BG start |
| `cam_channel_resolve.sh` | `EDGECONF_DIR=/root/shared_v` 기본 | 기본을 `/tmp/config`, explicit override 유지 | 매 diagnostic invocation |
| ORD | `ord/util.h` compile-time shared path | `/tmp/config` canonical paths | ORD restart |
| VCM | `vcm/util.h` compile-time shared path | `/tmp/config` canonical paths | VCM restart |
| gstApp/streamApp/PIMCAM | 외부 저장소 inventory 필요 | `/tmp/config` 고정 + config hash | app restart |

## B. camera-owned descendant라 함께 전환할 대상

`BG_Check_for_pim.sh`가 주기적으로 실행하므로 상위 script만 바꿔서는 runtime shared
read 0건을 달성하지 못한다.

| consumer | 현재 동작 | 분류 |
|---|---|---|
| `chk_wifi.sh` | 매 호출 shared edgeconf scan | BG descendant, `/tmp/config` 전환 |
| `chk_eth1.sh` | 매 호출 shared/backup scan | BG descendant, `/tmp/config` 전환 |
| `mcp4018_ctrl.sh` → `cam_channel_resolve.sh` | helper 기본 shared | camera diagnostic/runtime, 기본 경로 전환 |
| AP1302/Sensor diagnostic helpers | channel resolver 사용 | 기본 경로 전환, explicit test override 유지 |

## C. shared source 사용을 유지할 config authority

다음은 runtime consumer가 아니라 canonical 설정을 만들거나 검증하는 주체다.

- `config_guard.sh`
- `factory_init.sh`, `factory_init_pim_gate.sh`
- `update_edgeconf.sh`, `update_ordvcmconf.sh`
- `update_network_pim.py`, `update_eap_id.py`, `update_time_sync.sh`
- `camera_config_bootstrap.sh`

이 도구가 runtime 설정도 즉시 바꾸려면 shared 수정과 별도로 명시적인
`/tmp/config` atomic override를 수행해야 한다. 기본 정책은 다음 boot import 전까지
shared 변경이 running camera에 영향을 주지 않는 것이다.

## D. camera 외 시스템 consumer — owner 결정 필요

다음 항목은 shared access가 확인됐지만 camera lifecycle 소유로 단정하지 않는다.
camera boot snapshot을 공용 system snapshot으로 확대할지, 기존 shared source를 유지할지
각 owner와 결정한다.

- `automnt_sd_for_emmc_boot.sh`
- `cam_rotate_setting.sh`
- `cpu_limit.sh`
- `file_manager.sh`
- `ncsftp.sh`
- `sd_mount_stop.sh`
- `set_link_speed.py`
- `pim_guardian.py`

단, 이 프로세스가 camera health/recovery 판정에 값을 제공하면 A/B 대상으로 승격한다.

## 전환 완료 감사

1. boot 후 각 consumer PID의 `/proc/<pid>/fd`와 audit 로그로 config source를 기록한다.
2. bootstrap/config authority를 제외한 camera-owned process에서 `/root/shared_v` open 0건.
3. shared JSON 변경 후 automatic gstApp restart가 `/tmp/config` hash를 유지한다.
4. `/tmp/config` 직접 변경 후 reset한 app만 새 hash를 사용한다.
5. 명시적 cam-operate restart 후 A/B registry의 모든 consumer가 현재 tmp hash를 사용한다.

## 아직 확인이 필요한 외부 항목

- gstApp 저장소의 모든 edgeconf/ord JSON open site
- max9296 reinitialize에 전달할 complete desired-control 목록
- 저장소 밖에서 `startcam`, `killcam`, `init_cam.sh`를 호출하는 consumer
- D 목록의 실제 systemd owner와 camera stop 시 기대 생존 범위
