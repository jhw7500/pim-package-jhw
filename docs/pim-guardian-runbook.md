# PIM Guardian 운영/장애 대응 런북

> 대상: 현장 운영자, 개발자, QA
> 
> 목적: `pim_guardian.py` 로그만 보고도 정상/장애를 빠르게 판단하고, 즉시 조치 및 에스컬레이션 자료를 확보한다.
>
> 기준: 2026-08-25 `master`. 구현 위치는 행 번호가 아니라 함수/필드명을 기준으로 확인한다.

---

## 1) 빠른 시작

### 실행

```bash
/opt/pim/bin/pim_guardian.py
```

복구 요청 파일 생성까지 포함하려면:

```bash
/opt/pim/bin/pim_guardian.py --recovery
```

기본 루프 주기: `--interval 5` (초)

에러 표시 튜닝(옵션):

```bash
/opt/pim/bin/pim_guardian.py --error-window-sec 300 --error-list-max 8
```

- `--error-window-sec`: `/tmp/err_*.log` 유효 시간창(초), 기본 `180`
- `--error-list-max`: `Error List` 최대 항목 수, 기본 `5`

---

## 2) 30초 트리아주 순서 (현장용)

아래 순서대로만 보면 된다.

1. `Camera Health`의 `reason` 확인
2. `Camera:` / `Heartbeat:` 확인
3. `App Uptime`에서 `gstApp`, `vcm`이 `N/A`인지 확인
4. `TMP`의 `bgCamMask`, `file`, `syncDebounced` 확인
5. `Recent Error` + `Error List` 확인

판단 키워드:
- `reason=ok` + `bgCamMask=0x0` + `Heartbeat:OK` = 정상
- `reason=bg_cam_err_mask=...` = 카메라 채널 에러 우선
- `reason=pipeline_down` = 앱 down
- `Heartbeat:FROZEN` = 스트림 정지
- `syncDebounced=WARN` = start_time 불일치 지속

---

## 3) 로그 블록 구조

예시:

```text
[03:10:57] [WiFi:DOWN RX:0KB/s TX:0KB/s] [RTC:OK] [Camera:4/4] [Heartbeat:OK(0s)]
         |- [Storage: SD(N/A/N/A) SHM(3.8%)] [App CPU: gstApp(28.9%) ord(0.2%) vcm(3.1%)]
         |- [App Uptime: gstApp(00:57) ord(05:33) vcm(00:57)] [Power:OK(22.60V)]
         `- [System: CPU(46.3%/78C)] [DiskIO: SD(mmcblk1 0.0%/0.0KB/s) eMMC(mmcblk0 2.1%/128.0KB/s)] [RAMDelta:+64.0KB/s] [Peaks: Temp(78C) MinVolt(22.60V)]
         ! [Recent Error] None
         ! [Error List] None
         ! [Camera Health] effective=4/4 reason=ok hw=4/4 bgMask=0x0 channels=NONE
         |- [TMP: file=OK fileAge=27s camErrStreak=0 done(video/srt)=0/0 syncRaw=N/A syncDebounced=OK bgCamMask=0x0 bgCamCh=NONE vhl=True sdErrAge=0s]
```

---

## 4) 필드 설명 (운영 관점)

### 상단 상태 라인

- `WiFi:... RX/TX...` : 무선 인터페이스 상태/트래픽
- 쉽게 말해: 무선 연결이 살아있는지, 데이터가 실제로 오가는지
- `RTC:OK|ERR` : `hwclock -r` 성공 여부
- 쉽게 말해: 장비 시계(RTC)를 읽을 수 있는지
- `Camera:...` : 최종 운영 판단값 (`STARTING`, `x/y`, `UNKNOWN(...)`)
- 쉽게 말해: 지금 카메라를 몇 개나 "정상으로 본다"는 뜻
- `CamErr:CAM...` : BG 에러 비트 기반 에러 채널 목록 (`CAM0,CAM2` 등)
- 쉽게 말해: 문제 난 카메라 채널 번호를 바로 보여준다
- `Heartbeat:OK(n s)|FROZEN(n s)|NO_FILES` : `.part` 갱신 기반 파이프라인 생존 상태
- 쉽게 말해: 영상 파일 갱신이 최근에도 일어나고 있는지

### Storage/App 라인

- `SD(mode/usage)` : SD 마운트 모드/사용률
- 쉽게 말해: SD가 붙어있는지, 읽기전용(RO)인지, 얼마나 찼는지
- `SHM(usage)` : tmp_path 사용률
- 쉽게 말해: RAM 임시공간(`/dev/shm`)이 얼마나 찼는지
- `App CPU` : `gstApp`, `ord`, `vcm` CPU
- 쉽게 말해: 각 프로세스가 CPU를 얼마나 쓰는지
- `App Uptime` : 프로세스 생존 시간 (`N/A`면 미실행)
- 쉽게 말해: 앱이 살아있으면 실행 시간, 죽어있으면 `N/A`

### System 라인

- `CPU(x%/yC)` : 전체 CPU 사용률/온도
- 쉽게 말해: 장비가 얼마나 바쁘고 뜨거운지
- `DiskIO: SD(...), eMMC(...)` : 각 블록 디바이스의 util/쓰기속도
- 쉽게 말해: SD와 eMMC에 각각 얼마나 디스크 쓰기가 발생하는지
- `RAMDelta:+/-xKB/s` : `/dev/shm` 사용량의 순증감 속도(추정치)
- 쉽게 말해: RAM 임시공간이 지금 늘어나는지(+), 줄어드는지(-)
- 주의: `RAMDelta`는 "실제 write byte"가 아니라 **순사용량 변화량**이다.
  - 같은 공간을 덮어쓰는 작업은 작게 보일 수 있다.
  - 파일 정리/이동이 일어나면 음수로 보일 수 있다.
- `Peaks` : guardian 시작 이후 최고온도/최저전압
- 쉽게 말해: "이번 실행 동안" 가장 뜨거웠던 온도와 가장 낮았던 전압

### 진단 라인

- `Recent Error` : 최근 에러 1줄 (우선순위: `/tmp/err_*.log` 최신 항목 -> journal)
- 쉽게 말해: SD/카메라/온도/전압/WiFi 에러 플래그가 더 최근이면 그 내용을 먼저 보여준다
- `Error List` : 최신 순 에러 목록(각 항목에 에러 시간 포함)
- 쉽게 말해: 최근에 무슨 에러가 어떤 순서로 났는지 한 번에 확인한다
- `Camera Health`
  - `effective=` : 현재 카메라 최종 상태
  - `reason=` : 판단 근거 (`startup_grace`, `bg_cam_err_mask`, `ok`, `pipeline_down`)
  - `hw=` : 하드웨어 체크 원본 결과 (`check_cams`)
  - `bgMask=` : 활성 채널 기준 BG 카메라 에러 비트
- 쉽게 말해: 카메라 상태를 "왜" 그렇게 판단했는지 근거를 보여주는 라인

### TMP 라인

- `file` : `/tmp/file_check` 값 (`OK`, `NG`, `EMPTY`)
- 쉽게 말해: 파일 생성 체크 성공/실패 상태
- `fileAge` : `file_check` 마지막 갱신 후 경과초
- 쉽게 말해: 체크 값이 얼마나 오래됐는지
- `camErrStreak` : `/tmp/cam_state/streak`
- 쉽게 말해: 카메라 에러가 몇 번 연속 발생했는지
- `done(video/srt)` : 세션 완료 마커 개수
- 쉽게 말해: 비디오/자막 완료 파일 개수 비교
- `syncRaw` : start time raw 비교 (`OK`, `MISMATCH`, `N/A`)
- 쉽게 말해: 즉시 비교 결과(순간값)
- `syncDebounced` : raw mismatch 디바운스 상태 (`OK`, `WARN`)
- 쉽게 말해: 잠깐 튄 값은 무시한 "안정 판정" 결과
- `bgCamMask` : `/tmp/bg_chk_flag.bin` 하위 4비트(raw)
- 쉽게 말해: 채널별 카메라 에러 비트맵
- `bgCamCh` : 활성 채널 기준 에러 채널 목록 (`CAM0,CAM1` 등)
- 쉽게 말해: 비트값 해석 없이도 어느 채널이 에러인지 바로 확인 가능
- `vhl` : VHL cache 정합성
- 쉽게 말해: 설정 캐시가 기대값과 맞는지
- `sdErrAge` : `/tmp/err_sdcard.log` 경과초
- 쉽게 말해: SD 관련 에러가 최근에 있었는지

### Final 라인

TMP 라인 바로 다음에 별행으로 출력됨. Final-path 워치독 상태 5필드.

```text
`- [Final: status=OK metric=12 window=2m hbAge=12s hbEpoch=1778827600]
```

- `status` : 워치독 상태. `OK`, `OK_FB`, `RAM_ONLY`, `REC_DISABLED`, `BUSY`, `WARMUP`, `STALL`, `N/A`
- 쉽게 말해: 영상이 SD 최종 위치까지 잘 도착하는지. 자세한 의미는 위의 `Final-path 워치독 필드` 섹션 표 참조.
- `metric` : status 별 의미 다름.
  - `OK` → 마지막 final 도착 후 경과 초
  - `WARMUP` → 현재 timer 초
  - `STALL` → stall_cnt (escalation 단계 추적)
  - 그 외 → `0`
- `window` : 검사 윈도우(분). 보통 `rec_min * 2` (최소 2)
- `hbAge` : `/tmp/cam_last_final_ts`(마지막 final 도착 epoch) 기준 경과초. `N/A` 면 heartbeat 파일 없음
- `hbEpoch` : 마지막 final 도착 시각(epoch). `N/A` 면 heartbeat 파일 없음

운영 빠른 해석:
- `status=OK hbAge=<window*60 이내>` → 정상
- `status=STALL metric=<n>` → 자동 escalation 진행 중 (1~2: kill_test, 3~4: init_cam, 5+: reboot)
- `status=RAM_ONLY` / `REC_DISABLED` → 의도된 비활성, 워치독 skip 중
- `status=WARMUP` → 계산된 시작 유예시간 안이면 정상. 기본 설정의 유예시간은
  `120 + 10 + 10 = 140`초다.
- WARMUP이 계산된 유예시간보다 오래 지속되면 raw telemetry의 4번째 epoch와
  현재 시각을 비교하고 `chk_cam_operate.sh` 정지를 의심한다.

### 초보자용 한 줄 해석 예시

- `Camera:STARTING(...)` : 지금은 기동 직후라 판정 유예 중
- `Camera:UNKNOWN(app_down ...)` : 앱이 죽어 카메라 상태를 신뢰할 수 없음
- `Heartbeat:FROZEN` : 영상 갱신이 멈춤
- `syncDebounced=WARN` : start time 불일치가 일시적이 아니라 지속됨
- `bgCamMask=0x5` : CAM0 + CAM2 채널 에러
- `CamErr:CAM0,CAM2` 또는 `bgCamCh=CAM0,CAM2` : 사람이 바로 읽는 채널 표기

### Final-path 워치독 필드

`chk_cam_operate.sh CheckFinalArrival`이 60초마다 `/tmp/cam_final_health` 1줄을 갱신하고,
`MovePartFile` 성공 시 `/tmp/cam_last_final_ts` heartbeat를 찍는다. guardian이 이 2개 파일을 collect하여 다음 5필드로 노출한다.

| 필드 | 출처 | 의미 |
| :--- | :--- | :--- |
| `final_health_status` | `cam_final_health` 1번째 토큰 | 워치독 상태. 아래 표 참조 |
| `final_health_metric` | `cam_final_health` 2번째 토큰 | status 별 의미 다름 (아래) |
| `final_health_window_min` | 3번째 토큰 | 검사 윈도우(분). `rec_min * 2` (최소 2) |
| `final_health_epoch` | 4번째 토큰 | telemetry 갱신 시각(epoch) |
| `final_heartbeat_epoch` | `cam_last_final_ts` 원문 | 마지막 final 도착 시각(epoch). MovePartFile 성공 직후 갱신 |

#### status 값 + metric 의미

| status | metric 의미 | 운영 해석 |
| :--- | :--- | :--- |
| `OK` | 마지막 final 도착 후 경과 초 | 정상. heartbeat 기반 |
| `OK_FB` | 0 | 정상이지만 heartbeat 없음/stale → find -mmin fallback으로 확인 |
| `RAM_ONLY` | 0 | SD BAD/write-disable → SD final 검사 의도적 skip (정상 RAM-only) |
| `REC_DISABLED` | 0 | 모든 채널 disabled 또는 capture 모드+record off → 녹화 없음 |
| `BUSY` | 0 | restart/init/kill 사이클 진행 중 → 검사 일시 skip |
| `WARMUP` | 현재 timer 초 | 시작 후 워밍업 중. 기준은 `rec_time*2 + file_check_delay + startup_grace_extra_sec`이며 기본 140초 |
| `STALL` | stall_cnt | **정체 감지**. escalation 진행 중 (자동 복구 시도) |

#### 운영 시 빠른 확인

```bash
cat /tmp/cam_final_health        # 1줄 telemetry
cat /tmp/cam_last_final_ts       # heartbeat
date +%s                          # 비교 기준
```

- `OK <age>` 인데 age > rec_min*60*2 → guardian 갱신 지연 또는 워치독 정지
- `STALL <n>` 이 1~2 → 자동 kill_test.sh 진행 중 (지켜보기)
- `STALL <n>` 이 3~4 → init_cam.sh 진행 중
- `STALL <n>` 이 5+ → reboot 직전 (file_chk_reboot=true 시)
- 기본 설정에서 `WARMUP 120`은 정상 범위다. WARMUP 지속 여부는 raw telemetry
  epoch와 계산된 유예시간을 함께 확인한다.

Final 라인은 관측용이다. `status=STALL` 자체가 guardian의 `guardian_bits`나
`--recovery` 요청 조건을 직접 올리지는 않는다. FINAL STALL의 kill/init/reboot
사다리는 `chk_cam_operate.sh CheckFinalArrival()`이 소유한다.

상세 진단/대응: [runbook_final_stall.md](./runbook_final_stall.md)

---

## 5) Camera 판단 규칙 (중요)

`Camera`/`Camera Health`는 아래 우선순위로 계산된다.

1. startup grace 이내: `STARTING(hw=...)`
2. BG 카메라 에러 비트 존재: `x/y`, `reason=bg_cam_err_mask=0x...`
3. 앱(`gstApp`, `vcm`) 둘 다 up: `hw 결과 사용`, `reason=ok`
4. 그 외: `UNKNOWN(app_down hw=...)`, `reason=pipeline_down`

즉, **동작 중에는 BG cam err bit를 우선** 사용하고,
init 구간은 별도 `STARTING(...)`으로 표기한다.

---

## 6) 경고/장애 임계값

- 온도 경고 진입: `>= 80C`
- 온도 경고 해제: `< 75C`
- 온도 치명 비트(CPU_HOT): `>= 85C`
- 전압 정상 범위: `20.4V ~ 27.6V`
- Heartbeat OK 조건: idle `< 10s` (그 외 `FROZEN`)
- TMP sync 경고: `syncRaw=False` 3회 연속
- RAMDelta 경고 진입: `>= +16384KB/s` (약 +16MB/s)
- RAMDelta 경고 해제: `<= +8192KB/s` (약 +8MB/s)

---

## 7) 복구 트리거 규칙

guardian은 `guardian_bits`를 만들고, 아래 조건일 때만 복구 요청 카운트를 올린다.

- `--recovery` 옵션 활성
- `guardian_bits`에 아래 중 하나 포함
  - `GUARD_BIT_CAM_MISMATCH`
  - `GUARD_BIT_HB_FROZEN`

연속 카운트(`error_count`)가 4회(>3)일 때 `/tmp/recover_req_init_cam` 생성 요청.

---

## 8) 대표 장애 시나리오

### A. 카메라 분리(운영 중)

증상:
- `Camera Health reason=bg_cam_err_mask=...`
- `TMP bgCamMask != 0x0`
- 이후 `Heartbeat:FROZEN` 가능

조치:
1. 채널 비트 확인 (`0x1,0x2,0x4,0x8`)
2. 케이블/전원/커넥터 확인
3. `Recent Error` + `Error List` I2C/GST 메시지 확보

### B. 앱 다운

증상:
- `App Uptime: gstApp(N/A)` 또는 `vcm(N/A)`
- `Camera:UNKNOWN(app_down hw=...)`
- `reason=pipeline_down`

조치:
1. 프로세스 상태 확인
2. 서비스 재기동 경로 확인(`restart_app.sh`, `init_cam.sh`)
3. `Recent Error` + `Error List`와 journal 로그 수집

### C. 온도 높음

증상:
- `Temp Warning` 라인 반복
- `CPU(.../80C+)`

조치:
1. 팬/방열/주변 온도 확인
2. 85C 이상 지속 시 복구 비트 영향 확인

### D. TMP sync 불일치

증상:
- `syncRaw=MISMATCH` 반복
- `syncDebounced=WARN`

조치:
1. start time 관련 파일(`/tmp/start_video_time_chk`, `/tmp/start_video_time_cpy`) 점검
2. 일시 mismatch인지 지속 mismatch인지(디바운스 기준) 구분

### E. RTC 오류

증상:
- `RTC:ERR`
- 재부팅/시간 동기화 이후에도 반복

조치:
1. `hwclock -r` 직접 실행해 재현 확인
2. 시스템 시간/NTP 동기화 상태 점검
3. RTC 장치/배터리/보드 전원 상태 점검

### F. SD 이상 (미장착/읽기전용/에러)

증상:
- `Storage: SD(N/A/N/A)` (미장착 상태에서는 정상일 수 있음)
- `Storage: SD(RO/...)`
- `sdErrAge`가 작음(최근 SD 에러)

조치:
1. SD가 원래 장착 대상인지 먼저 확인(정책상 미장착이면 `N/A` 정상)
2. 장착 대상인데 `RO`면 파일시스템/마운트 상태 점검
3. SD 재장착 후 마운트/쓰기 테스트 확인
4. 필요 시 RAM 경로(`/dev/shm`) 사용률(`SHM`)도 같이 모니터링

### G. RAM 급증 (tmpfs 압박)

증상:
- `RAMDelta:+xxxxKB/s`가 크게 유지
- `RAM Delta Warning` 라인 반복
- `SHM` 사용률 동반 상승

조치:
1. `tmp_path`로 쓰는 프로세스(gstApp 등) 상태 확인
2. 세션 마커/정리 루틴(`session_*.all_done`, stale 정리) 지연 여부 확인
3. SHM가 빠르게 100%로 향하면 즉시 원인 로그 수집 후 저장 경로 정책 점검

주의:
- `RAMDelta`는 실제 write byte가 아니라 **순사용량 변화량**이다.
- 파일 이동/정리 시 음수(`-`)가 나올 수 있다.

### H. FINAL STALL (사일런트 정체)

증상:
- Final 라인의 `status=STALL metric=<n>` 지속
- `final_heartbeat_epoch` 가 `final_health_epoch` 기준 `rec_min * 120` 초보다 오래된 상태
- syslog 에 `[RST] FINAL STALL: no new <vhl>_* in <final_dir>` 반복
- 그러나 `Heartbeat:OK` (영상 fragment는 만들어지고 있음)

원인 후보:
- vcm/gstApp 간 `srt_done` 마커 미생성 (config srt_enable 불일치 등)
- `MovePartFile` 실패 (권한/SD 풀/마운트 RO)
- 카메라 disconnect 후 dead state 영구화

조치:
1. `cat /tmp/cam_final_health /tmp/cam_last_final_ts && date +%s`
2. `ls -la /tmp/session_*.{video_done,srt_done,all_done} 2>/dev/null` — 어느 마커가 누락인지
3. `jq '.VCM.srt_enable' /root/shared_v/ord_vcm_conf.json` — null은 현재
   구현에서 `false`다. 운영 의도와 다르면 승인된 설정 배포 경로로 명시값을 넣고
   vcm/gstApp을 포함한 파이프라인을 재기동한다.
4. escalation은 자동 진행한다(kill_test → init_cam → reboot). `stall_cnt`와
   journal의 단계가 진행하지 않거나 reboot 후에도 재발하면 storage/hardware를 확인한다.
5. 상세 진단: [runbook_final_stall.md](./runbook_final_stall.md)

---

## 9) bgCamMask 비트맵

`bgCamMask = /tmp/bg_chk_flag.bin & 0x0F`

- bit0 (`0x1`): CAM0
- bit1 (`0x2`): CAM1
- bit2 (`0x4`): CAM2
- bit3 (`0x8`): CAM3

예:
- `0x5` = CAM0 + CAM2 에러

---

## 10) 에스컬레이션용 최소 수집 템플릿

아래 6줄만 전달해도 1차 분석이 가능하다.

```text
1) 최근 guardian 로그 20줄
2) Camera Health 라인 3개 이상 (연속 시점)
3) TMP 라인 3개 이상 (bgCamMask, syncDebounced 포함)
4) Recent Error 라인 원문
5) Error List 블록 원문
6) 발생 시각 + 직전 작업(케이블 탈착/SD 탈착/재부팅 등)
```

---

## 11) 관련 문서

- `docs/camera-operation-guide.md`
- `docs/session-lifecycle.md` — 세션 마커 + `/tmp` 파일 명세 8.4
- `docs/cpu-usage-analysis.md`
- `docs/runbook_final_stall.md` — FINAL STALL 시나리오 H 상세 절차
- `docs/file_check_reboot-behavior.md` — 재부팅 게이트와 5개 분기
- `test/test_final_stall_scenarios.md` — 워치독 재현 시나리오 S1~S10
