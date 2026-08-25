# Runbook: FINAL STALL (final-path 도착 정체)

> 기준: 2026-08-25 `master`.

## 증상

`/var/log/syslog` 또는 journal에서 다음 로그가 나타난다.

```text
[RST][chk_cam_operate.sh:...] FINAL STALL: no new <vhl>_* in <final_dir> for >Nm (stall_cnt=K)
[RST][chk_cam_operate.sh:...] FINAL STALL escalate: kill_test.sh (stall_cnt=K)
```

또는 `cat /tmp/cam_final_health`가
`STALL <count> <window_min> <epoch>`를 출력한다.

## 의미

녹화 fragment의 생성 여부와 최종 저장 경로 도착 여부는 서로 다른 감시 대상이다.
`Heartbeat:OK`라도 `all_done` 마커 누락, `MovePartFile()` 실패 또는 저장장치
문제로 final-path 도착만 멈출 수 있다. `CheckFinalArrival()`은 이 사일런트
정체를 별도로 감시한다.

## 상태와 자동 조치

`/tmp/cam_final_health` 형식:

```text
<status> <metric> <window_min> <epoch>
```

| status | metric | 의미 |
|---|---:|---|
| `OK` | 마지막 도착 age(초) | heartbeat로 최근 final 도착 확인 |
| `OK_FB` | 0 | heartbeat가 없거나 stale이지만 `find -mmin` fallback으로 최근 파일 확인 |
| `RAM_ONLY` | 0 | SD BAD/write-disable로 SD final 감시 제외 |
| `REC_DISABLED` | 0 | 모든 채널 비활성 또는 capture 녹화 비활성 |
| `BUSY` | 0 | init/restart/kill 진행 중 |
| `WARMUP` | 현재 timer(초) | 시작 직후 유예 중 |
| `STALL` | `stall_cnt` | final 도착 정체, 자동 복구 사다리 진행 |

검사 윈도우는 `max(rec_min * 2, 2)`분이다. 시작 워밍업은
`rec_time * 2 + file_check_delay + startup_grace_extra_sec`이며, 기본
`recording_time=1`분 설정에서는 140초다.

| `stall_cnt` | 자동 동작 |
|---:|---|
| 1~2 | `kill_test.sh` |
| 3~4 | `init_cam.sh` |
| 5 이상 | `file_check_reboot=true`면 reboot, 아니면 카운터 초기화 |

정상 루프에서는 60초마다 다시 평가한다. `MovePartFile()`이 실제 final 도착을
완료하면 `/tmp/cam_last_final_ts`를 갱신하고 다음 검사에서 `OK`로 복귀한다.
Guardian의 Final 라인은 이 상태를 표시만 하며, FINAL STALL 복구 사다리는
`chk_cam_operate.sh`가 직접 소유한다.

## 진단 체크리스트

1. **telemetry와 heartbeat 확인**

   ```bash
   cat /tmp/cam_final_health
   cat /tmp/cam_last_final_ts
   date +%s
   ```

   - `OK`/ `OK_FB`: 최근 도착 확인
   - `RAM_ONLY`/ `REC_DISABLED`: 의도된 감시 제외
   - `BUSY`/ `WARMUP`: 복구 또는 시작 유예 중
   - `STALL`: metric으로 현재 에스컬레이션 단계 확인
   - 파일이 없으면 워치독이 아직 실행되지 않았거나 설정된 final 디렉터리가 없는지 확인

2. **세션 마커 확인**

   ```bash
   ls -la /tmp/session_*.video_done /tmp/session_*.srt_done /tmp/session_*.all_done 2>/dev/null
   ```

   - `video_done`만 누적: vcm/SRT 설정 또는 자막 완료 경로 확인
   - `srt_done`만 누적: gstApp 영상 fragment close 경로 확인
   - `all_done` 누적: `ProcessCompletedSessions()` 또는 파일 이동 실패 확인

3. **tmp/sd_tmp/final 경로 확인**

   실제 경로는 `/root/shared_v/edgeconf_pim.json`의 `VHL_CAM` 설정을 우선한다.

   ```bash
   jq '.VHL_CAM | {tmp_path, sd_tmp_path, final_path}' /root/shared_v/edgeconf_pim.json
   find /mnt/sd_cam/tmp -maxdepth 1 -type f -name '*.part' -print 2>/dev/null
   find /mnt/sd_cam -maxdepth 1 -type f -name '*.mp4' -print 2>/dev/null | tail -5
   ```

4. **SRT 설정 확인**

   ```bash
   jq '.VCM.srt_enable' /root/shared_v/ord_vcm_conf.json
   ```

   현재 vcm, gstApp parser와 `chk_cam_operate.sh`는 키 누락을 모두 `false`로
   해석한다. 패키지 기본 설정은 `true`다. 값이 `null`이거나 의도와 다르면
   승인된 설정 배포 경로로 명시값을 넣고 vcm/gstApp을 포함한 카메라 파이프라인을
   재기동한다. 과거의 `audit_srt_enable.sh`와 `migrate_srt_enable.sh`는
   일회성 마이그레이션 완료 후 제거되었으므로 사용하지 않는다.

5. **SD 상태 확인**

   ```bash
   cat /dev/shm/sd_mount_flag
   dmesg | grep -iE 'mmc|sd' | tail -20
   df -h /mnt/sd_cam
   ```

   SD BAD/쓰기 차단이면 RAM-only로 전환되는 것이 정상이다. SD가 다시 OK가 되면
   `CheckDiskSpace()`가 RAM backlog backfill과 경로 복원을 수행한다.

6. **카메라 상태 확인**

   ```bash
   cat /tmp/cam_state/state
   cat /tmp/bg_chk_flag.bin
   cat /sys/bus/i2c/devices/2-0048/link_status
   cat /sys/bus/i2c/devices/1-0048/link_status
   ```

   `link_status`는 stale할 수 있으므로 단독 판정 근거로 사용하지 않는다.
   Guardian의 `bgCamMask`, `/tmp/cam_state`, syslog의 `[CHK]` CTRL3/RX3
   진단과 함께 해석한다.

## reboot까지 가도 회복되지 않을 때

- SD 카드 하드웨어 또는 파일시스템 결함
- 카메라 모듈/케이블 disconnect
- `ord_vcm_conf.json` 또는 `edgeconf_pim.json` 설정 불일치
- 다른 프로세스가 final 경로를 점유하거나 권한/용량 문제 발생
- vcm/gstApp 중 한쪽이 부분 마커를 만들지 못함

하드웨어 교체나 수동 복구 전에 위 telemetry, 세션 마커, Guardian 로그와 journal을
함께 보존한다.

## 관련 파일과 구현

- `/tmp/cam_final_health` — `<status> <metric> <window_min> <epoch>`
- `/tmp/cam_last_final_ts` — 마지막 final 도착 epoch
- `/tmp/file_check` — 라이브니스 `OK`/`NG`
- `/tmp/session_*.{video_done,srt_done,all_done}` — 세션 마커
- `dist/pim/opt/pim/bin/chk_cam_operate.sh`
  - `MovePartFile()`
  - `ProcessCompletedSessions()`
  - `CheckFinalArrival()`
- `dist/pim/opt/pim/bin/pim_guardian.py`
- `docs/session-lifecycle.md`
- `test/test_final_stall_scenarios.md`

이 워치독은 v0.6.2 P0/P1/P2 hotfix에서 처음 도입됐으며, 이후 storage-mode,
heartbeat, cooldown, orphan marker 처리 보강이 추가됐다.
