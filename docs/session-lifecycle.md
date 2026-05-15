# 세션(Session) 라이프사이클 및 파일 처리 로직 정리

## 개요

이 문서는 `chk_cam_operate.sh` 스크립트에서 녹화 파일의 **생성 감지**, **세션 완료 처리**, **이동/삭제 로직**이 어떻게 동작하는지 정리한 것입니다.

---

## 1. 핵심 개념 정의

| 개념 | 설명 | 목적 |
| :--- | :--- | :--- |
| **파일 생성 감지** (File Generation Check) | 현재 녹화가 정상적으로 진행되고 있는지 실시간으로 감시 | 앱 사망(Crash) 감지 → 재부팅/재시작으로 복구 |
| **세션 완료 마커** (`all_done`) | 특정 세션(예: 1분 단위)의 녹화가 완전히 끝났음을 알리는 신호 | 파일을 안전한 저장소로 이동 (Commit) |
| **Stale .part** | 오랫동안 갱신되지 않은 미완성 파일 | 오래된 파일 정리 혹은 복구 시도 |

---

## 2. `all_done` 마커 이해

### 2.1 마커 생성 조건

`all_done` 마커는 **두 개의 부분 마커**가 모두 갖춰져야 생성된다.

| 부분 마커 | 생성 주체 | 생성 시점 |
| :--- | :--- | :--- |
| `/tmp/session_<ts>.video_done` | `gstApp` (muxSinkBin.cpp) | 해당 분의 영상 fragment가 활성 채널 수만큼 모두 close된 직후 |
| `/tmp/session_<ts>.srt_done` | `vcm` (tcpServer.cpp) | 해당 분의 SRT 자막 처리가 완료된 직후. **시작/resync 직후 첫 분기는 prefixFileName이 비어있어도 시간 계산 fallback으로 생성됨** (2026-05-15 패치) |
| `/tmp/session_<ts>.all_done` | 어느 쪽이든 위 두 마커가 모두 존재할 때 `check_and_mark_all_done()` 이 생성. 동시에 부분 마커는 unlink. | video_done + srt_done 매칭 시 |

- **생성 위치**: `/tmp/session_YYYYMMDD_HHMM.all_done`
- **video_done 조건**: 활성 채널 수(`cmdArg.cam[i].enable`) 이상의 채널에서 fragment_closed 누적
- **srt_done 조건**: `_TVcmConf.srt_enable == TRUE` 그리고 (정상 분기에서 `prefixFileName != ""` OR 부트스트랩 분기)
- **코드 참고**:
  - video_done: `gstApp/muxSinkBin.cpp:283`
  - srt_done (정상): `vcm/tcpServer.cpp:600-606`
  - srt_done (부트스트랩, 2026-05-15 패치): `vcm/tcpServer.cpp:584-599`
  - all_done 통합 판정: `muxSinkBin.cpp:120-133`, `tcpServer.cpp:58-69`
  - 처리: `dist/pim/opt/pim/bin/chk_cam_operate.sh:1135` (ProcessCompletedSessions trigger)

#### 설정 의존성: `srt_enable`

세 컴포넌트(vcm / gstApp parser / chk_cam_operate.sh) 모두 `srt_enable` 디폴트가 **FALSE** 로 통일됨 (2026-05-15 패치). 이전에는 vcm만 TRUE 였다.
운영 단말은 `ord_vcm_conf.json`에 명시값(`"srt_enable": true|false`)을 둘 것을 권장. 누락 시 SRT가 일관되게 비활성으로 동작.
점검: `tools/audit_srt_enable.sh`, 마이그레이션: `tools/migrate_srt_enable.sh`.

### 2.2 마커가 있을 때 (정상 흐름)

1. `ProcessCompletedSessions` 함수가 `/tmp/session_*.all_done` 마커를 순회
2. 해당 타임스탬프(`YYYYMMDD_HHMM`)의 모든 `.part`, `.mp4`, `.ts`, `.srt` 파일 처리
3. **2단계 이동** 실행:
   - **Stage 1**: `tmp_path` → `sd_tmp_path` (파일 복사 + sync + 원본 삭제)
   - **Stage 2**: `sd_tmp_path` → `final_path` (파일 이동 + `.part` 확장자 제거)
4. 모든 처리가 성공하면 마커 삭제, 실패 시 다음 루프에서 재시도

**코드 위치**: `chk_cam_operate.sh:377-450`, `MovePartFile:115-175`

---

## 3. `all_done` 마커가 만들어지지 않았을 때

### 3.1 기본 동작

마커가 없으면 **"정상적인 커밋(이동) 이벤트는 발생하지 않습니다.** 대신 주기적(30초) 유지보수 루틴만 동작합니다.

### 3.2 유지보수 루틴 (30초마다 실행)

```
if [ $((timer % 30)) -eq 0 ]; then
    apply_storage_mode_overrides
    mkdir -p "$tmp_path" "$sd_tmp_path" "$final_path"
    CleanupStalePartFiles    # Stale .part 처리
    CheckDiskSpace           # 디스크/RAM 임계치 체크
fi
```

**코드 위치**: `chk_cam_operate.sh:926-934`

### 3.3 Stale .part 파일 처리 로직

`CleanupStalePartFiles` 함수는 마커 없이 남겨진 `.part` 파일을 다음과 같이 처리합니다.

#### A. `tmp_path`에 있는 `.part`

- **처리**: 일반적으로 **삭제**
- **조건**: 파일 크기가 N주기(기본 120초) 이상 변하지 않으면 "Stale"로 판단
- **예외 (첫 분 단편 보호)**:
  - 앱 재시작 직후 첫 1분 단편(HHMM00)은 짧게 기록될 수 있음
  - `/tmp/start_video_time_chk`에 기록된 실제 시작 시각을 확인하여 Stale 삭제에서 보호

**코드 위치**: `chk_cam_operate.sh:454-581` (특히 545-562행)

#### B. `sd_tmp_path`에 있는 `.part`

- **처리**: **복구 시도 (final_path로 이동)**
- **조건**: 파일이 Stale로 판단되면 `MovePartFile` 호출하여 `sd_tmp_path → final_path`로 이동
- **의도**: SD카드가 이미 중간에 복사된 파일들이 남겨진 경우, 이를 최종 위치로 복구

**코드 위치**: `chk_cam_operate.sh:534-543`

### 3.4 시나리오 정리

| 상황 | 마커 | 동작 |
| :--- | :--- | :--- |
| **정상 녹화** | ✓ 생성 | 파일 이동 (tmp → sd_tmp → final) |
| **녹화 중 앱 사망** | ✗ 생성 안 됨 | 재부팅 후 `tmp_path`의 `.part`는 Stale 삭제 |
| **녹화는 끝났는데 마커만 안 생김** | ✗ 생성 안 됨 | 파일이 계속 남다가 Stale로 간주되어 삭제될 수 있음 |
| **중간에 복사된 파일만 남음** | ✗ 생성 안 됨 | `sd_tmp_path`의 `.part`는 Stale로 final로 복구 시도 |

---

## 4. 파일 생성 감지 vs `all_done` 차이점

### 4.1 차이점 요약

| 구분 | **파일 생성 감지** (File Generation Check) | **all_done 마커** (Session Completion) |
| :--- | :--- | :--- |
| **목적** | **생존 신고 (Watchdog)**<br>현재 카메라 앱이 죽지 않고 파일을 쓰고 있는지 확인 | **작업 완료 (Commit)**<br>해당 시간대 녹화가 모두 끝났으니 파일을 안전한 곳으로 옮기라는 신호 |
| **시점** | **실시간 (Real-time)**<br>녹화가 시작된 직후부터 주기적으로 계속 확인 | **사후 (Post-event)**<br>녹화 시간(예: 1분)이 다 차고 파일이 닫힌 뒤에 확인 |
| **확인 대상** | **현재 녹화 중인 파일**<br>(예: `tmp_path`에 `.mp4`나 `.part`가 있는가?) | **완료 마커 파일**<br>(`/tmp/session_...all_done` 파일이 있는가?) |
| **동작 (성공 시)** | 카운터(`retry`) 초기화하고 계속 감시 | 파일을 `sd_tmp` → `final`로 이동하고 `.part` 떼기 |
| **동작 (실패 시)** | **앱 재시작 / 리부팅**<br>(`kill_test.sh`, `reboot`) | **아무 일도 안 함**<br>(파일 이동 안 됨, 나중에 Stale 로직으로 삭제될 수 있음) |

### 4.2 상세 로직 비교

#### A. 파일 생성 감지 (죽었으면 살린다)

- **작동 원리**:
  - `gstApp`이 새로운 파일을 쓰기 시작하면 `/tmp/start_video_time_chk`에 시간 기록
  - `chk_cam_operate.sh`는 이 시간을 보고 **"시작한 지 10초(`file_check_delay`)가 지났는데 파일이 왜 없어?"**라고 판단하면 에러 카운트 증가
- **코드 위치**: `chk_cam_operate.sh:731`
- **상황**: "심장 박동이 멈췄다" → **응급 처치(재부팅) 들어감**

#### B. all_done (끝났으면 옮긴다)

- **작동 원리**:
  - `gstApp`은 1분 녹화가 무사히 끝나고 파일을 닫은 뒤, 마지막으로 "이 세션 끝!"이라며 `all_done` 파일 생성
  - `chk_cam_operate.sh`는 이걸 보고 **"아, 이 파일은 이제 건드려도 안전하구나"**라고 판단하여 SD카드로 옮김
- **코드 위치**: `chk_cam_operate.sh:394`
- **상황**: "수술이 끝났다" → **회복실(저장소)로 이동**

---

## 5. 재부팅/재시작 로직

### 5.1 실행 조건 (트리거)

`kill_test.sh`, `init_cam.sh`, `reboot`는 **"녹화 파일 생성이 감지되지 않을 때"** 실행됩니다.

#### Case A: 파일 생성 지연 (녹화 중 끊김/누락 감지)

- **조건**:
  - `/tmp/start_video_time_chk` 파일이 갱신된 후
  - `file_check_delay`(기본 10초)가 지났는데도
  - 활성화된 채널의 파일(.mp4 등)이 `tmp_path`에 없을 때
- **판단**: `check_num`(활성 채널 수)과 `file_cnt`(발견된 파일 수)가 다르면 (`check_num != file_cnt`) 실패로 간주

**코드 위치**: `chk_cam_operate.sh:832-871`

#### Case B: 초기 기동 실패 (앱 시작 후 무응답)

- **조건**:
  - 감시 루프의 타이머가 `rst_time`(채널 수에 따라 25~35초)을 초과할 때까지
  - 파일 생성이 한 번도 감지되지 않았을 때 (`start_f`가 0일 때)

**코드 위치**: `chk_cam_operate.sh:880-923`

### 5.2 단계별 조치 (`retry_total` 누적 횟수 기준)

실패가 감지되면 `retry_total` (`retry` + `retry_boot`) 값이 증가하며, 이 값에 따라 다음 스크립트를 실행합니다.

| 누적 실패 횟수 | 실행 명령 | 목적 (추정) |
| :--- | :--- | :--- |
| **1회 ~ 3회** | `/opt/pim/bin/kill_test.sh` | **프로세스 재시작**: 문제가 있는 앱 프로세스만 죽여서 재시작 유도 |
| **4회 ~ 5회** | `/opt/pim/bin/init_cam.sh` | **카메라 초기화**: 카메라 드라이버/모듈 레벨의 초기화 시도 |
| **6회 이상** | `reboot` | **시스템 재부팅**: 복구 불가 판단 시 시스템 리부팅<br>(단, 설정 파일의 `file_check_reboot`가 true여야 함) |

**코드 위치**: `chk_cam_operate.sh:840-861`, `900-918`

### 5.3 예외 (실행하지 않는 경우)

- **카메라 연결 끊김**:
  - `/tmp/bg_chk_flag.bin` 값을 확인하여 카메라 연결이 끊긴 상태(`cam_disconnect_flag != 0`)라고 판단되면
  - 재시도 로직을 타지 않고 로그만 남깁니다
- **파일 생성 성공**:
  - 파일 개수 확인이 성공하면(`check_num == file_cnt`)
  - 모든 카운트(`retry`, `retry_boot`, `retry_total`)는 0으로 초기화됩니다

### 5.4 Final-path 도착 정체 워치독 (2026-05-15 패치)

기존 파일 생성 감지가 잡지 못하는 **사일런트 정체** 차단용 별도 워치독.

- **이름**: `CheckFinalArrival`
- **주기**: 60초 (timer % 60 == 0)
- **검사**: heartbeat(`/tmp/cam_last_final_ts`) age < `rec_min*2` 분 → OK. 없거나 stale이면 `find $final_path_cfg -name "${vhl_name}_*" -mmin -N` fallback.
- **결과 노출**: `/tmp/cam_final_health` 1줄 (`<status> <metric> <window_min> <epoch>`)

#### 진입 가드 (검사 자체 skip)

| 가드 | telemetry status |
| :--- | :--- |
| `is_ram_only_mode` (SD BAD/write-disable) | `RAM_ONLY` |
| 모든 카메라 채널 disabled (csi1_en=0 && csi2_en=0) | `REC_DISABLED` |
| capture 모드인데 cap_record_en=false (`cap_en=true && cap_record_en=false`) | `REC_DISABLED` |
| `/tmp/init_cam_flag` / `/tmp/restart_flag` / `/tmp/kill_flag` 진행 중 | `BUSY` |
| 시작 후 워밍업 (`timer < rec_time*2`) | `WARMUP <timer>` |

#### 정체 escalation 사슬

| stall_cnt | 동작 |
| :--- | :--- |
| 1 ~ 2 | `/opt/pim/bin/kill_test.sh` |
| 3 ~ 4 | `/opt/pim/bin/init_cam.sh` |
| 5+ | `reboot` (단, `file_chk_reboot=true` 시. 아니면 카운터 리셋) |

각 단계 사이 60초 간격으로 재평가. `MovePartFile` 성공 시 heartbeat 갱신 → 다음 사이클에 자동 OK 복귀.

**코드 위치**:
- 워치독: `chk_cam_operate.sh:918-1010` (CheckFinalArrival, _write_final_health)
- heartbeat 갱신: `chk_cam_operate.sh:309-311` (MovePartFile Stage 2 직후)
- 호출: `chk_cam_operate.sh:1415` (60초 블록)
- guardian 노출: `pim_guardian.py:702-712, 729-733` (final_health_* 필드 5종)

상세 진단 절차는 [runbook_final_stall.md](./runbook_final_stall.md), 시나리오 테스트는 [../test/test_final_stall_scenarios.md](../test/test_final_stall_scenarios.md) 참조.

---

## 6. 시나리오별 동작 요약

### 6.1 정상 상황

```
1. 녹화 시작
2. 파일 생성 감지 OK (재부팅 안 함)
3. 1분 후 녹화 끝
4. all_done 생성
5. 파일 이동 (tmp → sd_tmp → final)
6. 마커 삭제
```

### 6.2 녹화 중 앱 사망 (Crash)

```
1. 녹화 시작
2. 파일 쓰다가 멈춤
3. 파일 생성 감지 Fail
4. retry_total 누적 → kill_test.sh 실행
5. retry_total 계속 누적 → reboot
6. 재부팅 후:
   - 남겨진 .part는 Stale로 간주되어 삭제
   - all_done은 절대 생성되지 않음
```

### 6.3 녹화는 다 했는데 all_done만 안 생김 (버그 상황)

```
1. 녹화 시작
2. 파일 생성 감지 OK (재부팅 안 함)
3. 녹화 끝났는데 마커 안 만듦
4. ProcessCompletedSessions 스킵 (마커 없음)
5. 파일이 tmp에 계속 쌓임
6. 30초 주기 체크(CleanupStalePartFiles)에서 Stale로 간주
7. 결과: 파일 삭제될 수 있음
```

---

## 7. 참고 파일 경로 및 라인 번호

| 기능 | 파일 | 라인 |
| :--- | :--- | :--- |
| **세션 완료 처리** | `chk_cam_operate.sh` | 377-450 |
| **MovePartFile (2단계 이동)** | `chk_cam_operate.sh` | 115-175 |
| **Stale .part 처리** | `chk_cam_operate.sh` | 454-581 |
| **파일 생성 감지** | `chk_cam_operate.sh` | 724-871 |
| **초기 기동 실패 감지** | `chk_cam_operate.sh` | 880-923 |
| **주기적 유지보수 루프** | `chk_cam_operate.sh` | 926-934 |
| **all_done 마커 생성** | `gstApp/muxSinkBin.cpp` | 57-67, 131-168 |
| **세션 ID 추출** | `gstApp/muxSinkBin.cpp` | 83-103 |
| **파일명 생성** | `gstApp/muxSinkBin.cpp` | 65-73 |

---

## 8. 추가 참고사항

### 8.1 경로 설정

- `tmp_path`: 임시 녹화 경로 (기본: `/tmp` 또는 `/dev/shm`)
- `sd_tmp_path`: SD카드 임시 경로 (기본: `/mnt/sd_cam/tmp`)
- `final_path`: 최종 저장 경로 (기본: `/mnt/sd_cam` 또는 `/dev/shm/recordings` - RAM-only 모드)

### 8.2 모드 오버라이드

`apply_storage_mode_overrides` 함수는 SD 상태에 따라 런타임에 경로를 변경합니다:

- **SD OK**: 설정 파일의 경로 사용 (`final_path_cfg`, `sd_tmp_path_cfg`)
- **SD Bad 또는 쓰기 비활성화**: RAM-only 모드로 전환
  - `final_path = /dev/shm/recordings`
  - `sd_tmp_path = tmp_path`

**코드 위치**: `chk_cam_operate.sh:204-220`

### 8.3 디스크/RAM 임계치 관리

- **SD Retention**: `enforce_sd_retention_if_needed` 함수
  - 경고(95%), 위기(98%) 임계치에 따라 오래된 세션 삭제 (기본값: `WARN_PCT_DEFAULT=95`, `CRIT_PCT_DEFAULT=98`)
- **RAM Cap**: `enforce_ram_cap_if_needed` 함수
  - RAM-only 모드에서 1.6GiB 초과 시 오래된 세션 삭제

**코드 위치**: `chk_cam_operate.sh:264-375`

### 8.4 /tmp 파일 명세 (마커 + telemetry + 사이클 플래그)

녹화 라이프사이클에서 chk_cam_operate.sh / gstApp / vcm 사이에 오가는 `/tmp` 파일 전체 목록.

#### 세션 마커 (transient)

| 파일 | 생성자 | 소비자 | 의미 | 수명 |
| :--- | :--- | :--- | :--- | :--- |
| `/tmp/session_<YYYYMMDD_HHMM>.video_done` | gstApp/muxSinkBin.cpp:283 | check_and_mark_all_done() | 해당 분 영상 fragment 전 채널 close | mark_session_complete() 시 unlink |
| `/tmp/session_<YYYYMMDD_HHMM>.srt_done` | vcm/tcpServer.cpp:600 또는 부트스트랩 | check_and_mark_all_done() | 해당 분 SRT 처리 완료 또는 부트스트랩 fallback | mark_session_complete() 시 unlink |
| `/tmp/session_<YYYYMMDD_HHMM>.all_done` | check_and_mark_all_done() (vcm 또는 gstApp 측) | chk_cam_operate.sh ProcessCompletedSessions | 세션 완료, 이동 트리거 | ProcessCompletedSessions 완료 후 unlink |
| `/tmp/session_debug.log` | gstApp/muxSinkBin.cpp:271 | (없음, 디버그용) | 매 fragment_closed의 채널 카운팅 | append-only, /tmp 재초기화 시 비워짐 |

#### Final-path 워치독 telemetry (2026-05-15 신규)

| 파일 | 생성자 | 소비자 | 의미 |
| :--- | :--- | :--- | :--- |
| `/tmp/cam_last_final_ts` | MovePartFile Stage 2 mv 성공 직후 | CheckFinalArrival 1차 검사 | 마지막 final 도착 epoch (heartbeat) |
| `/tmp/cam_final_health` | CheckFinalArrival 매 60초 | pim_guardian.py, 외부 fleet 모니터 | 1줄: `<status> <metric> <window_min> <epoch>`. status ∈ {OK, OK_FB, RAM_ONLY, REC_DISABLED, BUSY, WARMUP, STALL} |

#### 라이브니스 / 사이클 플래그 (기존)

| 파일 | 생성자 | 의미 |
| :--- | :--- | :--- |
| `/tmp/cam_state/file_check.txt` (`$FILE_CHECK`) | chk_cam_operate.sh 매 사이클 | OK / NG (라이브니스 외부 노출) |
| `/tmp/start_video_time_chk` | gstApp NEW_CLOCK 핸들러 | 현재 녹화 시작 시각. vcm가 mtime 변화로 resync 트리거 |
| `/tmp/init_cam_flag` | init_cam.sh | 카메라 초기화 진행 중 |
| `/tmp/restart_flag` | start_cam.sh / restart_app.sh | 앱 재시작 진행 중 |
| `/tmp/kill_flag` | kill_test.sh | 종료 진행 중 |
| `/tmp/bg_chk_flag.bin` | BG_Check_for_pim.sh | 카메라 disconnect bitmap |
| `/tmp/sd_write_disabled` | retention 로직 | SD write 강제 차단 (RAM-only 진입) |
| `/dev/shm/sd_mount_flag` | automnt_sd_for_emmc_boot.sh | SD 마운트 상태 (0=BAD, 1/2=OK) |
| `/tmp/chk_cam_operate.part_state` | CleanupStalePartFiles | stale .part 추적 |
| `/tmp/chk_cam_operate.disconnect_state` | maybe_init_cam_on_disconnect | disconnect 첫 감지 시각 + last init |
| `/tmp/cam_state/last_start_ts` | start_cam.sh | 마지막 시작 epoch |
| `/tmp/pim_cam_start_delay` | start_cam.sh | app_delay 값 |
| `/tmp/last_init_cam_ts` | init_cam.sh | 마지막 init_cam 시각 (cooldown 판정용) |

---

## 9. 버전 정보

- **작성일**: 2026-02-06
- **최종 갱신**: 2026-05-15 (FINAL STALL 워치독 + /tmp 파일 명세 추가)
- **기반 버전**:
  - `chk_cam_operate.sh` (~1430 lines, P0/P1/P2 hotfix 적용본)
  - `vcm/tcpServer.cpp` (srt_enable 디폴트 FALSE, prefixFileName bootstrap)
  - `gstApp/muxSinkBin.cpp` (변경 없음)
