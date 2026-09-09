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

지원 action은 `gstapp_restart`, `module_reload`, `camera_hard_reset`,
`reboot_fallback`이다.

```sh
cam-recoveryctl request gstapp_restart --source operator --reason "gstApp test restart" --wait 120
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

| exit code | 의미 |
| ---: | --- |
| 0 | 요청 접수 또는 기다린 action 성공 |
| 64 | 잘못된 action/argument 또는 runtime syntax/schema 오류 |
| 69 | daemon/service unavailable |
| 70 | 내부 state/storage 오류 |
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

성공한 recovery는 owner PID/invocation을 바꾸지 않고 lifecycle을 `ACTIVE`로 복귀시킨다.
terminal action 실패, post-publish readiness 실패, 또는 복구 불가능한 state 오류는 진단과
history를 남기고 `DEGRADED`로 전이한다. `DEGRADED`에서는 임의 liveness restart가 금지되며
operator가 status/history를 확인한 뒤 명시적 recovery 또는 `apply-config`를 수행한다.

runtime 정책에는 config SHA, digest, immutable generation, runtime manifest가 없다.
hardware 변경 판단은 정규화된 JSON value projection으로만 수행한다. package의 binary
integrity manifest는 build/deploy 검증 자료일 뿐 runtime 선택이나 recovery에 참여하지
않는다.

## 한 release 호환 명령

아래 wrapper는 deprecated 경고를 출력하고 동기 요청 결과를 그대로 반환한다.

| 기존 명령 | 전달 action |
| --- | --- |
| `kill_test.sh` / `/usr/local/bin/killcam` | `gstapp_restart` |
| `init_cam.sh` | `module_reload` |
| `cam_hard_reset.sh` | `camera_hard_reset` |
| `restart_app.sh` | `gstapp_restart` 한 번; 독립 loop 없음 |

wrapper는 source 검색, runtime 수정, 직접 process/reset 동작을 하지 않는다.

## 외부 integration 경계

별도 source/deployment의 `pim-check`가 새 request, sentinel, exit-code 계약을 소비하도록
변경되었는지는 이 package 변경의 완료 범위가 아니다. 해당 외부 구현과 배포본을 별도로
갱신하고 end-to-end 검증하기 전에는 `pim-check` integration이 완료됐다고 판단하지 않는다.
