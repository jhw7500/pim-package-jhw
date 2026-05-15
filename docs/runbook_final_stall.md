# Runbook: FINAL STALL (final-path 도착 정체)

## 증상

`/var/log/syslog` 또는 journalctl 에서 다음 로그가 나타남:

```
[RST][chk_cam_operate.sh:XXX] FINAL STALL: no new <vhl>_* in /mnt/sd_cam for >Nm (stall_cnt=K)
[RST][chk_cam_operate.sh:XXX] FINAL STALL escalate: kill_test.sh (stall_cnt=K)
```

또는 `cat /tmp/cam_final_health` 가 `STALL <count> <window_min> <epoch>` 출력.

## 의미

영상 fragment(.part)는 만들어지는데 final 디렉토리(예: /mnt/sd_cam)에
도착하지 않고 있다. `.all_done` 세션 마커 누락 또는 `MovePartFile` 실패가
가장 흔한 원인.

## Escalation 단계 (자동)

| stall_cnt | 동작 | 의미 |
|---|---|---|
| 1~2 | kill_test.sh | 카메라 앱 재시작 (gstApp/vcm) |
| 3~4 | init_cam.sh | 카메라 초기화 |
| 5+ | reboot (file_chk_reboot=true 시) | 시스템 재부팅 |

각 단계 사이 60초 간격으로 자동 재평가.

## 진단 체크리스트

운영자가 `FINAL STALL` 로그를 본 경우 다음 순서로 진단:

1. **즉시 telemetry 확인**
   ```bash
   cat /tmp/cam_final_health
   cat /tmp/cam_last_final_ts && date +%s
   ```
   → `OK*` / `RAM_ONLY` / `REC_DISABLED` 면 자동 회복 중 또는 의도된 상태.

2. **세션 마커 확인**
   ```bash
   ls -la /tmp/session_*.video_done /tmp/session_*.srt_done /tmp/session_*.all_done 2>/dev/null
   ```
   → `srt_done` 없이 `video_done`만 누적 시 SRT 측 문제 (vcm 또는 conf).
   → `video_done` 없으면 gstApp/카메라 측 문제.

3. **tmp/sd_tmp/final 상태**
   ```bash
   ls -la /mnt/sd_cam/tmp/*.part 2>/dev/null
   ls -la /mnt/sd_cam/*.mp4 | tail -5
   ```

4. **SRT 비활성 의심**
   ```bash
   jq '.VCM.srt_enable' /root/shared_v/ord_vcm_conf.json
   ```
   → null 또는 누락이면 [audit_srt_enable.sh](../tools/audit_srt_enable.sh) /
   [migrate_srt_enable.sh](../tools/migrate_srt_enable.sh) 사용.

5. **SD 카드 상태**
   ```bash
   cat /dev/shm/sd_mount_flag
   dmesg | grep -iE "mmc|sd" | tail -20
   df -h /mnt/sd_cam
   ```
   → SD BAD/풀이면 RAM-only 모드로 자동 전환됨 (정상 동작).

6. **카메라 드라이버 disconnect**
   ```bash
   cat /sys/bus/i2c/devices/2-0048/link_status
   cat /sys/bus/i2c/devices/1-0048/link_status
   ```

## 영구 해결이 안 되는 경우

reboot 단계까지 escalate 되어도 회복 안 되면 다음 의심:
- SD 카드 hardware 결함 (`dmesg` mmc 에러)
- 카메라 모듈 disconnect
- `ord_vcm_conf.json` 잘못된 값
- 다른 프로세스(vsd 등)가 `/mnt/sd_cam` 점유

이 경우 hardware 교체 또는 manual rescue 필요.

## 관련 파일

- `/tmp/cam_final_health` — 1줄 telemetry (`<status> <metric> <window_min> <epoch>`)
- `/tmp/cam_last_final_ts` — 마지막 final 도착 epoch (heartbeat)
- `/tmp/cam_state/file_check.txt` (FILE_CHECK) — 라이브니스 OK/NG
- `/tmp/session_*.{video_done,srt_done,all_done}` — 세션 마커

## 관련 패치

이 워치독은 v0.6.2 의 P0/P1/P2 hotfix 셋으로 도입.
관련 변경: `chk_cam_operate.sh CheckFinalArrival`,
`vcm/tcpServer.cpp` prefixFileName bootstrap, srt_enable 디폴트.
