# FINAL STALL 재현 테스트 매트릭스

`CheckFinalArrival` 워치독과 vcm bootstrap 패치의 정상/엣지 케이스 검증.
운영 단말 또는 동등 하드웨어에서 fleet rollout 전 모두 통과해야 함.

## 사전 준비
- 승인된 패키지 또는 배포 절차로 단말에 동일 커밋의 binary/script를 함께 배포
- `sync-to-gitlab.sh`, `sync-from-gitlab.sh`는 소스 저장소 간 동기화 도구이며
  단말 배포 명령이 아니다.
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
  - 기본 설정의 140초 워밍업 후 `cam_final_health` 가 `OK_FB` → `OK`
  - `cam_last_final_ts` 가 매 분 갱신
  - `FINAL STALL` 로그 0회

### S2. ord_vcm_conf.json srt_enable 키 누락
- 사전: 테스트 단말에서 `jq '.VCM.srt_enable' /root/shared_v/ord_vcm_conf.json`로
  현재 값을 기록한 뒤 승인된 설정 변경 절차로 키를 제거
- vcm 재시작
- **기대**: `bootstrap srt_done` 로그 없음 (srt 비활성). 영상은 정상 final 도달.
- 그 다음 운영값을 명시적으로 복원하고 vcm/gstApp을 재시작 → S1과 동일 결과.
- 과거 `audit_srt_enable.sh`, `migrate_srt_enable.sh`는 제거되었으므로 사용하지 않는다.

### S3. gstApp Snap-back resync (원래 버그 재현)
- 정상 운영 중 강제로 PATH_START_VIDEO_TIME mtime 변경
  ```bash
  touch /tmp/start_video_time_chk
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
- 테스트 설정에서 모든 채널을 비활성화하거나
  `.VHL_CAM.capture.enable=true`, `.VHL_CAM.capture.record=false`를 적용한 뒤
  카메라 파이프라인 재기동
- 2~3분 대기
- **기대**:
  - `cam_final_health` 가 `REC_DISABLED 0 ...`
  - `FINAL STALL` 로그 0회
  - 카메라 앱 재시작 발생 안 함

### S6. Final-path commit 정체 (escalation 검증)
- 카메라 연결과 fragment 생성은 유지한 채 fault-injection 환경에서
  `all_done` 생성 또는 `MovePartFile` final commit을 차단
- 운영 장비의 실제 영상을 손상시키지 않는 전용 테스트 경로에서만 수행
- 기본 설정에서 워밍업과 2분 검사 window 이후 5회의 60초 평가를 관찰
- **기대**:
  - `Heartbeat:OK`인 동안 `cam_final_health=STALL` 발생
  - stall_cnt 1~2: `kill_test.sh` 로그
  - stall_cnt 3~4: `init_cam.sh` 로그
  - stall_cnt 5: `reboot` (file_chk_reboot=true 시) 또는 카운터 리셋

물리 disconnect는 이 시나리오의 대체 수단이 아니다. 현재 기본값에서는
`maybe_init_cam_on_disconnect()`가 주기적 `init_cam.sh`를 소유하고
`disconnect_max_sec=0`이므로 disconnect만으로 재부팅하지 않는다. 선택적
disconnect 재부팅은 `test/cam_link/escalation_test.sh`에서 별도로 검증한다.

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
- `touch /tmp/start_video_time_chk` 를 1분 사이 2~3회 반복
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
