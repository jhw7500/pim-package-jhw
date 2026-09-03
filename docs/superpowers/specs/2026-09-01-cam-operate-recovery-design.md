# cam-operate 상시 유지와 직렬 recovery 설계

> 작성일: 2026-09-01
> 상태: 구현 전 설계 승인본
> 대상 이슈: GitHub #61 `fix(cam): cam-operate 상시 유지와 recovery 직렬화·횟수 관리`
> 코드 기준: `pim-package-jhw` `f74964871478b77f077d0491aac1bf21e690fc2c`

## 1. 결정

`cam-operate.service`의 한 invocation이 카메라 recovery와 camera process liveness를 모두
소유한다. 자동 recovery 중에는 서비스를 stop/start하지 않고 ACTIVE로 유지한다. gstApp
재시작, camera module reload, camera hard reset, reboot fallback은 단일 요청 인터페이스와
단일 executor를 통해 직렬 실행한다.

설정은 `/run/pim-camera/config/pim_runtime.json` 한 파일로 단순화한다. 이 파일은 다음을
합친 mutable runtime JSON이다.

- cam-operate가 `/root/shared_v/edgeconf_*.json` 중 가장 최신 파일에서 읽은 `VHL_CAM`
- `/root/shared_v/ord_vcm_conf.json`의 전체 top-level 내용

병합할 때 edgeconf의 `VHL_CAM`이 항상 우선한다. runtime generation directory, active
pointer, manifest, file/bundle SHA, process별 SHA 일치 검사는 사용하지 않는다.

원본 최신 파일 검색과 runtime 생성은 cam-operate만 수행한다. 시점은 daemon 최초 시작,
명시적 cam-operate 재시작, `cam-recoveryctl apply-config`로 제한한다. 자동 recovery와 기존
`killcam`/`init_cam.sh`/hard-reset 호환 명령은 원본을 검색하지 않고 현재 runtime JSON을
사용한다.

runtime JSON 직접 편집은 실제 수동 시험을 위해 허용한다. 편집 후 원하는 test app을
재시작하면 그 process가 수정된 값을 읽는다. 다른 process가 이전 값을 메모리에 유지하는
일시적 혼합 상태는 수동 시험 예외로 인정한다. 이 변경은 cam-operate 재시작 또는
`apply-config` 때 원본을 다시 검색해 runtime을 교체하면서 사라진다.

## 2. 배경과 원인

현재 recovery 경로에는 다음 문제가 있다.

- `start_cam.sh`가 `restart_app.sh`를 독립 background loop로 실행한다.
- `kill_test.sh`는 `/tmp/restart_flag`를 사용하지만 `restart_app.sh`의 service invocation
  소유권을 검증하지 않는다.
- `cam_operate_stop.sh`가 worker를 먼저 멈추지 않아 종료 중 gstApp이 다시 실행될 수 있다.
- `cam_hard_reset.sh -s -S`가 recovery 내부에서 cam-operate를 stop/start하여 이전
  invocation과 새 invocation이 겹칠 수 있다.
- `/tmp/cam_recovery.json`, `/tmp/cam_op_lock`, 여러 flag는 영속성과 원자적 상태 전이를
  보장하지 않는다.
- gstApp, ORD, VCM과 여러 script가 `/root/shared_v`, `edgeconf_*.json`,
  `ord_vcm_conf.json`을 서로 다른 시점에 직접 선택한다.

현재 `restart_app.sh`가 제공하는 죽은 process 자동 재시작 기능은 필요하다. 제거 대상은
그 기능이 아니라 cam-operate와 독립적으로 동작하는 무한 loop와 flag race다.

## 3. 목표와 비목표

### 목표

- 자동 recovery 동안 `cam-operate.service`를 ACTIVE로 유지한다.
- 모든 recovery action을 한 owner와 한 executor가 직렬 실행한다.
- 중첩 recovery, orphan worker, 종료 중 process 재기동을 차단한다.
- gstApp, ORD, VCM의 비정상 종료 자동 재시작 기능을 유지한다.
- action별 시도/성공/실패/연속 실패 횟수와 request history를 재시작 후에도 보존한다.
- 원본 선택은 cam-operate 한 곳에서만 수행하고 모든 consumer는 고정 runtime 경로를 쓴다.
- runtime을 직접 편집한 뒤 test app만 재시작하는 수동 시험을 허용한다.
- 같은 boot의 cam-operate 재시작에서 최소 module reload를 보장한다.
- 기존 직접 명령은 한 release 동안 호환 wrapper로 유지한다.

### 비목표

- systemd 자체의 비정상 종료 재기동 정책을 대체하지 않는다.
- 여러 recovery 요청을 queue로 적재하지 않는다. 진행 중이면 새 요청은 BUSY다.
- runtime JSON 변경을 자동 감지하거나 hot reload하지 않는다.
- runtime 변경을 `/root/shared_v` 원본으로 역반영하지 않는다.
- immutable config generation, rollback generation, manifest 또는 SHA 추적을 도입하지 않는다.
- 모든 process가 수동 시험 중 같은 설정을 사용한다고 보장하지 않는다.
- 별도 저장소/배포본의 `pim-check` 구현을 이 변경만으로 완료했다고 간주하지 않는다.

## 4. 소유권과 상태 모델

daemon은 시작할 때 다음 tuple로 invocation owner를 만든다.

- 현재 boot ID: `/proc/sys/kernel/random/boot_id`
- invocation UUID
- daemon PID와 `/proc/<pid>/stat` process start time
- 무작위 owner token
- 생성 시각과 lifecycle state

owner record는 `/run/pim-camera/owner.json`에 임시 파일 쓰기와 rename으로 기록한다. action
worker와 launcher는 외부 부작용 직전에 tuple 전체를 검증한다. PID만 같은 것은 소유권
증명이 아니다.

```text
cam-operate invocation
  |
  +-- runtime config builder
  +-- process liveness supervisor
  +-- health/recovery policy
  `-- single action executor
        +-- gstapp_restart
        +-- module_reload
        +-- camera_hard_reset
        `-- reboot_fallback
```

lifecycle state는 다음으로 제한한다.

| state | 새 자동 재시작 | 설명 |
|---|---|---|
| `STARTING` | 금지 | 원본 검색, runtime 생성, 초기화 중 |
| `ACTIVE` | 허용 | health 감시와 비정상 종료 복구 |
| `APPLYING_CONFIG` | 금지 | 원본 재검색과 설정 반영 중 |
| `RECOVERING` | executor만 허용 | 선택한 recovery action 실행 중 |
| `STOPPING` | 금지 | owner 폐기와 child 종료 중 |
| `DEGRADED` | 금지 | terminal action 실패 후 운영자 조치 대기 |

ACTIVE 이외의 상태에서는 liveness supervisor가 process를 임의로 실행하지 않는다. action
executor만 자신의 단계에서 필요한 process를 시작할 수 있다.

## 5. runtime config 계약

### 5.1 경로와 호환 파일명

실제 runtime 파일은 하나다.

```text
/run/pim-camera/config/
  pim_runtime.json
  edgeconf_pim.json  -> pim_runtime.json
  ord_vcm_conf.json -> pim_runtime.json
```

두 symlink는 경로와 파일명을 고정 참조하는 기존 consumer를 위한 한 release 호환 장치다.
서로 다른 JSON copy를 만들지 않는다. runtime directory 밖의 `/tmp/config` copy는 두지 않는다.

`pim-camera-config.service`와 `camera_config_bootstrap.sh`는 source directory 접근 권한과
필수 도구 같은 선행 조건만 검사한다. runtime directory를 소유하거나 최신 edgeconf를
선택하거나 runtime JSON을 생성하지 않는다. cam-operate가 runtime을 publish하고 ready가 된
뒤에 config consumer가 시작되도록 service ordering을 조정한다.

### 5.2 원본 선택과 병합

cam-operate는 다음 순서로 runtime candidate를 만든다.

1. 단일 source-root 상수(기본값 `/root/shared_v`) 아래 `edgeconf_*.json` regular file을 mtime
   내림차순으로 정렬한다.
2. mtime이 같으면 전체 path의 bytewise lexical 오름차순을 tie-break로 사용한다.
3. 첫 파일 하나를 선택한다. 선택한 최신 파일이 invalid여도 과거 파일로 후퇴하지 않는다.
4. 같은 source-root의 고정 파일 `ord_vcm_conf.json`을 읽는다.
5. edgeconf의 `.VHL_CAM` object와 ord JSON의 `.ORD`, `.VCM` object 존재를 검증한다.
6. ord JSON 전체를 복사한 뒤 `.VHL_CAM`을 선택한 edgeconf 값으로 덮어쓴다.
7. 임시 파일을 다시 parse/validate한 뒤 fsync와 rename으로 `pim_runtime.json`을 교체한다.
8. 호환 symlink가 동일한 runtime 파일을 가리키는지 확인한다.

`ETC`와 ord JSON의 추가 top-level key는 그대로 보존한다. ord JSON에 `VHL_CAM`이 있더라도
선택한 edgeconf의 값이 최종 runtime에 들어간다. 선택한 source path와 mtime은 journal과
request result에 기록하되 SHA는 계산하거나 저장하지 않는다.

### 5.3 생성 시점

| 사건 | 원본 재검색 | runtime 처리 | process/reset 처리 |
|---|---:|---|---|
| 새 boot 최초 cam-operate 시작 | 예 | 신규 생성 | 정상 module init 후 consumer 시작 |
| 같은 boot의 cam-operate 재시작 | 예 | 기존 값을 source로 쓰지 않고 교체 | 최소 module reload, 필요 시 hard reset |
| `apply-config` | 예 | candidate 검증 후 교체 | JSON diff에 필요한 action 실행 |
| 자동 health recovery | 아니오 | 현재 파일 재사용 | 현재 runtime으로 recovery |
| gstApp/ORD/VCM 비정상 종료 | 아니오 | 현재 파일 재사용 | 해당 liveness 정책으로 재시작 |
| `killcam`/`init_cam.sh`/hard-reset wrapper | 아니오 | 현재 파일 재사용 | wrapper가 요청한 action 실행 |
| runtime 직접 편집 | 아니오 | operator가 현재 파일 수정 | operator가 선택한 app만 재시작 |

cam-operate 재시작에서는 기존 runtime이 존재해도 새 invocation의 입력이나 fallback으로
사용하지 않는다. 새 source가 missing/invalid이면 invocation은 ready가 되지 않고 consumer를
시작하지 않는다.

`apply-config`는 현재 invocation이 ACTIVE 또는 DEGRADED이고 다른 lease가 없을 때 candidate를
먼저 검증한다. validation 실패는 기존 process를 중단하지 않고 request를 실패시킨다.
validation 성공 뒤에는 기존 runtime을 원자적으로 교체하며 자동 rollback하지 않는다. 반영
action이 terminal failure면 새 runtime을 유지하고 daemon을 DEGRADED로 표시한다. DEGRADED나
dirty 상태에서의 no-change apply는 no-op으로 끝내지 않고 recovery policy가 정한 최소 action과
health verification을 수행한다.

### 5.4 수동 runtime 시험

operator는 `pim_runtime.json`을 직접 편집할 수 있다. 관리 경로로 process를 재시작하기 전
JSON syntax와 필수 object를 검증한다. invalid runtime은 `CONFIG_INVALID`로 실패하며
module reload, hard reset, reboot로 확대하지 않는다.

유효한 runtime을 편집한 뒤 gstApp을 종료하거나 `gstapp_restart`를 요청하면 supervisor가
원본을 재검색하지 않고 편집된 runtime으로 gstApp을 다시 실행한다. ORD 또는 VCM만
재시작하면 해당 process만 새 값을 읽는다. 이 혼합 상태는 수동 시험에 한해 허용한다.

수동 변경은 persistent 원본이 아니다. cam-operate 재시작이나 `apply-config`가 성공하면
`/root/shared_v`에서 다시 만든 runtime으로 덮어쓴다. 영구 변경은 원본 JSON을 직접 수정한다.

### 5.5 consumer 경로

gstApp, ORD, VCM과 camera 관련 script는 다음 계약을 따른다.

- `/root/shared_v/edgeconf_*.json` wildcard를 직접 검색하지 않는다.
- `/root/shared_v/ord_vcm_conf.json`을 직접 열지 않는다.
- process 시작 때 고정 runtime path 또는 호환 alias를 연다.
- 가능하면 launcher의 명시적 `--config`를 사용하고, 미지원 binary는 compile-time default를
  `/run/pim-camera/config`로 바꾼다.
- shell script는 공통 resolver 하나를 사용하고 개별 path 상수를 중복 정의하지 않는다.

gstApp binary/source 변경도 이 범위에 포함한다. consumer가 파일을 process 시작 때 cache하는
것은 허용하며 자동 hot reload는 요구하지 않는다.

## 6. process liveness와 정지 순서

기존 `restart_app.sh`의 기능은 cam-operate liveness supervisor로 옮긴다.

- ACTIVE 상태에서 ORD 또는 VCM이 사라지면 해당 process를 재시작한다.
- gstApp이 사라지면 직렬 `gstapp_restart` action으로 처리한다.
- camera disconnect, video node, subdev readiness gate와 restart grace 의미를 보존한다.
- 수동으로 runtime을 편집한 뒤 app을 종료한 경우도 같은 자동 재시작 경로를 사용한다.
- 유효한 config에서 gstApp/camera health가 반복 실패하면 module reload, hard reset, reboot
  fallback으로 상향한다.
- ORD/VCM process 자체의 시작 실패는 기록하고 DEGRADED로 전이하되, 별도의 camera health
  실패 증거가 없으면 camera hardware recovery로 상향하지 않는다.
- 설정 validation 실패는 hardware failure가 아니므로 상향하지 않는다.

`restart_app.sh`의 독립 무한 loop는 제거한다. 외부 호출 호환성이 필요하면 한 release 동안
cam-operate 상태를 확인하거나 요청만 전달하는 deprecated shim으로 남긴다.

현재 `ord-operate.service`의 `Restart=on-failure`와 cam-operate supervisor가 동시에 ORD를
재시작해서는 안 된다. 변경 후에는 cam-operate가 restart 결정의 단일 owner이고 systemd unit은
ORD process 실행 경계로만 사용한다. `ord-operate.service`의 autonomous restart를 끄고
`After`/`PartOf`로 cam-operate lifecycle에 묶으며, supervisor가 필요할 때 executor 안에서
unit을 재시작한다. VCM과 gstApp은 cam-operate가 기존 launcher를 통해 관리한다.

`ExecStop`은 다음 순서를 지킨다.

1. owner 상태를 STOPPING으로 바꾸고 새 request intake를 닫는다.
2. liveness supervisor를 먼저 quiesce한다.
3. active action과 child worker를 quiesce한다.
4. gstApp, ORD, VCM 등 managed process를 종료한다.
5. runtime owner record를 정리하고 stop 결과를 영속화한다.

systemd unit은 `KillMode=control-group`을 사용해 잔존 child를 함께 종료한다. STOPPING 이후
어떤 monitor도 process를 다시 실행해서는 안 된다.

## 7. apply-config와 cam-operate 재시작

두 경로는 원본 검색, 병합, validation, runtime publish 코드를 공유하지만 적용 정책은 다르다.

| 구분 | `apply-config` | cam-operate 재시작 |
|---|---|---|
| owner | 현재 invocation 유지 | 새 invocation 생성 |
| 원본 재검색/runtime 재생성 | 수행 | 수행 |
| 변경 판단 | 현재 runtime과 candidate의 JSON 값 비교 | 마지막 성공 hardware projection과 candidate 비교 |
| 의미 변경 없음 | runtime 교체 후 action 없는 성공 | consumer 전체 재기동과 최소 module reload |
| 일반 설정 변경 | 관련 consumer를 quiesce/restart | consumer 전체 재기동과 최소 module reload |
| hardware 관련 변경 | camera hard reset 후 consumer 재기동 | camera hard reset 후 consumer 재기동 |
| dirty/interrupted 상태 | 기존 recovery policy로 상향 | camera hard reset으로 상향 |

`apply-config`는 파일 생성 명령이 아니다. 성공은 새 runtime으로 관련 process가 ready 상태가
된 것을 뜻한다. candidate가 현재 runtime과 다르면 consumer를 quiesce한 뒤 runtime을
교체하고, 변경된 top-level 영역에 관계된 장기 실행 consumer를 재시작한다. `VHL_CAM`이
바뀌면 gstApp, ORD, VCM이 모두 새 값을 읽도록 함께 재기동한다.

| 변경 영역 | 즉시 반영 동작 |
|---|---|
| `VHL_CAM` hardware field | camera hard reset 후 gstApp, ORD, VCM 재기동 |
| `VHL_CAM` non-hardware field | gstApp, ORD, VCM 재기동 |
| `ORD` | ORD 재기동 |
| `VCM` | VCM 재기동 |
| cam-operate가 사용하는 `ETC` | 현재 invocation의 in-memory policy reload |
| script-only 추가 key | 다음 script 실행부터 새 runtime 사용 |

여러 영역이 바뀌면 동작의 합집합을 한 APPLYING_CONFIG transaction에서 한 번만 실행한다.

hardware reset 분류는 SHA 대신 정규화된 JSON 값을 직접 비교한다. 비교 projection에는 최소
다음 의미 필드를 한 함수/상수로 중앙화한다.

- camera output width/height와 FPS
- camera/channel enable 상태
- single/dual topology와 CSI/ISI 연결 선택
- V4L device/channel mapping
- driver가 stream prepare 전에만 적용할 수 있는 camera mode

key 순서, 공백, 설명용 metadata는 semantic diff로 보지 않는다. 마지막 성공 hardware
projection은 `/var/lib/pim-camera/service-state.json`에 값 자체로 저장한다. 같은 boot의
cam-operate 재시작은 값이 같아도 최소 module reload를 수행한다. projection이 바뀌었거나
없거나 corrupt하거나 이전 action이 interrupted/dirty이면 hard reset을 수행한다.

## 8. 요청 인터페이스와 동시성

```text
cam-recoveryctl request <type> --source <name> --reason <text> [--wait <sec>]
cam-recoveryctl apply-config --source <name> --reason <text> [--wait <sec>]
cam-recoveryctl status [--request-id <id>] [--json]
```

recovery action type은 다음 네 개다.

| type | 의미 |
|---|---|
| `gstapp_restart` | 현재 runtime 검증, gstApp quiesce/restart, health 검증 |
| `module_reload` | consumer quiesce, camera module unload/load, 재기동, 검증 |
| `camera_hard_reset` | 서비스 owner를 유지한 hardware reset sequence와 재기동 |
| `reboot_fallback` | 상위 recovery가 모두 실패했을 때 한 번의 system reboot 요청 |

`apply-config`는 action type이 아니라 같은 pending/active lease를 사용하는 control request다.
실제로 실행한 recovery action만 action counter에 반영한다. `source`와 `reason`은 필수이며
request ID는 UUID다.

`/run/pim-camera/recovery.lock`의 non-blocking lock과 pending/active record를 사용한다.
pending 또는 active request가 있으면 queue하지 않고 `BUSY`, exit code 75를 반환한다. lock은
상태 전이의 짧은 critical section만 보호하고 pending/active record가 action 전체의 배타
lease가 된다.

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
| 64 | 잘못된 type/argument 또는 config syntax/schema |
| 69 | daemon/service unavailable |
| 70 | 내부 상태/저장 오류 |
| 75 | 다른 request가 pending/active인 BUSY |
| 124 | `--wait` timeout; action 자체 취소는 아님 |

terminal sentinel은 다음 형식을 사용한다.

```text
CAM_RECOVERY_RESULT id=<uuid> type=<type> status=SUCCEEDED rc=0
```

실패는 같은 key 순서에 `status=FAILED`와 non-zero `rc`를 사용한다.

## 9. action 실행과 fallback

모든 action은 executor 안에서 다음 공통 단계를 따른다.

1. owner와 request lease 검증
2. liveness trigger 억제와 managed process quiesce
3. 현재 runtime JSON validation
4. 선택 action 실행
5. 필요한 process 시작
6. 제한 시간 내 process/channel/camera health 검증
7. result, counter, history 기록
8. 성공 시 ACTIVE 복귀, terminal 실패 시 DEGRADED 전이

자동 recovery와 fallback은 같은 top-level request 안에서만 이어진다. module reload 검증
실패는 hard reset으로 한 번 상향한다. hard reset 실패는 같은 top-level request에서 정확히
한 번만 reboot fallback을 허용한다. 별도 worker가 다시 recovery request를 만들어 중첩
실행해서는 안 된다.

`camera_hard_reset`은 `systemctl stop/start/restart cam-operate`를 호출하지 않는다. service
owner를 유지한 상태에서 camera hardware와 managed process만 다룬다.

## 10. runtime과 persistent 상태

```text
/run/pim-camera/
  owner.json
  recovery.lock
  recovery/
    pending.json
    active.json
    results/<request-id>.json
  config/
    pim_runtime.json
    edgeconf_pim.json  -> pim_runtime.json
    ord_vcm_conf.json -> pim_runtime.json

/var/lib/pim-camera/
  service-state.json
  recovery/
    state.json
    history/<request-id>.json
```

`state.json`은 action type별로 다음 값을 가진다.

- `attempted`, `succeeded`, `failed`, `consecutive_failures`
- `last_request_id`, `last_started_at`, `last_finished_at`
- `last_status`, `last_rc`

history에는 top-level request, source/reason, parent/fallback 관계, state timestamp, 실제 action,
검증 결과, exit code, boot/invocation/owner 정보를 기록한다. config 정보는 runtime path,
선택한 source path와 mtime만 기록하며 SHA나 generation ID를 넣지 않는다.

attempt counter는 action이 running으로 전이할 때 올린다. terminal 전이에서 성공/실패와 연속
실패를 갱신한다. fallback으로 실제 실행한 action도 별도 counter를 올린다. process liveness
event는 journal/history에 target과 원인을 남긴다.

모든 persistent JSON은 동일 filesystem의 임시 파일에 쓰고 fsync한 뒤 rename한다. daemon
시작 시 terminal이 아닌 history의 owner가 유효하지 않으면 `FAILED/interrupted`로 한 번만
reconcile하고 같은 boot reset 분류를 hard reset으로 올린다.

## 11. 구성요소 변경

| 구성요소 | 변경 책임 |
|---|---|
| `pim-camera-config.service` / `camera_config_bootstrap.sh` | source 접근/필수 도구 guard만 수행; runtime 생성 금지 |
| 신규 `cam-recoveryctl` | request, apply-config, status, BUSY/wait/exit contract |
| 신규 `cam_recovery.sh` | owner, lock, atomic state, counter/history 공통 함수 |
| `chk_cam_operate.sh` | 유일한 owner/executor, runtime builder, liveness supervisor |
| `start_cam.sh` | 고정 runtime path와 owner 검증 후 app 실행 |
| `restart_app.sh` | 독립 loop 제거; 필요 시 deprecated forwarding shim |
| `cam_operate_stop.sh` | STOPPING -> monitor/action quiesce -> process stop 순서 |
| `kill_test.sh`, `init_cam.sh`, `cam_hard_reset.sh` | 직접 recovery 대신 synchronous forwarding wrapper |
| gstApp, ORD, VCM | wildcard/canonical source read 제거, 고정 runtime path 지원 |
| camera 관련 script | 공통 runtime resolver 사용 |
| `pim_guardian.py` | 직접 script/systemctl 대신 request interface 사용 |
| `cam-operate.service` | RuntimeDirectory/StateDirectory, control-group kill, start ordering |
| `ord-operate.service` | autonomous restart 제거, cam-operate의 `After`/`PartOf` execution unit으로 전환 |

`cam-operate.service`가 `/run/pim-camera` runtime lifetime을 소유한다. `RuntimeDirectory`가
restart 과정에서 보존되는지에 기대지 않으며 매 invocation마다 runtime을 다시 만든다.

## 12. 한 release 호환 정책

기존 command는 한 release 동안 남기되 recovery나 원본 검색을 직접 수행하지 않는다.

| 기존 진입점 | forwarding request |
|---|---|
| `kill_test.sh` / `killcam` | `gstapp_restart` |
| `init_cam.sh` | `module_reload` |
| `cam_hard_reset.sh` | `camera_hard_reset` |

wrapper는 deprecated 경고를 출력하고 synchronous wait 결과를 기존 호출자에게 전달한다.
`cam_hard_reset.sh -s -S`는 인자를 받아도 cam-operate를 stop/start하지 않는다. wrapper는
원본 또는 runtime JSON을 수정하거나 선택하지 않는다.

## 13. 오류 처리

- 최신 edgeconf가 invalid: 이전 edgeconf로 후퇴하지 않고 config request/startup 실패
- 고정 ord JSON missing/invalid: config request/startup 실패
- cam-operate 시작 config 실패: runtime을 fallback으로 사용하지 않고 consumer 시작 금지
- `apply-config` candidate validation 실패: 기존 runtime/process 유지, action 시작 전 실패
- valid candidate 교체 후 action 실패: 자동 rollback 없이 새 runtime 유지, DEGRADED 기록
- 수동 runtime invalid: `CONFIG_INVALID`, hardware recovery로 상향 금지
- owner mismatch: 외부 action 금지, interrupted history 기록
- module reload 실패: hard reset으로 한 번 상향
- hard reset 실패: top-level request당 reboot fallback 한 번
- daemon unavailable: CLI exit 69, legacy wrapper도 실패 전달
- corrupt persistent state: 덮어 숨기지 않고 진단 후 fail closed

## 14. 검증 계획

### 14.1 host 단위/통합 test

- 최신 `edgeconf_*.json` mtime 선택과 deterministic tie-break
- 최신 edgeconf invalid일 때 과거 파일로 후퇴하지 않음
- ord 전체와 edgeconf `VHL_CAM` 병합, edgeconf 우선, 추가 ord key 보존
- 임시 파일 validation과 runtime atomic rename
- 두 호환 filename이 같은 `pim_runtime.json`을 가리킴
- consumer가 `/root/shared_v` wildcard와 `/tmp/config`를 직접 읽지 않음
- 자동 recovery와 legacy wrapper가 원본을 재검색하지 않음
- runtime 수동 편집 후 선택한 test app 재시작이 편집값을 사용함
- cam-operate 재시작과 `apply-config`가 원본을 재검색해 수동 값을 덮어씀
- `apply-config` 성공이 관련 process ready까지 기다림
- semantic no-change apply가 action counter를 올리지 않음
- same-boot restart는 최소 module reload, hardware 값 변경/dirty는 hard reset
- invalid config가 module/hard-reset/reboot로 확대되지 않음
- ORD/VCM/gstApp 비정상 종료 자동 재시작 기능 유지
- APPLYING_CONFIG, RECOVERING, STOPPING, DEGRADED 중 monitor 재시작 금지
- 두 동시 request 중 하나만 accepted, 다른 하나는 BUSY/75
- pending -> active 전이에 새 request가 끼어들 수 없음
- action별 counter/history와 interrupted reconciliation의 재시작 후 persistence
- module reload 실패 -> hard reset, hard reset 실패 -> reboot fallback 한 번
- owner token/start-time mismatch fail closed
- hard reset 경로에 cam-operate systemctl stop/start/restart가 없음
- legacy wrapper mapping, warning, synchronous exit propagation

### 14.2 기존 회귀와 package gate

- `test/camera_health` 전체
- `test/cam_link` 전체, 특히 `initcam_modprobe_test.sh`
- shellcheck와 Python test/lint
- gstApp/ORD/VCM build와 runtime-path test
- package 설치 후 CLI/library 실행 권한과 systemd directory/ordering 검증
- maintainer script와 package file list 검증

### 14.3 target board 합격 기준

- 자동 app/module/hard-reset recovery 동안 cam-operate가 계속 ACTIVE
- 동시 요청에도 실제 hardware action은 하나만 실행
- same-boot cam-operate restart에서 runtime 재생성과 module/hard reset이 한 번 실행
- `apply-config`가 source 변경을 runtime과 실제 process 동작에 반영
- runtime 직접 편집 후 gstApp만 재시작하는 시험이 가능
- stop/restart stress 중 orphan `restart_app.sh`와 중복 process가 없음
- module/hard-reset failure injection과 reboot fallback 횟수가 history/counter와 일치
- 재부팅 뒤 counter/history가 유지되고 interrupted request가 한 번만 reconcile
- 전환된 `pim-check` 배포본에서 end-to-end 판정 통과

## 15. rollout과 완료 조건

1. runtime merge/validation helper와 fixture test를 먼저 추가한다.
2. cam-operate가 `/run/pim-camera/config/pim_runtime.json`을 생성하도록 전환한다.
3. 호환 symlink와 consumer 고정 경로를 함께 배포한다.
4. owner, request lease, persistent counter/history를 추가한다.
5. liveness supervisor와 recovery executor를 cam-operate에 통합한다.
6. stop ordering, systemd directory ownership, wrapper를 전환한다.
7. guardian과 config consumer inventory를 갱신한다.
8. host/package test 뒤 대상 board acceptance를 수행한다.
9. 한 release 동안 deprecated 호출을 확인한 뒤 wrapper/alias 제거 여부를 결정한다.

완료는 코드가 존재하는 것만으로 판정하지 않는다. host/package/board acceptance가 통과하고,
모든 자동 recovery가 한 owner 아래 직렬 실행되며, stop 구간에 process 재기동이 없고,
cam-operate 재시작과 `apply-config`가 원본 재검색 결과를 실제 process 동작에 반영해야 한다.

## 16. 구현 전 확인할 외부 경계

- gstApp의 config path 변경과 file open 시점은 upstream source 또는 target log로 확인하고
  binary를 함께 rebuild한다.
- target에서 `ord-operate.service`의 `After`/`PartOf`와 executor 기반 restart가 의도한
  단일 decision-owner 동작을 하는지 확인한다.
- `pim-check` source가 별도 저장소에 있으면 새 CLI/sentinel 연동을 그 저장소에서 별도
  구현·검증한다.
- systemd directive는 target Ubuntu 20.04/systemd 245에서 검증한다.
