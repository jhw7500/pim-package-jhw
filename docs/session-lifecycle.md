# 세션 라이프사이클과 파일 처리

> 기준: 2026-08-25 `master`. 변하기 쉬운 행 번호 대신 파일과 심볼을 기준으로
> 설명한다.

이 문서는 gstApp/vcm의 세션 완료 마커와
`dist/pim/opt/pim/bin/chk_cam_operate.sh`의 파일 이동, 유지보수, 복구 로직을
연결해서 설명한다.

## 1. 세 가지 독립 신호

| 신호 | 목적 | 실패 시 결과 |
|---|---|---|
| 파일 생성 검사 | 현재 녹화 파이프라인의 생존 확인 | kill/init/reboot 복구 사다리 |
| 세션 완료 마커 `all_done` | 닫힌 세션을 안전하게 final 경로로 commit | 이동 지연, stale 처리 또는 FINAL STALL |
| Final-path heartbeat | 실제 final 도착 진척 확인 | 별도 FINAL STALL 복구 사다리 |

파일 생성이 정상이어도 `all_done`이나 파일 이동이 막히면 final 도착만 멈출 수
있다. 따라서 세 신호를 하나의 상태로 해석하면 안 된다.

## 2. 세션 마커 계약

### 2.1 파일과 생성자

| 파일 | 생성자 | 의미 |
|---|---|---|
| `/tmp/session_<ts>.video_done` | gstApp `muxSinkBin.cpp` | 해당 분의 활성 영상 채널 fragment close 완료 |
| `/tmp/session_<ts>.srt_done` | vcm `tcpServer.cpp` | 해당 분의 SRT 처리 완료 |
| `/tmp/session_<ts>.all_done` | gstApp 또는 vcm의 `mark_session_complete()` | commit 가능한 세션 |

`<ts>` 형식은 `YYYYMMDD_HHMM`이다.

gstApp의 `check_and_mark_all_done()` 판정은 다음과 같다.

- `video_done`은 항상 필요하다.
- SRT가 활성화되어 있으면 `srt_done`도 필요하다.
- SRT가 비활성화되어 있으면 `video_done`만으로 완료할 수 있다.

vcm은 SRT가 활성화된 경우 `srt_done`을 만들고
`check_and_mark_all_done()`을 호출한다. 시작 또는 resync 직후
`prefixFileName`이 비어 있으면 현재 시각에서 `recording_time`만큼 뺀
세션 ID를 계산해 bootstrap한다.

`mark_session_complete()`은 idempotent하다. `all_done`이 이미 있으면 다시
만들지 않고 남은 부분 마커만 정리한다.

### 2.2 `srt_enable` 계약

- vcm 초기값: `FALSE`
- gstApp parser: 파일/키를 읽지 못하면 `FALSE`
- `chk_cam_operate.sh`: `(.VCM.srt_enable // false)`
- 패키지 기본 `ord_vcm_conf.json`: `true`

운영 파일 `/root/shared_v/ord_vcm_conf.json`에는 `true` 또는 `false`를
명시해야 한다. 누락은 세 컴포넌트에서 비활성으로 해석된다. 과거 일회성
`audit_srt_enable.sh`와 `migrate_srt_enable.sh`는 제거되었으므로 현재
설정 배포 절차를 사용한다. 값을 바꾸면 vcm과 gstApp을 포함한 카메라
파이프라인을 재기동한다.

## 3. 정상 commit 흐름

메인 루프는 `/tmp/session_*.all_done`이 있을 때만
`ProcessCompletedSessions()`을 호출한다.

1. 현재 분과 같은 세션은 아직 기록 중일 수 있으므로 다음 루프로 미룬다.
2. `tmp_path`와, 경로가 다르면 `sd_tmp_path`를 함께 스캔한다.
3. 해당 세션의 `.part`, `.mp4`, `.ts`, `.srt`, `-vib.bin`을
   `MovePartFile()`로 처리한다.
4. 모든 파일 처리가 성공하면 `all_done`을 삭제한다.
5. 하나라도 실패하면 마커를 유지해 다음 루프에서 재시도한다.

`MovePartFile()`은 commit 직전에 SD 상태를 다시 확인한다.

- Stage 1: 입력이 `tmp_path`에 있고 `tmp_path != sd_tmp_path`이면
  `sd_tmp_path`로 copy, sync 후 원본 삭제
- Stage 2: `final_path`로 move하고 `.part` 확장자 제거
- 성공: `/tmp/cam_last_final_ts`에 현재 epoch 기록

SD가 BAD이거나 `/tmp/sd_write_disabled`가 있으면
`apply_storage_mode_overrides()`가 RAM-only 경로로 바꾼다.

## 4. `all_done`이 없을 때

`all_done`이 없으면 정상 commit 이벤트는 발생하지 않는다. 대신 정상
steady-state에서 60초마다 다음 유지보수 블록이 실행된다.

```text
apply_storage_mode_overrides
CleanupStalePartFiles
CleanupOrphanMarkers
CheckDiskSpace
CheckFinalArrival
```

복구 동작이 timer를 초기화하는 동안에는 실제 호출 간격이 더 길어질 수 있다.

### 4.1 Stale `.part`

`CleanupStalePartFiles()`은 파일 mtime이 아니라 여러 유지보수 호출 사이의
크기 변화를 추적한다.

- 최근 세션과 `all_done`이 있는 세션은 보호한다.
- gstApp 시작 초가 `00`이 아닌 첫 짧은 fragment도 보호한다.
- `tmp_path`의 인식 가능한 stale 파일은 삭제한다.
- `sd_tmp_path`의 stale 파일은 삭제하지 않고 `MovePartFile()`로 복구를
  시도하며, 실패하면 다음 시도를 위해 유지한다.
- 파일명에서 세션 ID를 인식하지 못한 `tmp_path` 파일은 삭제하지 않는다.

현재 기본 계산은 `STABLE_WINDOW_SEC=120`,
`MAINTENANCE_INTERVAL_SEC=30`으로 4회의 크기 불변 호출을 요구한다. 하지만
메인 유지보수 호출은 60초 주기이므로 기본 steady-state에서 실제 stale 처리는
첫 관측 후 약 4분이 걸린다. 이는 현재 코드의 실효 동작이며 단순히 “120초 후
삭제”로 보면 안 된다.

### 4.2 고아 부분 마커

`CleanupOrphanMarkers()`은 짝이 없는 `video_done` 또는 `srt_done`을
정리한다.

- 현재 분은 보호한다.
- 짝 마커나 `all_done`이 있으면 정상 처리 중으로 보고 유지한다.
- 제한시간은 `recording_time * 3`분이며 최소 2분, 최대 30분이다.

### 4.3 대표 결과

| 상황 | 결과 |
|---|---|
| 정상 완료 | `all_done` 기반 commit |
| gstApp/vcm 중 한쪽 마커 누락 | 부분 마커가 남고, 제한시간 후 고아 정리 |
| `tmp_path`에 완료되지 않은 stale part | 보호 조건이 아니면 삭제 가능 |
| Stage 1 후 중단되어 `sd_tmp_path`에 남음 | final 경로로 복구 시도 |
| fragment는 계속 생성되지만 commit 정지 | FINAL STALL이 감지하고 복구 사다리 실행 |

## 5. 파일 생성 검사

파일 생성 검사는 세션 commit과 별개다.

### 5.1 채널별 파일 수 불일치

`/tmp/start_video_time_chk`의 시각에서 `file_check_delay`가 지난 뒤 활성
채널과 SRT 설정으로 기대 파일 수를 만들고 실제 파일 수와 비교한다.

- `retry_total` 1~3: `kill_test.sh`
- `retry_total` 4~5: `init_cam.sh`
- `retry_total` 6 이상: `file_check_reboot=true`면 reboot

성공하면 `retry`, `retry_boot`, `retry_total`과 `/tmp/file_check`를
정상 상태로 되돌린다. init cooldown 또는 disconnect 중에는 이 사다리를 그대로
진행하지 않는다.

### 5.2 초기 시작 마커 없음

`/tmp/start_video_time_chk`가 비어 있고 `timer >= rst_time`이면 초기 시작
실패로 본다. `rst_time`은 카메라 그룹 구성에 따라 기본 25초 또는 35초다.

- `retry_total` 1~2: `kill_test.sh`
- `retry_total` 3~4: `init_cam.sh`
- `retry_total` 5 이상: `file_check_reboot=true`면 reboot

모든 카메라 채널이 비활성인 경우에는 실패로 보지 않는다.

드라이버 미로딩과 선택적 장기 disconnect 재부팅까지 포함한 전체 5개 재부팅
분기는 `docs/file_check_reboot-behavior.md`를 참조한다.

## 6. Final-path 정체 감시

`CheckFinalArrival()`은 `/tmp/cam_last_final_ts`의 age를 우선 확인한다.
heartbeat가 없거나 stale이면 설정된 final 경로의 최근
`${vhl_name}_*` 파일을 fallback으로 찾는다.

- 검사 윈도우: `max(recording_time * 2, 2)`분
- 워밍업:
  `recording_time*60*2 + file_check_delay + startup_grace_extra_sec`
- 기본 `recording_time=1`분일 때 워밍업: 140초
- 결과: `/tmp/cam_final_health`

가드와 복구 사다리:

| 상태/횟수 | 결과 |
|---|---|
| RAM-only | `RAM_ONLY`, 검사 제외 |
| 모든 채널 또는 capture 녹화 비활성 | `REC_DISABLED` |
| init/restart/kill 중 | `BUSY` |
| 워밍업 중 | `WARMUP` |
| 최근 도착 확인 | `OK` 또는 `OK_FB` |
| `stall_cnt` 1~2 | `STALL`, `kill_test.sh` |
| `stall_cnt` 3~4 | `STALL`, `init_cam.sh` |
| `stall_cnt` 5 이상 | `file_check_reboot=true`면 reboot, 아니면 카운터 초기화 |

상세 진단은 [runbook_final_stall.md](./runbook_final_stall.md)를 참조한다.

## 7. 저장공간 보호

### SD

- 기본 경고 임계치: 95%
- 기본 위기 임계치: 98%
- 위기 시 `/tmp/sd_write_disabled`를 만들고 RAM-only로 전환
- hard-cap 상황에서는 보호 세션을 우회해 가장 오래된 fragment부터 제거할 수 있음

### RAM-only

- 기본 final 경로: `/dev/shm/recordings`
- 기본 soft cap: 1.6GiB
- 기본 hard cap: 2.0GiB
- SD가 회복되면 `CheckDiskSpace()`가 RAM backlog를 SD로 backfill한 뒤 설정
  경로를 복원

## 8. 런타임 파일 계약

### 세션과 진척

| 파일 | 소유자 | 의미 |
|---|---|---|
| `/tmp/session_*.video_done` | gstApp | 영상 완료 부분 마커 |
| `/tmp/session_*.srt_done` | vcm | SRT 완료 부분 마커 |
| `/tmp/session_*.all_done` | gstApp/vcm | commit 트리거 |
| `/tmp/session_debug.log` | gstApp | fragment close 디버그 로그 |
| `/tmp/cam_last_final_ts` | `MovePartFile()` | 마지막 final 도착 epoch |
| `/tmp/cam_final_health` | `CheckFinalArrival()` | `<status> <metric> <window_min> <epoch>` |

### 라이브니스와 복구

| 파일 | 소유자 | 의미 |
|---|---|---|
| `/tmp/file_check` | `chk_cam_operate.sh` | 파일 생성 검사 `OK`/`NG` |
| `/tmp/start_video_time_chk` | gstApp | 현재 녹화 시작 시각 |
| `/tmp/init_cam_flag` | `init_cam.sh` | 초기화 진행 중 |
| `/tmp/restart_flag` | 재시작 스크립트 | 앱 재시작 진행 중 |
| `/tmp/kill_flag` | `kill_test.sh` | 종료 진행 중 |
| `/tmp/recover_req_init_cam` | Guardian 등 | init 요청 |
| `/tmp/bg_chk_flag.bin` | `BG_Check_for_pim.sh` | disconnect bitmap |
| `/tmp/cam_state/*` | 공통 `cam_state.sh` | 카메라 상태 저장소 |

### 저장공간과 유지보수

| 파일 | 소유자 | 의미 |
|---|---|---|
| `/dev/shm/sd_mount_flag` | SD automount | 0=BAD, 1/2=OK |
| `/tmp/sd_write_disabled` | retention | SD 쓰기 차단 |
| `/tmp/chk_cam_operate.part_state` | `CleanupStalePartFiles()` | 파일 크기 추적 |
| `/tmp/chk_cam_operate.disconnect_state` | `maybe_init_cam_on_disconnect()` | disconnect 최초 시각/마지막 init |
| `/tmp/cam_disconnect_reboot.flag` | disconnect 에스컬레이션 | 같은 부팅의 재부팅 이력 |
| `/tmp/last_init_cam_ts` | `init_cam.sh` | cooldown 기준 시각 |

## 9. 구현 기준점

- `dist/pim/opt/pim/bin/chk_cam_operate.sh`
  - `MovePartFile()`
  - `ProcessCompletedSessions()`
  - `CleanupStalePartFiles()`
  - `CleanupOrphanMarkers()`
  - `CheckDiskSpace()`
  - `CheckFinalArrival()`
  - `maybe_init_cam_on_disconnect()`
- `dist/pim/opt/pim/bin/pim_guardian.py::collect_tmp_signals()`
- `vcm/tcpServer.cpp::check_and_mark_all_done()`
- gstApp `muxSinkBin.cpp::check_and_mark_all_done()`

## 10. 문서 이력

- 최초 작성: 2026-02-06
- 현행화: 2026-08-25
- 기준 구현: 세션 idempotency, SRT bootstrap, storage-mode 전환, orphan marker
  정리와 FINAL STALL telemetry가 포함된 현재 `master`
