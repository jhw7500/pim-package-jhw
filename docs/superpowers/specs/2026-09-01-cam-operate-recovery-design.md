# cam-operate 상시 유지와 직렬 recovery 설계

> 작성일: 2026-09-01
> 상태: 구현 전 설계 승인본
> 대상 이슈: GitHub #61 `fix(cam): cam-operate 상시 유지와 recovery 직렬화·횟수 관리`
> 코드 기준: `pim-package-jhw` `f74964871478b77f077d0491aac1bf21e690fc2c`

## 1. 결정

`cam-operate.service`의 한 invocation이 카메라 recovery 전체를 소유한다. 자동 recovery
중에는 서비스를 stop/start하지 않으며 ACTIVE 상태를 유지한다. `gstApp` 재시작, 카메라
모듈 reload, camera hard reset, reboot fallback은 단일 요청 인터페이스와 단일 executor를
통해 직렬 실행한다.

서비스 invocation은 시작할 때 검증된 camera config bundle 세대를 고정하며, 어느 순간에도
유효한 active 세대는 하나뿐이다. bundle은 `edgeconf_pim.json`과 `ord_vcm_conf.json` 두
파일을 반드시 함께 포함한다. 실행 중 `/root/shared_v`의 어느 파일이 바뀌어도 현재 세대에는
섞어 적용하지 않는다. 새 설정은 명시적인 `cam-operate` 재시작 또는
`cam-recoveryctl apply-config`에서만 candidate로 검증하고, reset/restart 검증까지 성공한
뒤 원자적으로 새 active 세대로 승격한다. `apply-config`는 같은 invocation 안에서 허용되는
유일한 config-generation 경계다.

같은 boot에서 `cam-operate`를 재시작하면 최소 `module_reload`를 수행한다. 해상도, FPS,
채널 enable/topology, V4L 매핑처럼 hardware epoch를 바꾸는 설정이 달라졌거나 이전 상태가
dirty이면 `camera_hard_reset`을 수행한다. 첫 managed activation은 기존 boot 초기화 흐름대로
정상 module load를 수행한다.

ACTIVE 유지 조건은 서비스 내부의 자동 recovery에 적용한다. 운영자가 명시적으로
`systemctl restart cam-operate`를 실행하거나 systemd가 crash 뒤 새 process를 시작하는 경우는
새 invocation이므로 systemd의 정상적인 deactivating/activating 전이를 거친다.

## 2. 배경과 원인

현재 recovery 경로는 서비스 소유권과 설정 수명이 분리돼 있다.

- `start_cam.sh`가 `restart_app.sh`를 독립 background loop로 실행한다.
- `kill_test.sh`는 `/tmp/restart_flag`를 사용하지만 `restart_app.sh` 자체를 종료하거나
  서비스 invocation 소유권을 검증하지 않는다.
- `cam_operate_stop.sh`는 worker quiesce보다 먼저 gstApp을 종료한다. 그 사이
  `restart_app.sh`가 gstApp을 다시 띄울 수 있다.
- `cam_hard_reset.sh -s -S`는 recovery 안에서 `cam-operate`를 stop/start하여 종료 중인
  invocation과 새 invocation이 겹칠 수 있다.
- `/tmp/cam_recovery.json`과 `/tmp/cam_op_lock`은 영속성이 없고 원자적 상태 전이를
  보장하지 않는다.
- `chk_cam_operate.sh`, `start_cam.sh`, `restart_app.sh`, `kill_test.sh`, `init_cam.sh`가
  edgeconf/ord 설정을 서로 다른 시점과 경로에서 선택하거나 cache한다.

현재 JSON 동작과 변경 후 정책은 다음과 같다.

| 경로 | 현재 동작 | 변경 후 동작 |
|---|---|---|
| `chk_cam_operate.sh` | 서비스 시작 때 최신 wildcard edgeconf와 고정 경로 ord JSON을 읽고 실행 중 reload하지 않음 | invocation의 고정 bundle 세대만 사용 |
| `start_cam.sh` | 호출할 때마다 최신 wildcard JSON 선택 | executor가 넘긴 고정 세대만 사용 |
| `restart_app.sh` | 프로세스 시작 때 JSON을 읽고 cache한 뒤 무한 loop | 독립 loop 제거, daemon이 고정 세대로 liveness 관리 |
| `kill_test.sh` / `killcam` | 호출 때 최신 JSON을 읽지만 주로 cleanup path에 사용 | deprecated wrapper가 `gstapp_restart` 요청, JSON 직접 접근 금지 |
| `init_cam.sh` | module reload 뒤 최신 JSON을 다시 선택 | deprecated wrapper가 `module_reload` 요청, 고정 세대 사용 |
| `cam_hard_reset.sh` | 자체 JSON read는 없고 `-s/-S`가 서비스 수명을 변경 | deprecated wrapper가 `camera_hard_reset` 요청, 서비스 수명 변경 금지 |

따라서 현재는 `/root/shared_v` 변경이 명령별로 일부만 보일 수 있어 old/new 설정이 한
실행에 공존한다. 변경 후에는 runtime 편집을 암묵적으로 반영하지 않아 이 split-brain을
제거한다.

## 3. 목표와 비목표

### 목표

- 자동 recovery 동안 `cam-operate.service`를 ACTIVE로 유지한다.
- 모든 recovery action을 한 owner와 한 executor가 직렬 실행한다.
- 중첩 recovery, orphan worker, 종료 중 gstApp 재기동을 차단한다.
- action별 시도/성공/실패/연속 실패 횟수와 request history를 재시작 후에도 보존한다.
- 두 JSON을 한 설정 세대로 원자적으로 고정하고 모든 결과에 개별/bundle SHA-256을 남긴다.
- candidate 적용 실패 시 기존 active 설정 세대를 보존한다.
- 같은 boot의 명시적 서비스 재시작에서 module/hardware reset을 보장한다.
- 기존 직접 명령은 한 release 동안 호환 wrapper로 유지한다.

### 비목표

- systemd 자체의 비정상 종료 재기동 정책을 대체하지 않는다.
- 여러 recovery 요청을 queue로 적재하지 않는다. 진행 중이면 새 요청은 BUSY다.
- 임의 JSON 변경을 실행 중 hot reload하지 않는다.
- 외부 binary인 gstApp 내부의 JSON open 구현을 이 저장소에서 단정하거나 변경하지 않는다.
- camera recovery가 `ord-operate`/`vcm-operate` 서비스 수명을 제어하게 만들지 않는다. 두
  서비스의 config reload/restart 정책은 각 서비스 owner 범위다.
- 별도 저장소/배포본의 `pim-check` 구현을 이 변경만으로 완료했다고 간주하지 않는다.

## 4. 소유권 모델

서비스 시작 시 daemon은 다음으로 구성된 invocation owner를 생성한다.

- 현재 boot ID: `/proc/sys/kernel/random/boot_id`
- invocation UUID
- daemon PID
- `/proc/<pid>/stat`의 process start time
- 무작위 owner token
- 생성 시각과 상태(`starting`, `active`, `stopping`)

runtime owner record는 `/run/pim-camera/owner.json`에 임시 파일+rename으로 기록한다. action
worker, gstApp launcher, background child는 시작 전과 외부 부작용 직전에 owner tuple 전체를
검증한다. PID만 일치하는 것은 소유권 증명이 아니다. token, boot ID, invocation UUID,
process start time 중 하나라도 다르면 fail closed한다.

```text
cam-operate invocation
  |
  +-- owner generation
  +-- pinned config generation
  +-- main health loop
  |     +-- gstApp liveness check
  |     +-- request intake
  |     `-- recovery policy
  `-- single action executor
        +-- gstapp_restart
        +-- module_reload
        +-- camera_hard_reset
        `-- reboot_fallback
```

`ExecStop`은 다음 순서를 지킨다.

1. owner 상태를 `stopping`으로 바꾸고 token을 폐기한다.
2. 새 request intake를 닫는다.
3. active action과 child worker를 quiesce한다.
4. gstApp을 종료한다.
5. runtime active record를 정리하고 stop 결과를 영속화한다.

systemd unit은 `KillMode=control-group`을 사용해 invocation의 잔존 child를 함께 종료한다.
종료 절차가 시작된 뒤 owner mismatch child가 gstApp을 다시 실행해서는 안 된다.

## 5. 설정 세대와 reset 분류

### 5.1 설정 source와 snapshot

운영자 소유 canonical source는 정확히 다음 두 파일이다.

- `/root/shared_v/edgeconf_pim.json`
- `/root/shared_v/ord_vcm_conf.json`

`edgeconf_*.json` 최신 파일 선택은 제거한다. 두 파일을 한 bundle로 검증하며 하나가
missing/invalid이면 generation 전체를 거부한다. daemon은 canonical source를 직접 수정하지
않는다.

고정 세대는 package의 초기 default JSON을 영구 복사해 쓰는 모델이 아니다. 각 명시적 반영
시점에 존재하는 canonical JSON bundle을 검증해 만든 snapshot이다. 따라서 실행 중 편집은 즉시
반영되지 않지만, 다음 명시적 service restart 또는 `apply-config`에는 반영된다.

runtime config 위치는 `/run/pim-camera/config` 하나만 사용한다. 기존
`camera_config_bootstrap.sh`의 `/tmp/config` publish는 이 경로로 이전하고 `/tmp`에 두 번째
runtime copy를 만들지 않는다. `pim-camera-config.service`가 `RemainAfterExit=yes`와
`RuntimeDirectory=pim-camera`로 boot 동안 directory lifetime을 소유하고, 첫 validated
generation을 camera/ORD/VCM 서비스보다 먼저 publish한다.

서비스 재시작과 `apply-config`에서도 현재 canonical bundle을 bootstrap과 같은 validation
규칙으로 다시 검증한다. 검증 실패 시 현재 pinned generation을 유지하고 새 action을 시작하지
않는다.

검증된 파일은 다음 metadata와 함께 immutable runtime candidate generation으로 publish한다.

- generation UUID
- `edgeconf_pim.json` SHA-256
- `ord_vcm_conf.json` SHA-256
- 파일 이름과 개별 SHA를 key-sort한 manifest의 bundle SHA-256
- 두 schema에서 camera 관련 필드만 정규화한 hardware-epoch SHA-256
- 각 canonical source path와 source SHA-256
- validation 시각
- boot ID와 invocation UUID

runtime generation은 `/run/pim-camera/config/generations/<generation-id>/`에 두 JSON과
`manifest.json`을 함께 저장한다. manifest 생성 규칙과 bundle SHA 계산 입력은 versioned
schema로 고정한다.
classifier가 고른 action은 candidate snapshot으로 실행·검증한다. 성공한 뒤에만
`/run/pim-camera/config/active.json`을 원자적으로 교체하며, 실패하면 기존 active pointer를
유지하고 candidate를 failed history에 연결한다. 하위 process에는 canonical path가 아니라
선택된 generation directory를 명시적으로 전달한다. recovery request와 결과에는 이전
active와 candidate generation UUID, 두 file SHA, bundle SHA, hardware SHA를 모두 기록한다.

daemon은 canonical JSON을 쓰거나 정규화 결과를 되돌려 쓰지 않는다. 기존
`force_edgeconf_app_to_gstapp` 형태의 runtime canonical mutation은 제거한다.

### 5.2 반영 시점

| 사건 | 새 canonical bundle 반영 | 최소 action |
|---|---|---|
| 실행 중 두 canonical 파일 중 하나 또는 모두 편집 | 반영 안 함 | 없음 |
| `killcam` / `init_cam.sh` / `cam_hard_reset.sh` 직접 호출 | 반영 안 함 | wrapper가 요청한 action |
| 자동 health recovery | 반영 안 함 | 기존 pinned generation으로 정책 action |
| 같은 boot의 `systemctl restart cam-operate` | validation/action 성공 시 반영 | `module_reload` |
| `cam-recoveryctl apply-config` | validation/action 성공 시 반영 | diff classifier 결과 |
| 새 boot의 첫 managed activation | 두 파일 boot validation 결과 반영 | 정상 module load |

`apply-config`는 다섯 번째 recovery action type이 아니라 같은 pending/active lease를 사용하는
config control request다. classifier가 고른 실제 action만 해당 action counter에 반영한다.
변경이 없으면 성공 no-op이며 action counter를 올리지 않는다.

### 5.3 hardware epoch classifier

normalized hardware projection은 적어도 다음 의미 필드를 포함한다.

- 카메라 출력 width/height와 FPS
- 카메라/채널 enable 상태
- single/dual channel topology와 CSI/ISI 연결 선택
- V4L device/channel mapping
- driver가 stream prepare 전에만 적용할 수 있는 camera mode 필드

구현 시 실제 JSON path 목록을 한 함수/상수에 중앙화하고 fixture test로 고정한다. key 순서,
공백, 설명용 metadata처럼 hardware에 영향을 주지 않는 변경은 hardware SHA를 바꾸지 않는다.
현재 `ord_vcm_conf.json`의 `ETC.camera_startup_grace_sec`는 health/control policy로 분류하고
hardware epoch에는 넣지 않는다. 향후 ORD/VCM schema에 camera reset/topology field가 추가되면
versioned projection과 test를 함께 갱신한다.

reset 결정은 다음 순서다.

1. 새 boot의 첫 managed activation이면 정상 module load 후 검증한다.
2. 같은 boot의 서비스 재시작이면 최소 `module_reload`를 선택한다.
3. hardware SHA가 달라졌으면 `camera_hard_reset`으로 상향한다.
4. 이전 stop이 unclean, recovery가 interrupted, owner/state가 모순되거나 hardware 상태가
   dirty이면 `camera_hard_reset`으로 상향한다.
5. `apply-config`에서 app-level 변경만 있으면 `gstapp_restart`, hardware 변경이면
   `camera_hard_reset`을 선택한다.
6. `module_reload` 검증 실패는 한 번 `camera_hard_reset`으로 fallback한다.
7. `camera_hard_reset` 검증 실패는 같은 top-level request 안에서 정확히 한 번만
   `reboot_fallback`을 실행한다.

같은 boot 여부는 persistent service state의 마지막 boot ID와 현재 boot ID를 비교한다.
state가 없거나 boot ID가 다르면 첫 managed activation으로 보되, 이미 실행 중인 gstApp,
terminal이 아닌 recovery 또는 모순된 module 상태가 발견되면 unknown/dirty로 분류해 hard
reset으로 상향한다. 각 activation은
`last_invocation_id`, `clean_stop`, pinned bundle SHA, active/interrupted recovery를 갱신한다.

## 6. 요청 인터페이스

### 6.1 CLI

```text
cam-recoveryctl request <type> --source <name> --reason <text> [--wait <sec>]
cam-recoveryctl apply-config --source <name> --reason <text> [--wait <sec>]
cam-recoveryctl status [--request-id <id>] [--json]
```

recovery action type은 다음 네 개로 제한한다.

| type | 의미 |
|---|---|
| `gstapp_restart` | gstApp만 quiesce, stop, pinned config로 재실행, 검증 |
| `module_reload` | gstApp quiesce 후 camera module unload/load, 재실행, 검증 |
| `camera_hard_reset` | 서비스는 유지한 채 camera hardware reset sequence와 재기동, 검증 |
| `reboot_fallback` | 상위 recovery가 모두 실패했을 때 1회 system reboot 요청 |

`source`와 `reason`은 필수이며 빈 문자열을 거부한다. request ID는 UUID로 생성한다.
`--wait`가 없으면 atomic accept 결과까지만 기다리고, 있으면 해당 request의 terminal result를
기다린다.

### 6.2 동시성

`/run/pim-camera/recovery.lock`의 non-blocking lock은 상태 전이의 짧은 critical section을
보호한다. lock 안에서 `pending.json`과 `active.json`을 확인하고 둘 다 없을 때만 새
`pending.json`을 temp+fsync+rename으로 publish한다. daemon은 같은 lock 안에서 pending을
active로 이동한다.

lock은 action 전체 시간 동안 잡지 않는다. 대신 pending/active record가 배타 lease다. 이로써
CLI가 accept 후 종료하는 순간에도 다음 요청이 끼어드는 gap이 없다. pending 또는 active가
있으면 queue하지 않고 다음을 반환한다.

- 상태: `BUSY`
- exit code: `75` (`EX_TEMPFAIL`)
- 현재 request ID와 state

### 6.3 상태와 종료 코드

정상 state machine은 다음과 같다.

```text
accepted -> quiescing -> running -> verifying -> succeeded
                                          |
                                          `-> failed
```

권장 CLI 종료 코드는 다음과 같다.

| code | 의미 |
|---:|---|
| 0 | 요청 접수 또는 기다린 action 성공 |
| 64 | 잘못된 type/argument |
| 69 | daemon/service unavailable |
| 70 | 내부 상태/저장 오류 |
| 75 | 다른 request가 pending/active인 BUSY |
| 124 | `--wait` timeout; action 자체 취소를 뜻하지 않음 |
| 기타 non-zero | 기다린 action의 terminal failure |

stdout의 machine-readable terminal sentinel은 정확히 다음 형식을 사용한다.

```text
CAM_RECOVERY_RESULT id=<uuid> type=<type> status=SUCCEEDED rc=0
```

실패 sentinel은 같은 key 순서에 `status=FAILED`와 non-zero `rc`를 사용한다. 사람이 읽는
설명은 stderr 또는 JSON status에 두며 sentinel parsing에 섞지 않는다.

## 7. 저장과 crash reconciliation

### 7.1 runtime

```text
/run/pim-camera/
  owner.json
  recovery.lock
  recovery/
    pending.json
    active.json
    results/<request-id>.json
  config/
    active.json
    generations/<generation-id>/
      edgeconf_pim.json
      ord_vcm_conf.json
      manifest.json
```

### 7.2 persistent

```text
/var/lib/pim-camera/
  service-state.json
  recovery/
    state.json
    history/<request-id>.json
```

`state.json`은 action type별로 최소 다음 필드를 가진다.

- `attempted`, `succeeded`, `failed`, `consecutive_failures`
- `last_request_id`, `last_started_at`, `last_finished_at`
- `last_status`, `last_rc`, `last_bundle_sha256`

attempt counter는 action이 `running`으로 전이할 때 올린다. 성공/실패와 연속 실패 값은
terminal 전이에서 갱신한다. fallback으로 실제 실행한 action도 별도 counter를 올린다.

history에는 top-level request, source/reason, parent/fallback 관계, 모든 state timestamp,
실행 action, config generation과 file/bundle/hardware SHA, 검증 결과, exit code,
boot/invocation/owner 정보를 남긴다.
모든 JSON 갱신은 동일 filesystem의 temp file에 write+fsync한 뒤 rename하고, 필요한 경우
parent directory도 fsync한다.

서비스 시작 시 persistent history가 terminal이 아닌데 runtime owner가 유효하지 않으면
해당 action을 `FAILED/interrupted`로 reconcile하고 failure counter를 정확히 한 번 갱신한다.
interrupted 표식은 같은 boot 재시작 reset classifier를 hard reset으로 올린다.

## 8. action 실행과 fallback

모든 action은 executor 안에서 다음 공통 단계를 따른다.

1. owner와 request lease 검증
2. 새 health-trigger 억제 및 gstApp/child quiesce
3. 선택 action 실행
4. pinned generation의 edgeconf/ord bundle로 gstApp과 camera-owned child 시작
5. 제한 시간 내 process, channel, camera health 검증
6. result/counter/history 원자적 기록
7. health-trigger 재개

자동 recovery와 fallback은 같은 top-level request 안에서만 이어진다. fallback마다 child
action record를 만들고 실제 action counter를 별도로 반영한다. 별도 worker가 다시 recovery
request를 만들어 중첩 실행해서는 안 된다.

`camera_hard_reset` 내부에서는 `systemctl stop/start/restart cam-operate`를 호출하지 않는다.
서비스 owner가 유지된 상태에서 gstApp과 camera hardware만 quiesce/reset/restart한다.
hard reset 실패 뒤 `reboot_fallback`은 compare-and-set 표식으로 top-level request당 한 번만
허용한다. reboot 요청 자체가 실패해도 반복 loop를 만들지 않고 terminal failure를 남긴다.

## 9. 구성요소 변경

| 구성요소 | 책임 |
|---|---|
| `pim-camera-config.service` / `camera_config_bootstrap.sh` | boot bundle validation, `/run/pim-camera/config` 첫 generation과 manifest publish |
| 신규 `dist/pim/opt/pim/bin/cam-recoveryctl` | request/apply-config/status CLI, validation, BUSY와 wait 처리 |
| 신규 `dist/pim/opt/pim/lib/cam_recovery.sh` | lock, atomic JSON, counter/history, reconciliation 공통 함수 |
| `chk_cam_operate.sh` | 유일한 owner/executor, 고정 bundle로 app liveness와 recovery policy 통합 |
| `start_cam.sh` | generation directory와 owner token을 받아 gstApp 실행 |
| `restart_app.sh` | 독립 무한 loop 제거; 필요하면 deprecated forwarding shim만 유지 |
| `cam_operate_stop.sh` | owner revoke -> worker quiesce -> gstApp stop 순서 보장 |
| `cam_state.sh` | 새 persistent state 조회/기록 API 사용 |
| `BG_Check_for_pim.sh`와 camera-owned descendant | 같은 generation directory 사용, canonical source 직접 read 금지 |
| `pim_guardian.py` | 직접 script/systemctl 대신 `cam-recoveryctl request` 호출 |
| `docs/camera-health/config-consumer-inventory.md` | runtime authority를 `/tmp/config`에서 `/run/pim-camera/config`로 갱신 |
| `cam-operate.service` | RuntimeDirectory/StateDirectory, control-group kill, stop ordering |

`pim-camera-config.service`가 `RuntimeDirectory=pim-camera`와 `RemainAfterExit=yes`로 boot
runtime bundle의 수명을 소유한다. `cam-operate.service`는 config service를 `Requires/After`로
의존하고 `StateDirectory=pim-camera`, 적절한 directory mode, `KillMode=control-group`을
적용한다. exact directive와 shared RuntimeDirectory cleanup semantics는 대상 Ubuntu 20.04의
systemd 버전에서 검증한다.

## 10. 한 release 호환 정책

기존 command는 한 release 동안 남기되 실제 recovery를 직접 수행하지 않는다.

| 기존 진입점 | forwarding request |
|---|---|
| `kill_test.sh` / `killcam` | `gstapp_restart` |
| `init_cam.sh` | `module_reload` |
| `cam_hard_reset.sh` | `camera_hard_reset` |

wrapper는 stderr에 deprecated 경고를 출력하고 synchronous wait로 terminal 결과를 받아 같은
성공/실패 의미를 반환한다. wrapper는 JSON을 선택하거나 module/gstApp/systemd를 직접
조작하지 않는다. 특히 `cam_hard_reset.sh -s -S`는 인자를 호환 목적으로 받아도 서비스
stop/start를 수행하지 않는다.

다음 major 또는 사전 공지된 release에서 직접 진입점을 제거할 수 있도록 호출 source를
history/journal에 기록한다.

## 11. 관측성과 guardian 출력

각 request와 state transition은 journald 및 `local0`에 구조화된 한 줄 로그로 기록한다.
최소 field는 request ID, action type, source, state, rc, boot ID, invocation ID, bundle SHA,
elapsed time이다. reason의 newline/control character는 sanitize한다.

guardian/status 출력에는 다음 recovery summary를 포함한다.

- pending/active request와 elapsed time
- 마지막 terminal request/action/result
- action별 counter와 consecutive failure
- 현재 invocation과 pinned bundle/file SHA
- interrupted/dirty 여부

status 조회는 상태를 변경하지 않으며 missing/corrupt persistent file을 구분해 보고한다.

## 12. 오류 처리

- canonical bundle validation 실패: 기존 pinned 세대 유지, request 실패, hardware 미변경
- owner mismatch: action 시작/계속 금지, interrupted history 기록
- atomic state write 실패: 외부 action 시작 전이면 중단; action 후면 journal에 비상 기록하고
  다음 시작에서 reconcile
- gstApp verification 실패: recovery policy에 따라 직렬 fallback
- module reload 실패: hard reset으로 한 번 상향
- hard reset 실패: reboot fallback 정확히 한 번
- daemon unavailable: CLI exit 69, legacy wrapper도 실패 전달
- corrupt history/state: 원본을 덮어 숨기지 않고 별도 진단 로그 후 fail closed

## 13. 검증 계획

### 13.1 단위/통합 test

- 두 동시 request 중 하나만 accepted, 다른 하나는 BUSY/75
- pending -> active 전이에 request가 끼어들 수 없음
- state machine success/failure와 CLI wait/timeout/sentinel
- action별 counter, consecutive failure, history의 재시작 후 persistence
- interrupted active action의 startup reconciliation이 한 번만 수행됨
- module reload 실패 -> hard reset, hard reset 실패 -> reboot fallback 1회
- fallback child action별 counter와 parent relation
- stop timeline에서 owner revoke 뒤 gstApp 재실행이 없음
- PID 재사용을 포함한 owner token/start-time mismatch fail closed
- 자동 hard reset 경로에 `systemctl stop/start/restart cam-operate`가 없음
- runtime JSON 편집이 현재 pinned 세대에 섞이지 않음
- explicit restart/apply-config의 action 성공만 새 validated SHA를 승격함
- candidate action 실패는 기존 active pointer를 보존하고 dirty 상태를 기록함
- daemon과 helper가 canonical JSON을 수정하지 않음
- 두 JSON 중 하나가 missing/invalid이면 bundle 전체가 거부되고 active pointer가 유지됨
- 두 file hash와 manifest의 deterministic bundle hash가 재현됨
- camera runtime consumer가 `/tmp/config` 또는 `/root/shared_v`를 직접 읽지 않음
- same-boot restart는 최소 module reload, hardware SHA 변경/dirty는 hard reset
- new boot 첫 activation은 normal module load
- key order/공백/app-only 변경은 hardware SHA를 바꾸지 않음
- invalid canonical JSON은 기존 pinned 세대와 hardware를 보존함
- legacy wrapper mapping, warning, synchronous exit propagation
- `pim_guardian.py`가 새 request interface와 strict sentinel/status를 사용함

### 13.2 기존 회귀와 package gate

- `test/camera_health` 전체
- `test/cam_link` 전체, 특히 `initcam_modprobe_test.sh`
- shellcheck와 Python test/lint
- package 설치 후 신규 CLI/library 실행 권한과 systemd directory 생성
- maintainer script와 binary manifest 검증

### 13.3 target board 합격 기준

- 자동 app/module/hard-reset recovery 동안 `cam-operate.service`가 계속 ACTIVE
- 요청 2개를 동시에 보내도 실제 hardware action은 하나만 실행
- service restart 시 분류된 module/hard reset이 한 번 실행되고 정상 stream 복구
- stop/restart stress 중 orphan `restart_app.sh`와 중복 gstApp process가 없음
- 두 canonical 파일 중 하나를 실행 중 수정해도 기존 process는 같은 bundle SHA를 유지
- `apply-config` 또는 명시적 restart 성공 뒤에만 두 JSON의 새 bundle SHA가 반영
- module/hard-reset failure injection 결과와 reboot fallback 횟수가 history/counter와 일치
- 재부팅 뒤 counter/history가 유지되고 interrupted request가 정확히 reconcile
- `pim-check`가 새 request/sentinel로 전환된 배포본에서 end-to-end 판정 통과

## 14. rollout과 완료 조건

1. bootstrap destination을 `/run/pim-camera/config`로 옮기고 two-file manifest를 test-first로
   추가한다.
2. atomic state/config library와 CLI를 test-first로 추가한다.
3. daemon owner/executor와 app liveness를 통합한다.
4. stop ordering과 systemd ownership을 변경한다.
5. guardian, camera-owned config consumer, legacy wrapper를 전환한다.
6. host test와 package gate를 통과한다.
7. 대상 보드에서 service ACTIVE, concurrency, reset classifier, config pinning을 검증한다.
8. 한 release 동안 deprecated 호출 telemetry를 확인한 뒤 제거 계획을 확정한다.

완료는 코드가 존재하는 것만으로 판정하지 않는다. 위 host/board acceptance가 통과하고,
모든 자동 recovery history가 단일 owner와 pinned bundle SHA를 가리키며, 서비스 종료 구간에
gstApp 재기동이 관측되지 않아야 한다.

## 15. 구현 전 확인할 외부 경계

- gstApp은 이 저장소에서 binary로 배포되므로 config path 전달 방식과 실제 file open 시점을
  target log 또는 upstream source로 확인한다. 확인 전에는 symlink/환경변수 지원을 가정하지
  않는다.
- `pim-check`의 실제 배포 source가 이 저장소 밖에 있으면 해당 저장소에서 별도 변경과 검증이
  필요하다. 이 저장소에서는 새 CLI/sentinel contract와 guardian 연동까지만 보장한다.
- systemd `RuntimeDirectoryPreserve` 등 선택 directive는 target systemd 245에서 지원 여부와
  stop/restart semantics를 확인한 뒤 적용한다. 지원에 의존하지 않고 persistent hash로
  same-boot restart를 판정할 수 있어야 한다.
