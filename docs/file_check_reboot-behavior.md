# `file_check_reboot` 현행 동작 명세

> 기준: 2026-08-25 `master`. 코드 행 번호 대신 함수/변수명을 기준으로 설명한다.

`ord_vcm_conf.json`의 `.ETC.file_check_reboot`는 복구 사다리 전체를 켜고 끄는
옵션이 아니다. `gstapp_restart`, `module_reload`, `camera_hard_reset` 요청을 거친 뒤 마지막 단계에서
`reboot_fallback` 요청을 허용할지를 결정하는 공통 게이트다. 꺼져 있으면 데몬이 스스로 낸 복구 요청이
실패했을 때 실행기가 재부팅으로 넘어가는 것도 막는다(3절). 복구 사다리는 스크립트를
직접 실행하지 않고 복구 요청을 낸다(`kill_test.sh`와 `init_cam.sh`도 지금은 요청을 내는
래퍼다).

## 1. 설정과 로딩

| 항목 | 현재 값 |
|---|---|
| 런타임 JSON | `/root/shared_v/ord_vcm_conf.json` |
| 패키지 기본 JSON | `dist/pim/opt/pim/config/ord_vcm_conf.json` |
| JSON 키 | `.ETC.file_check_reboot` |
| 로컬 변수 | `file_chk_reboot` |
| 패키지 기본값 | `true` |
| 키 누락/JSON 읽기 실패 시 | `false`로 취급 |
| 활성 판정 | 값 문자열에 `true`가 포함되는지 확인 |

`GetConfig_()`는 다음과 같이 값을 읽는다.

```bash
(.ETC.file_check_reboot // false)
```

패키지의 `update_ordvcmconf.sh`는 키가 없을 때 `true`를 주입하지만,
`chk_cam_operate.sh` 자체는 누락된 키를 안전측인 `false`로 해석한다.
설정은 데몬 시작 때 읽고, `cam-recoveryctl apply-config`가 `.ETC` 변경을 반영할 때(`policy_reload`
단계) 다시 읽는다. JSON을 직접 고친 경우에는 `chk_cam_operate.sh`가 다시 시작되는 정식 카메라 재기동
절차가 필요하다.

## 2. 현재 재부팅 분기

현재 `file_check_reboot`가 제어하는 재부팅 분기는 5개다.

| 분기 | 소유 로직 | 재부팅 직전 조건 | `false`일 때 |
|---|---|---|---|
| 장기 disconnect | `maybe_init_cam_on_disconnect()` | `.ETC.disconnect_max_sec > 0`이고 disconnect가 제한시간 이상 지속 | 주기적 `module_reload` 요청만 계속 |
| 드라이버 모듈 미로딩 | 메인 루프의 `modules_loaded()` 검사 | `max9296`/`imx8_media_dev` 미로딩, disconnect 아님, `retry_total > 5` | 공통 retry 카운터 초기화 |
| 채널별 파일 수 불일치 | 파일 생성 검사 | `check_num != file_cnt`, cooldown/disconnect 아님, `retry_total > 4`, 이번 주기에 사다리가 하드 리셋을 이미 냄 | 공통 retry 카운터 초기화 |
| 초기 시작 마커 없음 | `start_f == 0` 분기 | 적어도 한 카메라 그룹이 활성, cooldown/disconnect 아님, `retry_total > 4`, 이번 주기에 사다리가 하드 리셋을 이미 냄 | 공통 retry 카운터 초기화 |
| Final-path 정체 | `CheckFinalArrival()` | `final_stall_cnt >= 5`이고 정체 가드에 걸리지 않음 | `final_stall_cnt`만 초기화 |

이 다섯 분기와 별도로, 이 설정이 꺼져 있으면 데몬이 스스로 낸 복구 요청의 실패가 실행기 안에서
`reboot_fallback`으로 올라가는 것도 막는다(3절, #192).

### 2.1 장기 disconnect

disconnect 복구의 기본 동작은 `disconnect_init_grace_sec` 이후
`disconnect_init_interval_sec` 간격으로 `module_reload`를 요청하는 것이다.

`.ETC.disconnect_max_sec`의 스크립트 기본값은 `0`이므로 재부팅 에스컬레이션은
기본적으로 비활성이다. 명시적으로 0보다 큰 값을 설정한 장비에서만 다음 조건을
모두 만족하면 재부팅한다.

- disconnect 지속시간이 `disconnect_max_sec` 이상
- `file_check_reboot=true`
- 에스컬레이션 이력 파일을 정상적으로 기록할 수 있음

기본 이력 파일은 `/tmp/cam_disconnect_reboot.flag`다. 따라서 같은 부팅에서는
한 번만 에스컬레이션하지만 재부팅하면 플래그가 사라진다. 물리 disconnect가 계속되면
다음 부팅에서 제한시간 후 다시 재부팅할 수 있다. 플래그를 쓰지 못하면 반복 재부팅을
피하기 위해 재부팅 자체를 건너뛴다.

### 2.2 드라이버 모듈 미로딩

`modules_loaded()`가 실패하고 카메라 disconnect 비트가 없을 때:

- `retry_total <= 5`: `module_reload`
- `retry_total > 5`: `file_check_reboot=true`면 `reboot_fallback`, 아니면 retry 카운터 초기화

disconnect 상태라면 이 분기에서는 retry와 reboot를 실행하지 않는다.

### 2.3 채널별 파일 수 불일치

활성 채널과 SRT 설정으로 계산한 기대 파일 수가 실제 파일 수와 다를 때:

- `retry_total <= 2`: `gstapp_restart`
- `retry_total` 3: `module_reload`
- `retry_total` 4: `camera_hard_reset`
- `retry_total > 4`: 이번 주기에 이 사다리나 2.4의 사다리가 `camera_hard_reset`을 낸 적이 없으면 먼저 한 번
  낸다. 낸 적이 있으면 `file_check_reboot=true`일 때 `reboot_fallback`, 아니면 retry 카운터 초기화

이 사다리만 이어질 때는 모듈 재적재 한 번 뒤에 CSI·ISI까지 다시 묶는 하드 리셋으로 넘어간다(#192).
단계표는 2.4의 사다리와 같고 `retry_total`을 함께 쓴다. 그래서 두 실패가 어떤 순서로 섞여도 같은 횟수에서
같은 요청이 나간다. 예전에는 이 사다리의 `gstapp_restart`가 세 번이어서 각 단계가 한 횟수씩 뒤였다.
드라이버 모듈 미로딩 사다리(2.2)도 같은 횟수를 올리는데 5까지 `module_reload`만 낸다. 그 실패가 섞여
하드 리셋 자리(4)를 건너뛴 채 한계를 넘으면, 포기(재부팅 요청이나 초기화)하기 전에 하드 리셋을 한 번 낸다.
그래서 두 사다리가 포기할 때는 그 주기에 하드 리셋 요청이 한 번 이상 나간 뒤다. 이미 하드 리셋을 거치는
순서는 바뀌지 않는다. 드라이버 모듈 미로딩 사다리(2.2)의 포기에는 이 규칙이 없다(이유는 2.7). 요청이 거부된
경우(진행 중인 요청이 있거나 owner가 `ACTIVE`가 아님)도 낸 것으로 센다.
재기동 직후 첫 조각이 아직 없고 앱이 `init_cooldown_sec`보다 어리면 파일 검사를 보류한다(#190).
모듈 재적재 뒤 쿨다운 판정은 #214에서 제거했다. disconnect가 감지되면 이 사다리 대신
disconnect 전용 주기 복구 경로에 맡긴다.

### 2.4 초기 시작 마커 없음

`/tmp/start_video_time_chk`가 비어 있고 `timer >= rst_time`인 상태가 계속될 때:

- `retry_total <= 2`: `gstapp_restart`
- `retry_total` 3: `module_reload`
- `retry_total` 4: `camera_hard_reset`
- `retry_total > 4`: 이번 주기에 이 사다리나 2.3의 사다리가 `camera_hard_reset`을 낸 적이 없으면 먼저 한 번
  낸다. 낸 적이 있으면 `file_check_reboot=true`일 때 `reboot_fallback`, 아니면 retry 카운터 초기화

모든 채널이 비활성인 경우에는 실패가 아니라 설정상 비활성으로 보고 건너뛴다.
cooldown과 disconnect 처리 원칙은 파일 수 불일치 분기와 같다.

### 2.5 Final-path 정체

`CheckFinalArrival()`은 정상 루프에서 60초마다 최종 저장 경로의 도착 진척을
확인한다.

- `final_stall_cnt` 1~2: `gstapp_restart`
- `final_stall_cnt` 3: `module_reload`
- `final_stall_cnt` 4: `camera_hard_reset`
- `final_stall_cnt` 5 이상: `file_check_reboot=true`면 `reboot_fallback`, 아니면
  `final_stall_cnt=0`

다음 경우에는 정체 재부팅 사다리에 진입하지 않는다.

- RAM-only 모드
- 모든 카메라 채널 비활성
- capture 모드에서 녹화 비활성
- init/restart/kill 진행 중
- 시작 워밍업 중
- heartbeat 또는 final 파일의 최근 도착이 확인됨

상세 상태와 진단 절차는 `docs/runbook_final_stall.md`를 참조한다.

### 2.6 복구 요청 직전의 ISP 근거 로그

2.3·2.4·2.5의 사다리는 복구 요청을 고르기 직전에 감시 로그(`local0`)에 한 줄을 남긴다(#192).

```
isp evidence before file check failure request: ch0=ok(119>134) ch1=ok(120>135) | ch2=STALL(121>121) ch3=ok(122>137)
```

드라이버의 `health_raw`(`/sys/bus/i2c/devices/2-0048`, `1-0048`)를 1초 간격으로 두 번 읽어 채널별 ISP 프레임
카운터(`hinf_count`)를 견준 것이다. `|` 앞이 `2-0048`(ch0·ch1), 뒤가 `1-0048`(ch2·ch3)이다.

| 표기 | 뜻 |
|---|---|
| `ok(전>후)` | 카운터가 움직였다. ISP는 프레임을 내고 있다 |
| `STALL(전>후)` | 카운터가 그대로다. 그 ISP가 프레임을 내지 않는다 |
| `off` | 끈 채널 |
| `link-down` | 그 채널의 링크가 내려가 있다 |
| `isp-<상태>` | 카운터를 읽지 못했다(드라이버가 보고한 ISP 상태) |
| `not-streaming` | 그 장치가 스트리밍 중이 아니다. 이때의 `STALL`은 정지의 근거가 아니다 |
| `unreadable`, `schema?`, `busy` | 그 장치의 값을 읽지 못했거나 형식이 다르거나, 드라이버가 다른 일을 하는 중이다 |
| `unavailable` | 두 장치 모두 읽지 못했다(드라이버가 올라와 있지 않음 등) |

파일 검사 실패 로그의 `miss=[...]`는 파일이 빠진 채널을 알려 줄 뿐이다. ISP 하나가 멈추면 같은 CSI의 두 채널이
함께 빠지므로, 어느 ISP가 멈췄는지와 ISP 쪽 문제인지(카운터 정지) 그 뒤 단계의 문제인지(카운터 진행)는 이
줄로 가른다. 기록 전용이다. 요청의 종류와 횟수는 이 값에 따라 달라지지 않고, 읽지 못해도 사다리는 그대로
간다. 쉬는 중인 사다리, disconnect 분기, 드라이버 모듈 미로딩 사다리(2.2)는 이 줄을 남기지 않는다. 한 번
남길 때마다 요청이 약 1.5초 늦어진다(두 읽기 사이 1초와 값 정리).

### 2.7 재부팅 전에 하드 리셋: 경로별 적용

이슈 #192 의 규칙은 "재부팅을 요청하기 전에 `camera_hard_reset`을 먼저 시도한다"이다. 복구 요청을 내는
경로마다 이 규칙이 어떻게 지켜지는지 적는다. lifecycle이 `ACTIVE`일 때의 길이다.

재부팅에 이르는 길은 둘이다.

- **사다리의 직접 요청**: 감시 데몬(`chk_cam_operate.sh`)의 사다리가 `reboot_fallback`을 요청한다.
- **실행기의 승격**: `module_reload` 요청이 실패하면 실행기가 같은 요청 안에서 `camera_hard_reset`을 하고,
  그것도 실패하면 `reboot_fallback`을 한다. `camera_hard_reset` 요청이 실패해도 `reboot_fallback`으로
  간다(`cam_operate_control.sh`의 `_coc_execute_recovery_active`). 승격은 항상 하드 리셋을 거친다.
  `gstapp_restart` 요청은 실패해도 승격하지 않는다.

| 경로 | 내는 요청 | 재부팅에 이르는 길 | 하드 리셋이 먼저인가 |
|---|---|---|---|
| 파일 수 불일치(2.3), 시작 마커 없음(2.4) | `gstapp_restart` → `module_reload` → `camera_hard_reset` → `reboot_fallback` | 사다리의 직접 요청 | 예. 그 주기에 사다리가 하드 리셋을 낸 뒤에만 요청한다 |
| Final-path 정체(2.5) | 같은 순서 | 사다리의 직접 요청 | 예. 4번째 판정이 하드 리셋이다 |
| liveness(앱 프로세스 없음, `cam_liveness.sh`) | `gstapp_restart`. 연속 실패가 5회(`PIM_CAMERA_LIVENESS_ESCALATION_THRESHOLD`)에 이르면 `module_reload` | 실행기의 승격 | 예. 직접 재부팅을 요청하지 않는다 |
| guardian(`pim_guardian.py --recovery`) | 카메라 수 불일치면 `module_reload`, heartbeat 정지면 `gstapp_restart` | 실행기의 승격 | 예. 직접 재부팅을 요청하지 않는다 |
| 드라이버 모듈 미로딩(2.2) | `module_reload` 5번 → `reboot_fallback` | 실행기의 승격, 또는 사다리의 직접 요청 | 승격은 예. 사다리의 직접 요청은 아니오 |
| 장기 disconnect(2.1, 기본 꺼짐) | 주기적 `module_reload`, 제한 시간 뒤 `reboot_fallback` | 사다리의 직접 요청 | 아니오 |

규칙을 적용하지 않는 두 곳과 그 이유는 다음과 같다.

- **드라이버 모듈 미로딩 사다리의 직접 요청.** 모듈을 올리지 못하는 고장은 이 사다리가 낸 `module_reload`가
  실패하는 것으로 나타나고, 그때는 실행기가 첫 요청에서 하드 리셋을 거쳐 재부팅한다. 사다리가 횟수 6까지
  가서 직접 재부팅을 요청하는 것은 두 경우뿐이다. 요청이 실행되지 않았거나(다른 요청이 진행 중이거나
  lifecycle이 `ACTIVE`가 아니어서 거부), 재적재가 성공으로 끝났는데도 다음 검사에서 모듈이 다시 없는
  경우다. 앞의 경우에는 하드 리셋 요청도 똑같이 거부되고, 뒤의 경우에는 하드 리셋도 같은 모듈 적재를
  하므로 얻는 것이 없다.
  - .6 실측(2026-11-25, 1.0.0.2): 모듈을 내린 시험에서 `module_reload` 요청 5번이 실행되지 않았다(1번은 다른
    요청이 진행 중, 4번은 `DEGRADED`라 거부). 횟수 6에서 낸 `reboot_fallback` 요청도 거부됐다
    (`request reboot_fallback refused: lifecycle=DEGRADED`).
  - 그 시험 전까지 .6의 감시 로그(2026-09-15~)에는 `driver module not loaded` 판정이 없었고, .4의 로그
    (2025-12-02~2026-11-25)에는 27건이 있었으나 횟수는 3을 넘지 않았다.
- **장기 disconnect의 재부팅.** 케이블이나 링크가 끊긴 상태가 `disconnect_max_sec`을 넘겼을 때만 타고,
  기본값이 0이라 꺼져 있다. 그 사이 `module_reload`가 주기적으로 이미 돈다. 하드 리셋이 재적재보다 더
  하는 일은 SoC 쪽 CSI·ISI를 다시 묶는 것이라, 끊긴 링크를 되살리지 못한다.

`DEGRADED`에서는 사다리와 liveness의 요청이 `reboot_fallback`까지 모두 거부된다
(`docs/camera-health/cam-recovery-operations.md`). `file_check_reboot`가 꺼져 있으면 데몬이 낸 요청
(출처 `monitor`, `liveness`)의 승격은 하드 리셋에서 멈춘다(3절).

## 3. 운영 해석

### `true`

- 소프트 복구가 임계 횟수를 초과하면 시스템 재부팅까지 허용한다.
- 장기 disconnect 재부팅은 `disconnect_max_sec`를 별도로 켠 경우에만 동작한다.
- 재부팅으로 진행 중인 녹화가 중단될 수 있다.

### `false` 또는 키 누락

- 사다리 마지막 단계의 `reboot_fallback` 요청을 억제한다.
- `gstapp_restart`, `module_reload`, `camera_hard_reset` 요청과 disconnect 주기 복구는 계속 동작한다.
- 데몬이 스스로 낸 복구 요청(출처가 `monitor` 또는 `liveness`: 사다리, disconnect 주기 복구, 드라이버 적재
  실패, liveness)은 실행 중에 실패해도 재부팅으로 올라가지 않는다(#192). `module_reload`가 실패하면
  `camera_hard_reset`까지는 시도하고, 그것도 실패하면 요청이 `FAILED`로 끝나고 상태가 `DEGRADED`가 된다.
  `true`일 때는 지금처럼 `reboot_fallback`까지 올라간다.
- `DEGRADED`에서는 사다리, disconnect 주기 복구, liveness의 요청이 모두 거부된다. 대신 데몬이
  `disconnect_init_interval_sec`(기본 180초, 하한 60초)마다 `camera_hard_reset`을 한 번 낸다(#192, reason
  `degraded periodic recovery`). 성공하면 `ACTIVE`로 돌아오고, 실패하면 그 실패 뒤부터 간격을 다시 재고
  또 낸다. 원인이 남아 있는 동안에는 하드 리셋이 되풀이되고, 그 사이 녹화는 멈춰 있다.
  - 이 재시도는 마지막 요청이 실패한 복구 요청(`gstapp_restart`, `module_reload`, `camera_hard_reset`)일
    때만 한다. `service-state.json`의 `degraded_target`(`camera_health` 또는 `gstapp`)과 복구 이력의 마지막
    요청을 함께 본다. `gstapp_restart`가 앱을 다시 띄운 뒤의 검증에서 실패하면 대상이 `camera_health`로
    적히는데, 그 경우도 포함한다. `apply-config` 실패, 정지 요청, 설정 오류, ord·vcm 기동 실패로 생긴
    `DEGRADED`는 건드리지 않는다. `true`일 때는 이 재시도가 없다.
  - 기다리지 않고 벗어나려면 `cam-recoveryctl request hard`를 내거나 `cam-operate` 서비스를
    재시작한다(시작 경로가 하드 리셋을 다시 시도한다). 모듈 재적재나 하드 리셋이 실패한 뒤라면
    `cam-recoveryctl apply-config`도 하드 리셋부터 돈다. 그래도 돌아오지 않으면
    `cam-recoveryctl request reboot`로 재부팅한다.
- 판정 기준은 요청의 source 값이다. source가 `monitor`나 `liveness`가 아닌 요청(`cam-recoveryctl
  request ...`의 기본값 `operator`, `pim_guardian.py --recovery`의 `pim-guardian`)은 이 설정과 무관하게,
  실패하면 `reboot_fallback`까지 올라간다. `cam-recoveryctl`에 `--source monitor`를 주면 데몬이 낸
  요청처럼 다뤄진다.
- 일반 retry 사다리는 한계에서 카운터를 초기화하고, FINAL STALL은 `final_stall_cnt`만 초기화한다.
  초기화한 뒤에는 `disconnect_init_interval_sec`만큼 쉬고 1부터 다시 센다(#192). 쉬는 동안 파일 검사,
  시작 마커, 드라이버 적재 실패, FINAL STALL 사다리는 세지도 요청하지도 않는다. disconnect 주기 복구와
  liveness는 계속 돈다. 쉬는 시간은 증상이 사라져도 줄지 않으므로, 그 안에 새로 생긴 파일 누락은 쉬는
  시간이 끝난 뒤에 다뤄진다. 쉬는 중에 설정을 `true`로 바꾸면 곧바로 풀린다.
  - MAX9296 prepare 실패로 채널이 빠진 채 뜬 앱도 쉬는 동안에는 그대로 둔다. 사다리의 마지막 단계인
    하드 리셋이 그런 기동을 남기면, 쉬는 시간만큼 그 채널이 빠진 채 있다가 쉰 뒤에 사다리가 다룬다.
    파일 검사가 이어서 실패하면 `module_reload`, `camera_hard_reset` 순으로 간다(.6 2026-11-24 실측 8주기
    모두). `module_reload` 뒤에 시작 마커 검사가 먼저 실패해도 그 자리가 `camera_hard_reset`이다(2.3).
- 하드웨어 수준 장애가 소프트 복구로 해결되지 않으면 복구 사이클이 반복될 수 있다.

## 4. 관련 구현

- `dist/pim/opt/pim/bin/chk_cam_operate.sh`
  - `GetConfig_()`
  - `maybe_init_cam_on_disconnect()`
  - `maybe_retry_degraded()`, `ladder_hold_start()`, `ladder_on_hold()`
  - `modules_loaded()` 검사 분기
  - 파일 수 불일치 및 시작 마커 검사 분기
  - `CheckFinalArrival()`
- `dist/pim/opt/pim/bin/update_ordvcmconf.sh`
- `dist/pim/opt/pim/config/ord_vcm_conf.json`
- `test/cam_link/escalation_test.sh`
- `test/cam_link/monitor_ladder_test.sh`
- `test/cam_link/ladder_hold_retry_test.sh`
- `test/camera_health/final_stall_watch_test.sh`
- `dist/pim/opt/pim/lib/cam_operate_control.sh`
  - `_coc_reboot_escalation_blocked()`
- `test/camera_health/cam_operate_control_test.sh`
- `test/cam_link/config_default_test.sh`

## 5. 운영 권장

- 정상 운영 기본값은 `true`다.
- 재부팅 없이 로그를 오래 수집해야 하는 진단 환경에서는 일시적으로 `false`를
  사용할 수 있다. 이때 하드 리셋까지 실패하면 재부팅 없이 `DEGRADED`가 되고 데몬이 주기적으로 하드
  리셋을 다시 시도한다. `cam-recoveryctl status`로 상태를 확인하고, 기다릴 수 없으면 3절의 방법으로
  바로 벗어난다.
- 장기 disconnect 재부팅은 기본 비활성이므로 필요한 장비에서만
  `disconnect_max_sec`와 플래그 보존 정책을 함께 검토해 활성화한다.
- 설정 변경 후에는 현재 JSON 값과 재기동 이후의 시작 로그에 출력되는
  `file_chk_reboot` 값을 함께 확인한다. `apply-config`로 반영한 경우에는 시작 로그가 다시 찍히지 않는다.
