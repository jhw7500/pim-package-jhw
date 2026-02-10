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

- **생성 주체**: `gstApp` (바이너리)
- **생성 시점**: 녹화 시간(예: 1분)이 다 차고 파일이 닫힌 후
- **생성 위치**: `/tmp/session_YYYYMMDD_HHMM.all_done`
- **조건**: 활성 채널 수 이상의 채널에서 완료 카운트가 쌓일 때
- **코드 참고**:
  - 생성: `projects/gstApp/muxSinkBin.cpp:57-67`, `131-168`
  - 처리: `projects/pim-package/dist/pim/opt/pim/bin/chk_cam_operate.sh:394-450`

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
  - 경고(90%), 위기(95%) 임계치에 따라 오래된 세션 삭제
- **RAM Cap**: `enforce_ram_cap_if_needed` 함수
  - RAM-only 모드에서 1.6GiB 초과 시 오래된 세션 삭제

**코드 위치**: `chk_cam_operate.sh:264-375`

---

## 9. 버전 정보

- **작성일**: 2026-02-06
- **기반 버전**: `chk_cam_operate.sh` (943 lines)
