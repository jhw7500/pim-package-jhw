# Camera recovery operations

## 운영 계약

`cam-operate.service`의 현재 invocation 하나가 runtime 설정, process liveness,
recovery side effect를 소유한다. gstApp 재시작, module reload, camera hard reset,
reboot fallback은 모두 같은 owner와 단일 executor 아래에서 직렬 실행된다. recovery가
성공하면 daemon lifecycle은 `ACTIVE`로 돌아오며, terminal failure만 `DEGRADED`로
남는다.

실제 camera runtime은 다음 한 파일이다.

```text
/run/pim-camera/config/pim_runtime.json
```

같은 파일을 가리키는 한 release 호환 symlink는 `edgeconf_pim.json`과
`ord_vcm_conf.json`이다. `/var/lib/pim-camera`의 상태는 systemd
`StateDirectory`이며 package upgrade, remove, purge 뒤에도 보존한다.

## 시작과 재시작

`pim-camera-config.service`는 `/root/shared_v` 접근과 필요한 도구만 확인하는 선행
guard다. runtime을 만들거나 소유하지 않는다. 이어서 systemd가
`/run/pim-camera`와 `/var/lib/pim-camera`를 준비하고 `cam-operate.service`를
시작한다.

새 cam-operate invocation은 항상 다음 순서로 동작한다.

1. 새 owner tuple을 만들고 lifecycle을 `STARTING`으로 둔다.
2. `/root/shared_v`에서 mtime과 bytewise path 순서로 최신 regular
   `edgeconf_*.json`을 다시 찾고, 고정 `ord_vcm_conf.json`과 병합한다.
3. `VHL_CAM`, `ORD`, `VCM` object를 검증하고 runtime을 원자적으로 교체한다.
4. 새 boot에서는 initial module load를 수행한다. 같은 boot의 service restart는
   consumer를 다시 시작하고 최소 `module_reload`를 수행한다. 저장된 hardware
   projection이 바뀌었거나 없거나 dirty이면 `camera_hard_reset`을 수행한다.
5. readiness 검증 뒤 `ACTIVE`로 전이한다.

**`systemctl is-active`가 `active`인 것은 5단계가 끝났다는 뜻이 아니다.** 유닛의
`ExecStartPost`는 runtime JSON이 validate되기까지만 기다리므로, 그 시점 owner는 아직
`STARTING`이거나 4단계의 `module_reload`를 돌고 있어 `RECOVERING`일 수 있다. 제출은
`ACTIVE`/`DEGRADED`에서만 받으므로 기동 직후 바로 요청하면 69 또는 75로 거절된다 — 그것을
hardware 문제로 오진하기 쉽다.

따라서 `systemctl start`/`restart` 뒤에 명시적 recovery를 요청해야 하면 먼저 owner가 받을
상태인지 확인한다.

```bash
/opt/pim/bin/cam-recoveryctl status | jq -r '.owner.lifecycle'   # ACTIVE 또는 DEGRADED
/opt/pim/bin/cam-recoveryctl status | jq -c '.pending, .active'  # 둘 다 null
```

**대개는 기다릴 필요조차 없다** — 같은 boot의 restart는 4단계에서 최소 `module_reload`를
스스로 수행하므로(`cam_operate_control.sh`의 `cam_startup_request_reserve`) 별도 요청이
불필요하다. 2026-10-03 설치 실측: `start` 직후 unit은 `active`, owner는 `RECOVERING`,
`active`에 `type=module_reload source=startup`. 그 요청이 적재 모듈을 교체하고 약 10초 뒤
`ACTIVE`로 수렴했다.

따라서 `systemctl restart cam-operate.service`는 새 invocation이다. 기존 runtime의
수동 편집값을 입력이나 fallback으로 사용하지 않고 source를 다시 검색해 덮어쓰며,
consumer를 다시 시작하고 위 reset 정책을 적용한다. source가 없거나 최신 source가
invalid이면 이전 파일로 후퇴하지 않고 시작에 실패한다.

## 설정 적용

source 변경을 실행 중 daemon에 반영하려면 다음 요청을 사용한다.

```sh
cam-recoveryctl apply-config --source operator --reason "approved source update" --wait 300
```

`apply-config`는 현재 owner를 유지하면서 `/root/shared_v`를 다시 검색하고 candidate를
검증한 뒤 runtime을 원자적으로 교체한다. 이어서 변경 영역에 필요한 consumer/reset
동작과 final readiness 검증을 수행한다. runtime 결과를 source JSON에 쓰지 않으며,
어떤 runtime 직접 편집도 `/root/shared_v`로 역반영하지 않는다.

| 변경 영역 | 즉시 적용 동작 |
| --- | --- |
| `VHL_CAM` hardware field | `camera_hard_reset` 후 gstApp, ORD, VCM 재기동 |
| `VHL_CAM` non-hardware field | gstApp, ORD, VCM 재기동 |
| `ORD` | ORD 재기동 |
| `VCM` | VCM 재기동 |
| cam-operate가 소비하는 `ETC` | 현재 invocation의 policy reload |
| script-only 추가 key | 즉시 action 없음; 다음 script 실행부터 새 값 사용 |

여러 영역이 바뀌면 동작의 합집합을 한 transaction에서 각각 한 번만 실행한다. valid
candidate publish 뒤 action이 실패하면 새 runtime을 유지하고 `DEGRADED`로 전이하며
자동 rollback하지 않는다.

## 명시적 recovery와 상태 조회

지원 action은 `gstapp_restart`, `gstapp_stop`, `module_reload`, `camera_hard_reset`,
`reboot_fallback`이다.

`gstapp_stop`은 gstApp과 BG_Check를 정지시키고 부재를 확인하는 것까지만 한다 —
SIGTERM 후 `PIM_CAMERA_QUIESCE_TIMEOUT_SEC`까지 대기하고, 남아 있으면 SIGKILL 후 다시
대기해 부재를 확인한다. 다시 띄우지는 않는다. `cam_liveness_tick`이 이후 순회에서
gstApp 부재를 보고 `source=liveness`로 `gstapp_restart`를 스스로 제출한다. 따라서 이
요청의 rc 0은 "확인 시점에 부재"이고 "다시 실행 중"이 아니다. 재기동 결과는 그
liveness 요청에서 조회한다. 재기동은 무조건이 아니다 — `cam_liveness_gstapp_gate`가
enable된 채널, disconnect 없음, video 노드, 응답하는 subdev를 요구하므로 게이트가 닫히면
`chk_cam_operate.sh`의 자체 래더가 뜰 때까지 앱은 내려간 채 남는다 (이슈 #113).

**앱을 내려간 채로 두는 용도가 아니다.** `cam_monitor_control_iteration`은 이 요청을
끝내고 owner를 진입 시점 lifecycle로 되돌린 뒤, **같은 iteration 안에서** 그 lifecycle을
다시 읽고 `cam_liveness_tick`을 부른다. 즉 재기동은 정지가 SUCCEEDED를 보고한 바로 그
iteration에 제출되며 확실히 내려가 있는 구간이 없다. 바이너리 교체처럼 앱이 내려가
있어야 하는 작업은 `cam_operate_stop.sh`(owner를 STOPPING으로)를 쓴다.

`gstapp_stop`은 escalation counter를 쓰지 않는다. `state.json`의 action 카운터는
`gstapp_restart`, `module_reload`, `camera_hard_reset`, `reboot_fallback` 네 개로
유지되며, 정지는 history에 `countered:false`로만 남는다.

정지는 `service-state.json`도 건드리지 않는다. 다른 action은 `_coc_verify_all`이 카메라
정상을 증명한 뒤 `_coc_persist_success`로 `dirty`·`degraded_reason`·
`last_successful_hardware_projection`을 다시 쓰지만, 정지의 성공 조건은 프로세스 부재뿐이라
하드웨어에 대해 아무것도 증명하지 않는다. 따라서 DEGRADED인 owner는 DEGRADED로 남고
다음 부팅 계획(`cam_plan_startup_action`)도 바뀌지 않는다.

```sh
cam-recoveryctl request gstapp_restart --source operator --reason "gstApp test restart" --wait 120
cam-recoveryctl request gstapp_stop --source operator --reason "stop gstApp before it is relaunched" --wait 120
cam-recoveryctl request module_reload --source operator --reason "camera module recovery" --wait 300
cam-recoveryctl request camera_hard_reset --source operator --reason "approved hardware reset" --wait 300
cam-recoveryctl status --json
cam-recoveryctl status --request-id 01234567-89ab-cdef-0123-456789abcdef --json
```

`reboot_fallback`은 보통 executor의 terminal fallback으로만 사용한다. 실제 reboot가
허용된 maintenance window가 아니면 수동 요청하지 않는다.

한 pending 또는 active lease가 있으면 다음 요청은 queue되지 않고 `BUSY`/75로 즉시
종료한다. `--wait` timeout은 기다리는 CLI만 124로 종료하며 실행 중 action을 취소하지
않는다. terminal 결과는 항상 같은 key 순서를 갖는다.

```text
CAM_RECOVERY_RESULT id=01234567-89ab-cdef-0123-456789abcdef type=module_reload status=SUCCEEDED rc=0
CAM_RECOVERY_RESULT id=01234567-89ab-cdef-0123-456789abcdef type=module_reload status=FAILED rc=70
```

`--wait`로 기다리는 호출자는 위 terminal 결과를 받기 전에 stderr로 제출 통지 한 줄을
먼저 받는다. 진행 상황 보고일 뿐이며 **stdout contract가 아니다** — stdout은 terminal
`CAM_RECOVERY_RESULT` 한 줄만 갖는다. `--wait` 없이 제출하면 이 줄은 찍히지 않고
stdout으로 request id만 나온다.

```text
CAM_RECOVERY_SUBMITTED id=01234567-89ab-cdef-0123-456789abcdef type=gstapp_stop (waiting up to 120s)
```

제출 자체가 거절되면 이 줄도 terminal 결과도 찍히지 않는다. **stdout은 비어 있고,
판정은 아래 표의 exit code로만 한다.** 정상 owner 상태에서의 `BUSY`/75 거절은 stderr도
비어 있지만 그것이 모든 거절 경로의 계약은 아니다 — 예를 들어 owner 문서가 파싱되지
않으면 rc 69와 함께 jq 진단이, recovery 디렉터리에 쓸 수 없으면 rc 70과 함께 mktemp
오류가 stderr로 나온다. 거절 시 stderr에 라이브러리 진단이 실려 나올 수 있으므로,
**stderr가 비었는지로 거절 여부를 판단하지 않는다.**

| exit code | 의미 |
| ---: | --- |
| 0 | 요청 접수 또는 기다린 action 성공 |
| 64 | 잘못된 action/argument 또는 runtime syntax/schema 오류 |
| 69 | daemon/service unavailable. 같은 코드가 두 경우 더 쓰인다 — `status --request-id`의 "terminal 결과가 아직 없음", 그리고 owner lifecycle이 제출을 받을 상태가 아닐 때의 제출 거절 |
| 70 | 내부 state/storage 오류. **owner-stale 종결도 같은 코드를 쓴다** — `status=FAILED rc=70` 만으로는 둘을 구분할 수 없고, stale 판정에는 요청 이력의 `interrupted=true` 와 `interrupted_reason="owner_stale"` 이 필요하다. `CAM_RECOVERY_RESULT` 한 줄은 그 두 필드를 담지 않는다 |
| 75 | 다른 request가 pending/active인 `BUSY`; queue 없음 |
| 124 | wait timeout; action은 취소되지 않음 |

## 수동 runtime 시험 예외

일시적인 app 시험에 한해 runtime을 같은 directory의 candidate로 편집하고 검증한 뒤
rename으로 원자 교체할 수 있다.

```sh
runtime=/run/pim-camera/config/pim_runtime.json
candidate=/run/pim-camera/config/.manual-runtime.$$
install -m 0640 "$runtime" "$candidate"
${EDITOR:-vi} "$candidate"
/opt/pim/bin/camera_runtime_config.py validate --file "$candidate"
mv -f "$candidate" "$runtime"
cam-recoveryctl request gstapp_restart --source operator-manual-test --reason "consume temporary runtime" --wait 120
```

선택한 app만 다시 시작하므로 다른 app은 이전 값을 memory에 보유할 수 있다. 이 mixed
in-memory 상태는 이 수동 시험에서만 허용한다. 다음 성공한 `apply-config` 또는
cam-operate restart는 source에서 runtime을 다시 만들어 수동 편집을 폐기한다. 영구 변경은
source JSON을 별도 변경 절차로 수정해야 한다.

## 영속 상태와 장애 판정

- service owner와 pending/active/result lease: `/run/pim-camera`
- 마지막 성공 hardware projection과 dirty/degraded 상태:
  `/var/lib/pim-camera/service-state.json`
- action별 attempted/succeeded/failed/consecutive counter:
  `/var/lib/pim-camera/recovery/state.json`
- request/action history: `/var/lib/pim-camera/recovery/history/<request-id>.json`

action의 **소요 시간은 별도 필드로 저장하지 않는다.** history의 terminal action 레코드가
`started_at`과 `finished_at`을 담으므로 소요 시간은 그 차로 구한다:

```
jq '[.actions[] | {action, status,
      sec: (if .finished_at then .finished_at - .started_at else null end)}]' <history-file>
```

`finished_at`을 조건부로 다루는 것이 중요하다. 중단된 이력은 `finished_at`이 **없는** RUNNING
레코드를 담을 수 있고(`cam_recovery.sh:350`의 `public_running` — 키가
`["action","request_id","started_at","status"]`뿐이며 `:363`이 interrupted 이력에서 이를 허용한다),
그 레코드에 뺄셈을 그대로 적용하면 jq가 `null and number cannot be subtracted`로 중단된다.
즉 조사가 가장 필요한 순간에 아무 값도 못 얻는다. 위 형태는 종료된 action의 초와 진행 중이던
action의 `null`을 함께 보여 준다.
`state.json`의 키 집합에 필드를 더하면 이미 배포된 보드의 파일이 `_cr_state_valid`에서
거부되므로, 파생 가능한 값을 위해 그 위험을 지지 않는다(이슈 #61 요구 4에 대한 결정).

`errno`는 어디에도 수집하지 않는다. 실패는 action의 `rc`와 journal의 실패 단계 이름
(`action FAILED: <action> rc=<rc> step=<step>`)으로 판정한다. 드라이버 수준 `errno`
(예: `MAX9296_PREPARE -ESTALE`)가 필요하면 커널 로그를 직접 본다 — 단, 링버퍼는
wrap 되므로(실측 약 38분) 사후 조회로는 놓칠 수 있다.

성공한 recovery는 owner PID/invocation을 바꾸지 않고 lifecycle을 `ACTIVE`로 복귀시킨다.
terminal action 실패, post-publish readiness 실패, 또는 복구 불가능한 state 오류는 진단과
history를 남기고 `DEGRADED`로 전이한다. `DEGRADED`에서는 임의 liveness restart가 금지되며
operator가 status/history를 확인한 뒤 명시적 recovery 또는 `apply-config`를 수행한다.

runtime 정책에는 config SHA, digest, immutable generation, runtime manifest가 없다.
hardware 변경 판단은 정규화된 JSON value projection으로만 수행한다. package의 binary
integrity manifest는 build/deploy 검증 자료일 뿐 runtime 선택이나 recovery에 참여하지
않는다.

## 한 release 호환 명령

아래 wrapper는 deprecated 경고를 출력하고, 기본적으로 동기 요청 결과를 그대로 반환한다.

| 기존 명령 | 전달 action | 기본 `--wait` |
| --- | --- | ---: |
| `kill_test.sh` / `/usr/local/bin/killcam` | `gstapp_stop` (재기동은 cam-operate) | 120 |
| `init_cam.sh` | `module_reload` | 300 |
| `cam_hard_reset.sh` | `camera_hard_reset` | 300 |
| `restart_app.sh` | `gstapp_restart` 한 번; 독립 loop 없음 | 120 |
| `start_cam.sh` / `/usr/local/bin/startcam` | `gstapp_restart` | 120 |

wrapper는 source 검색, runtime 수정, 직접 process/reset 동작을 하지 않는다.

### `kill_test.sh`(killcam)의 생산 호출자 두 곳

둘 다 인자 없이, 즉 블로킹으로 부른다.

| 호출자 | liveness 억제 | 반환 rc 0의 의미 |
| --- | --- | --- |
| `dist/pim/opt/pim/bin/cam_disable.sh` | 있음 — 호출 전 `touch /tmp/init_cam_flag`로 `_cl_handle_operation_flags`가 tick을 건너뛴다 | 정지 완료이며, 재기동이 끼어들지 않으므로 뒤따르는 `rmmod`가 디바이스를 잡고 있지 않다 |
| `ord/tcpServer.cpp` (`CAM_RESET_FILE`, `ord/tcpServer.h`) | **없음** | **정지 완료일 뿐 카메라가 돌아왔다는 뜻이 아니다** |

ord 쪽은 `CMD_TIMESETTING_BLACKBOX` 처리 중 `_TOrdConf.rtc_reset`(기본 `true` — struct
초기화와 배포 `ord_vcm_conf.json` 양쪽)일 때 이 wrapper를 동기 실행하고, nonzero면 핸들러를
중단한다. wrapper가 `gstapp_restart`를 보내던 동안 그 rc 0은 "gstApp이 다시 떴다"였지만 이제는
"정지됐다"이다. 재기동은 cam-operate의 liveness가 같은 iteration에 제출하며
`cam_liveness_gstapp_gate`가 닫혀 있으면 제출되지 않으므로, RTC-set 응답은 **정지 완료를
근거로** 전송된다. 이슈 #113에서 의도적으로 채택한 동작이다 — ord를 blocking
`gstapp_restart`로 돌리는 대안은 별도 빌드 산출물인 ord의 외부 프로토콜 의미를 바꾸므로
이 변경의 범위를 넘는다. `ord_vcm_conf` 설정 문서의 `rtc_reset` 설명 갱신은 이 저장소의
tribunal 범위 규칙(라운드 1 `initial_paths`) 때문에 이 변경에 담을 수 없어 후속으로 남긴다.

이 문단과 위 표는 **운영자가 직접 부르는 forwarding 경로**에만 해당한다. `start_cam.sh`는
예외적으로 두 역할을 겸한다 — executor가 `PIM_CAMERA_EXECUTOR=1`로 부르면 forwarding 분기를
건너뛰고 runtime 문서를 읽어 gstApp과 BG checker를 직접 기동한다. 그 경로는 deprecated 경고도
출력하지 않고 request 결과도 반환하지 않는다. `test/camera_health/runtime_consumer_path_test.py`가
이 파일만 다른 boundary(`PIM_CAMERA_RUNTIME_JSON`)로 분류하는 이유다.

### `--no-wait`

다섯 wrapper 모두 `--no-wait`를 받는다. 이 모드에서는 `--wait`를 전달하지 않으므로
**동기 결과를 반환하지 않는다** — request를 제출한 즉시 request UUID를 출력하고 exit 0
한다. 따라서 **wrapper의 exit 0은 action 성공을 뜻하지 않으며**, 그 뒤 action이
`FAILED`로 끝나도 호출자는 알 수 없다. action 결과가 필요하면 `--no-wait` 없이 쓴다.

진행 중 확인은 **인자 없는 `cam-recoveryctl status`**로 한다. `status --request-id <UUID>`는
terminal 결과 파일만 읽으므로(`cam_recovery.sh`의 `cam_recovery_status_json`), request가
PENDING/ACTIVE인 동안에는 출력 없이 **69**로 끝난다. 이 69는 위 exit code 표의
"daemon/service unavailable"이 아니라 **"아직 결과가 없다"**는 뜻이다 — 두 경우가 같은 코드를
쓴다. action이 도는 내내 그러므로, 이때 cam-operate를 재시작하면 안 된다.

**두 번째 호출은 제출되지 않는다.** 위 "한 pending 또는 active lease" 규칙과 exit code
표대로 queue는 없고 pending slot은 하나뿐이다. 앞 request가 pending 또는 active인 동안
`--no-wait`를 다시 부르면 아무것도 제출하지 않는다. 반복 호출하는 운용에서 이 거절은 실패가
아니라 "앞 요청이 아직 처리 중"이라는 정상 응답이며, **앞 action이 끝날 때까지 계속 그렇다.**
그 길이는 wrapper의 `--wait` 기본값(120/300초)과 무관하다 — 위에 적힌 대로 wait timeout은
기다리는 CLI만 124로 종료할 뿐 실행 중 action을 취소하지 않으므로, 거절이 300초를 넘겨
계속되는 것은 정상이다.

**거절 시 exit code는 owner lifecycle에 따라 갈린다.**

| owner lifecycle | 거절 시 exit code |
| --- | ---: |
| `ACTIVE`, `DEGRADED`, `RECOVERING` | **75** (`BUSY`) |
| 그 외 — 특히 `apply-config` 트랜잭션 중의 `APPLYING_CONFIG` | **69** |

`cam_request_submit`(`cam_recovery.sh`)이 pending/active를 확인한 뒤 lifecycle 검사를 먼저
통과해야 75를 돌려주기 때문이다. 따라서 **69는 세 가지 뜻을 공유한다** — daemon 부재,
`status --request-id`의 "아직 결과 없음", 그리고 여기의 "lifecycle이 제출을 받을 상태가
아님". 어느 경우에도 cam-operate 재시작이 답이 아니다. 무엇인지는 인자 없는
`cam-recoveryctl status`의 `owner.lifecycle`로 구분한다.

기본 `--wait` 값은 의도적으로 유지한다. 낮추면 정상 성공하는 복구가 timeout(124)으로
끊긴다 — 근거 측정은 issue #109에 있다.

`start_cam.sh`는 위치 인자 `[delay]`도 받으므로 숫자가 아닌 인자는 rc 64로 거부한다.
나머지 넷은 각자의 기존 플래그 외의 인자를 rc 64로 거부한다. 어느 쪽도 인식하지 못한
인자를 조용히 무시하지 않는다.

## 외부 integration 경계

별도 source/deployment의 `pim-check`가 새 request, sentinel, exit-code 계약을 소비하도록
변경되었는지는 이 package 변경의 완료 범위가 아니다. 해당 외부 구현과 배포본을 별도로
갱신하고 end-to-end 검증하기 전에는 `pim-check` integration이 완료됐다고 판단하지 않는다.
