# FINAL STALL 재현 테스트 매트릭스

`CheckFinalArrival` 워치독과 vcm bootstrap 패치의 정상/엣지 케이스 검증.
운영 단말 또는 동등 하드웨어에서 fleet rollout 전 모두 통과해야 함.

## 사전 준비
- 단말 동기화: `sync-from-gitlab.sh` 또는 패치 binary/script 직접 배포
- 패치 적용 위치:
  - vcm: 재빌드된 vcm binary → /opt/pim/bin/vcm
  - chk_cam_operate.sh → /opt/pim/bin/chk_cam_operate.sh
- 로그 수집: `journalctl -f` 또는 `tail -f /var/log/syslog`
- 텔레메트리 확인 보조: `watch -n 1 'cat /tmp/cam_final_health /tmp/cam_last_final_ts; date +%s'`

## 시나리오

### S1. Cold boot 정상 동작
- 단말 콜드부팅 후 vcm/gstApp 정상 기동
- **기대**:
  - 첫 2분 안에 `[SRT] bootstrap srt_done for prev session: ...` 1회
  - 2분 워밍업 후 `cam_final_health` 가 `OK_FB` → `OK`
  - `cam_last_final_ts` 가 매 분 갱신
  - `FINAL STALL` 로그 0회

### S2. ord_vcm_conf.json srt_enable 키 누락
- 사전: `audit_srt_enable.sh` 로 `AFFECTED` 확인 (또는 직접 conf 키 삭제)
- vcm 재시작
- **기대**: `bootstrap srt_done` 로그 없음 (srt 비활성). 영상은 정상 final 도달.
- 그 다음 `migrate_srt_enable.sh true` 실행 → vcm 재시작 → S1과 동일 결과.

### S3. gstApp Snap-back resync (원래 버그 재현)
- 정상 운영 중 강제로 PATH_START_VIDEO_TIME mtime 변경
  ```bash
  touch /dev/shm/start_video_time_chk
  ```
- **기대**:
  - vcm `start_video_time mtime changed - resync` 로그
  - 다음 분기 시점에 `bootstrap srt_done` 또는 정상 srt_done
  - 해당 세션 `.all_done` 마커 생성, `Complete:` 로그
  - `FINAL STALL` 발생 안 함

### S4. RAM-only 모드 (SD BAD 시뮬레이션)
- `echo 0 > /dev/shm/sd_mount_flag` 또는 `touch /tmp/sd_write_disabled`
- 2~3분 대기
- **기대**:
  - `cam_final_health` 가 `RAM_ONLY 0 ...`
  - `FINAL STALL` 로그 0회 (워치독 정상 skip)
  - `kill_test.sh` 호출 없음
- 복구: `echo 1 > /dev/shm/sd_mount_flag` → 정상 모드 복귀, S1 결과

### S5. Manual stop (녹화 중지)
- edgeconf에서 `cap_record_en=false` 설정 후 변경 트리거 (또는 cam_disable.sh)
- 2~3분 대기
- **기대**:
  - `cam_final_health` 가 `REC_DISABLED 0 ...`
  - `FINAL STALL` 로그 0회
  - 카메라 앱 재시작 발생 안 함

### S6. 카메라 disconnect 영구 (escalation 검증)
- 카메라 케이블 분리 또는 cam_disable.sh
- 6~10분 대기
- **기대**:
  - stall_cnt 1~2: `kill_test.sh` 로그
  - stall_cnt 3~4: `init_cam.sh` 로그
  - stall_cnt 5: `reboot` (file_chk_reboot=true 시) 또는 카운터 리셋

### S7. vhl_name underscore 안전성 (P1-A)
- edgeconf 에 `vhl_name="VD_3001"` 같이 underscore 포함 값 설정
- vcm 재시작
- **기대**:
  - `bootstrap srt_done for prev session: YYYYMMDD_HHMM` 정상 출력 (timestamp 추출 정확)
  - 영상 final 도달 OK

### S8. recording_time=5 (rec_min 비례 bootstrap, P1-C)
- edgeconf `recording_time=5`
- 단말 콜드부팅
- **기대**:
  - `bootstrap srt_done for prev session: ... (rec_min=5)` 로그
  - 5분 fragment 정상 final 도달
  - `FINAL STALL` window가 10분으로 자동 확대

### S9. heartbeat 깨짐 → find fallback
- 워치독 정상 동작 중 `rm /tmp/cam_last_final_ts`
- 60초 대기
- **기대**:
  - 다음 사이클에서 `cam_final_health` 가 `OK_FB` (fallback)
  - heartbeat 파일 자동 재생성
  - 그 다음 사이클부터 `OK`

### S10. 연속 Snap-back (S3 strong variant)
- `touch /dev/shm/start_video_time_chk` 를 1분 사이 2~3회 반복
- **기대**:
  - vcm 매번 resync
  - 모든 fragment final 도달 (마커 누락 없음)
  - 결과적으로 `FINAL STALL` 0회

## 통과 기준

- 모든 S1~S10 시나리오에서 기대 결과 일치
- S4/S5에서 `FINAL STALL` 또는 `kill_test.sh` 호출 0회
- S6 escalation 사슬 정확히 1~5 stall_cnt 단계 진행
- 모든 시나리오에서 segfault, hang, OOM 없음

## 로그 수집 명령

```bash
# 시나리오 시작 시
journalctl --since "now" -f > /tmp/scenario.log &
JPID=$!

# 시나리오 종료 시
kill $JPID
grep -E "FINAL STALL|bootstrap srt_done|RAM_ONLY|REC_DISABLED|Session complete|Complete:" /tmp/scenario.log
```
