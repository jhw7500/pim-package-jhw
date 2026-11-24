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
| 채널별 파일 수 불일치 | 파일 생성 검사 | `check_num != file_cnt`, cooldown/disconnect 아님, `retry_total > 5` | 공통 retry 카운터 초기화 |
| 초기 시작 마커 없음 | `start_f == 0` 분기 | 적어도 한 카메라 그룹이 활성, cooldown/disconnect 아님, `retry_total > 4` | 공통 retry 카운터 초기화 |
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

- `retry_total <= 3`: `gstapp_restart`
- `retry_total` 4: `module_reload`
- `retry_total` 5: `camera_hard_reset`
- `retry_total > 5`: `file_check_reboot=true`면 `reboot_fallback`, 아니면 retry 카운터 초기화

이 사다리만 이어질 때는 모듈 재적재 한 번 뒤에 CSI·ISI까지 다시 묶는 하드 리셋으로 넘어간다(#192).
2.4의 사다리와 `retry_total`을 함께 쓰므로 두 실패가 섞이면 한쪽 단계를 건너뛰거나 되풀이할 수 있다.
재부팅을 요청하는 조건은 섞여도 위와 같다.
재기동 직후 첫 조각이 아직 없고 앱이 `init_cooldown_sec`보다 어리면 파일 검사를 보류한다(#190).
모듈 재적재 뒤 쿨다운 판정은 #214에서 제거했다. disconnect가 감지되면 이 사다리 대신
disconnect 전용 주기 복구 경로에 맡긴다.

### 2.4 초기 시작 마커 없음

`/tmp/start_video_time_chk`가 비어 있고 `timer >= rst_time`인 상태가 계속될 때:

- `retry_total <= 2`: `gstapp_restart`
- `retry_total` 3: `module_reload`
- `retry_total` 4: `camera_hard_reset`
- `retry_total > 4`: `file_check_reboot=true`면 `reboot_fallback`, 아니면 retry 카운터 초기화

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
    요청을 함께 본다. `apply-config` 실패, 정지 요청, 설정 오류, ord·vcm 기동 실패로 생긴 `DEGRADED`는
    건드리지 않는다. `true`일 때는 이 재시도가 없다.
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
