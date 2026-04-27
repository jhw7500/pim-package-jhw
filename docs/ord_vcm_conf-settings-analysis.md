# `ord_vcm_conf.json` 설정값 분석

**대상 파일**: `/home/jhw/ai/opencode/projects/pim-package-jhw/dist/pim/opt/pim/config/ord_vcm_conf.json`
**작성일**: 2026-04-17
**참고 소스**:
- `/home/jhw/ai/opencode/projects/pim-package-jhw/ord/tcpServer.cpp`
- `/home/jhw/ai/opencode/projects/pim-package-jhw/ord/util.h`
- `/home/jhw/ai/opencode/projects/pim-package-jhw/vcm/tcpServer.cpp`
- `/home/jhw/ai/opencode/projects/pim-package-jhw/dist/pim/opt/pim/bin/chk_cam_operate.sh`
- `/home/jhw/ai/opencode/projects/pim-package-jhw/dist/pim/opt/pim/bin/BG_Check_for_pim.sh`

> 테이블은 유니코드 박스 문자로 그려져 있으므로 `cat`, `less`, 모노스페이스 에디터에서 그대로 정렬되어 보입니다. 한국어 폭 정렬은 East Asian Wide(2셀) 기준입니다.

---

## 1. 설정 파일 전체 구조

```json
{
   "ORD" : { ... },
   "VCM" : { ... },
   "ETC" : { ... }
}
```

- **ORD** 그룹 → `ord` 프로세스가 `tcpServer.cpp`에서 `json_object_get_value()`로 파싱
- **VCM** 그룹 → `vcm` 프로세스가 동일한 방식으로 파싱
- **ETC** 그룹 → C++ 코드가 아닌 **셸 스크립트(`jq`)**에서만 사용. 카메라 재시작/복구 로직 제어용

---

## 2. ORD 그룹

읽는 위치: `ord/tcpServer.cpp:1253~1269`

```
┌──────────────────────┬──────────┬─────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ 키                   │ 기본값   │ 단위    │ 효과                                                                                                                                         │
├──────────────────────┼──────────┼─────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ vhl_max              │ 1        │ 개      │ VHL 클라이언트 최대 동시 연결 수. 초과 시 연결 거부 (line ~1683)                                                                             │
│ event_auto_remove    │ true     │ bool    │ DEAD (ord_vcm_conf 미파싱). edgeconf_pim.json의 VHL_CAM에서 파싱(1216). 디스크초과/파일>15000 시 자동삭제(815), false면 복사거절(1904)       │
│ copy_margin_sec      │ 10       │ 초      │ 이벤트 복사 시 녹화 시작/종료 여유시간. margin_sec으로 복사 구간 분기 (line 2172, 2181)                                                      │
│ debug_level          │ 0        │ level   │ 디버그 로그 레벨                                                                                                                             │
│ log_level            │ 5        │ level   │ 로그 출력 레벨                                                                                                                               │
│ ip_static            │ ""       │ str     │ 정적 IP (저장만, 실제 분기 없음)                                                                                                             │
│ port_num             │ 10007    │ port    │ ORD TCP 서버 포트                                                                                                                            │
│ disk_manage          │ true     │ bool    │ false면 디스크 관리 스레드 자체 미생성 (line 1412, 1441)                                                                                     │
│ target_copy          │ true     │ bool    │ 타겟 경로로 이벤트 복사 여부 (line 988, 2088, 2121, 2161)                                                                                    │
│ rtc_reset            │ true     │ bool    │ 이벤트 감지 시 카메라 리셋 실행 여부 (line ~1876)                                                                                            │
│ disk_limit_per       │ 90       │ %       │ 디스크 사용률 임계값. 초과 시 구 파일 삭제 (line 2062, 2065)                                                                                 │
│ disk_limit_file      │ 1000     │ 개      │ 디스크 내 최대 파일 수. 초과 시 구 파일 삭제 (line 614, 617, 720)                                                                            │
│ disk_manage_period   │ 40       │ 초      │ 디스크 관리 체크 주기 (line 592, 910)                                                                                                        │
│ ovl_buffering        │ 0        │ 개      │ 오버레이 큐 버퍼 임계값. 초과 시 오래된 데이터 폐기 (line 1816)                                                                              │
│ vib_enable           │ false    │ bool    │ 진동 센서 수집 활성화. true면 Redis 스레드 생성 + 이벤트 파일에 vib 포함                                                                     │
│ evt_copy_delay       │ 15       │ 초      │ 이벤트 복사 usleep 대기시간. 경로 다르면 (max_bps/1024)*recMinute 가산 (line 1279). 복사 시점 공식 (line 2175/2184/2193). usleep(delay*SEC) @ line 944 │
│ err_send_period      │ 180      │ 초      │ 에러 상태 전송 주기. 0이면 주기 전송 미실행 (line 486, 511)                                                                                  │
└──────────────────────┴──────────┴─────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. VCM 그룹

읽는 위치: `vcm/tcpServer.cpp:1210~1227`

```
┌──────────────────┬──────────┬─────────┬────────────────────────────────────────────────────────────────────────────────────────────┐
│ 키               │ 기본값   │ 단위    │ 효과                                                                                       │
├──────────────────┼──────────┼─────────┼────────────────────────────────────────────────────────────────────────────────────────────┤
│ debug_level      │ 0        │ level   │ 디버그 로그 레벨                                                                           │
│ log_level        │ 5        │ level   │ 로그 출력 레벨                                                                             │
│ ip_static        │ ""       │ str     │ 정적 IP (저장만)                                                                           │
│ port_num         │ 10009    │ port    │ VCM TCP 서버 포트                                                                          │
│ srt_enable       │ true     │ bool    │ SRT(자막) 파일 생성/저장 활성화 (line 581, 638, 665)                                       │
│ srt_auto_sync    │ true     │ bool    │ 자동 시간 동기화 루프. false면 SRT 스레드가 동기화 대기 (line 421)                         │
│ srt_test         │ false    │ bool    │ SRT 테스트 모드 로그 (line 343)                                                            │
│ srt_period       │ 500      │ ms      │ SRT 갱신 주기. 주기마다 시간 동기화 체크 (line 560, 744)                                   │
│ srt_delay        │ 0        │ ms      │ SRT 처리 지연 — 주기 내 실제 대기 시간 (line 326, 664, 744)                                │
│ srt_set_index    │ 1        │ 개      │ SRT 큐에 N개 모일 때마다 파일 쓰기 (line 655)                                              │
│ srt_buffering    │ 0        │ 개      │ SRT 큐 버퍼 임계값 (최대 10). 초과 시 경고 (line 1231~1234)                                │
│ file_time_check  │ true     │ bool    │ 파일 시간 체크 플래그 (현재 로그 출력만, line 621)                                         │
│ ops_enable       │ false    │ bool    │ OPS(진동 연산) 데이터 폴링 활성화. false면 Redis 스레드 미생성 (line 873)                  │
│ ops_period       │ 500      │ ms      │ OPS 루프 주기 (line 193, 284)                                                              │
│ ops_buffering    │ 0        │ 개      │ OPS 큐 버퍼 임계값 (최대 10) (line 252, 1243~1246)                                         │
│ ops_delay        │ 0        │ ms      │ OPS 처리 지연 (line 190, 250, 284)                                                         │
│ vib_test         │ false    │ bool    │ 진동 센서 테스트 모드 (line 639, 698)                                                      │
└──────────────────┴──────────┴─────────┴────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. ETC 그룹 (셸 스크립트 전용)

읽는 위치: `dist/pim/opt/pim/bin/chk_cam_operate.sh:166~186`, `dist/pim/opt/pim/bin/BG_Check_for_pim.sh`

```
┌────────────────────────────────┬──────────┬─────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ 키                             │ 기본값   │ 단위    │ 효과                                                                                                                               │
├────────────────────────────────┼──────────┼─────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ file_check_delay               │ 10       │ 초      │ 녹화 파일 존재 검사 유예. diffEpoch ≥ file_check_delay일 때 검사 시작 (line 1040). rec_time+file_check_delay가 "파일 미생성" 타임아웃 (line 1185) │
│ file_check_reboot              │ true     │ bool    │ 파일 검사 실패 누적 시 재부팅 여부. false면 재부팅 없이 리트라이 카운트만 유지                                                     │
│ startup_grace_extra_sec        │ 10       │ 초      │ 부팅 후 추가 유예. in_startup_grace() 계산에 사용 (BG_Check_for_pim.sh:68, chk_cam_operate.sh:207)                                 │
│ init_cooldown_sec              │ 40       │ 초      │ init_cam.sh 실행 후 쿨다운. 이 기간 중 재초기화 방지 (chk_cam_operate.sh:84-85, 95, 104)                                           │
│ disconnect_init_interval_sec   │ 180      │ 초      │ 카메라 단절 감지 후 주기적 init_cam.sh 실행 간격 (line 123)                                                                        │
│ disconnect_init_grace_sec      │ 60       │ 초      │ 단절 감지 후 init 시도 전 유예. 순간 단절 오탐 방지 (line 118)                                                                     │
└────────────────────────────────┴──────────┴─────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. `evt_copy_delay` 동작 상세

### 5.1 단위 확정 근거

소비 지점 (`ord/tcpServer.cpp:944`):
```c
usleep((arg->delay)*SEC);
```

매크로 (`ord/util.h:41`):
```c
#define SEC  (1000UL * MSEC)   // MSEC=1000 → SEC=1,000,000 us
```

즉 `usleep(delay * 1,000,000)` → `delay` 값이 **초 단위**. 로그도 `"sleep : %dsec"` (line 942).

### 5.2 로드 직후 동적 보정 (line 1275~1280)

```c
if (strcmp(PATH_MOUNT, vhlConf.tmp_path) == 0) {
    path_eq_f = 1;                  // tmp와 mount 경로가 같으면 그대로
} else {
    path_eq_f = 0;
    _TOrdConf.evt_copy_delay += ((max_bps/1024) * vhlConf.recMinute);
}
```

- `tmp_path`가 마운트 경로와 다를 때(경로 간 복사 필요) 원본 값에 `(max_bps/1024) * recMinute` **가산**
- `max_bps`: 각 채널 비트레이트 중 최대값 (`ord/tcpServer.cpp:1231`에서 산출)
- `/1024`로 대략적 KB/s로 줄인 뒤 녹화 길이(분)와 곱해서 **복사에 추가로 필요한 초 수**로 간주
- 대용량 복사 대기를 위한 안전 마진

### 5.3 복사 시점 계산 (line 2175 / 2184 / 2193)

3케이스 모두 같은 패턴:

```c
// start-time copy (녹화 구간 초입 이벤트)
multiArg->delay = (recMinute * 60) - diff + evt_copy_delay;

// normal-time copy (녹화 구간 내부)
multiArg->delay = (recMinute * 60) - diff + evt_copy_delay;

// end-time copy (녹화 구간 말미, recMinute 경계 걸침)
multiArg->delay = (recMinute * 60) * 2 - diff + evt_copy_delay;
```

- `recMinute * 60`: 녹화 주기(초)
- `diff`: 이벤트 시각과 녹화 시작 시각의 차(초)
- **의미**: 현재 녹화 세그먼트가 끝나 파일이 닫힐 때까지 남은 시간 + `evt_copy_delay`만큼의 안전 여유 후 복사 스레드가 깨어남
- `evt_copy_delay`를 키우면 파일 flush/close 여유가 늘어 복사 실패 가능성 감소

---

## 6. 주요 연쇄 효과

```
┌────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────┐
│ 설정                   │ 영향                                                                                       │
├────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────┤
│ disk_manage=false      │ 디스크 관리 스레드 미생성 → disk_limit_per/file, disk_manage_period 모두 무의미            │
│ vib_enable=false       │ Redis 스레드 미생성 → 이벤트 복사 시 vib 파일 제외 (copyHead/copyTail 계산 변경)           │
│ ops_enable=false       │ OPS 스레드 미생성 → ops_period/buffering/delay 모두 무의미                                 │
│ srt_enable=false       │ SRT 파일 미생성 + 이벤트 복사 시 SRT 카운트 제외                                           │
│ err_send_period=0      │ 주기 에러 전송 비활성                                                                      │
│ rtc_reset=false        │ 이벤트 감지 시 카메라 리셋 스킵                                                            │
│ target_copy=false      │ 타겟 경로로 이벤트 복사 스킵                                                               │
└────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Dead 키 여부

`ord_vcm_conf.json` 기준 **dead key 1개 확인**:

- **`ORD.event_auto_remove`**: 이 JSON에서 **파싱되지 않음**. 실제 동작하는 `event_auto_remove`는 `edgeconf_pim.json`의 `VHL_CAM` 섹션에서 파싱됨 (`ord/tcpServer.cpp:1216`).
  - 사용처 ①: `ord/tcpServer.cpp:815` — 디스크 초과 또는 이벤트 파일 >15000개일 때 자동 삭제 트리거
    ```c
    if((disk_size_over_evt || disk_file_cnt_evt > 15000) && vhlConf.event_auto_remove)
        disk_op_f = TRUE;
    ```
  - 사용처 ②: `ord/tcpServer.cpp:1904` — 디스크 초과 상태에서 `event_auto_remove=false`면 이벤트 복사 요청 거절
    ```c
    if(disk_size_over_evt && !vhlConf.event_auto_remove) {
        __LOG(LOG_ERR, "evt auto remove false and evt disk size over!");
        ret = -1; break;
    }
    ```
  - 즉 `ord_vcm_conf.json`에서 이 키를 수정해도 **ORD 동작에 아무 영향 없음**. 실제 제어는 `edgeconf_pim.json`에서 해야 함.

아래는 파싱되지만 단순 저장/로깅 용도에 그침 (soft-dead):

- `ip_static` (ORD/VCM): 파싱 후 저장만, 실제 분기 미사용
- `file_time_check` (VCM): `true`/`false` 분기 없이 로그에만 출력

---

## 8. 파서 매핑 요약

- **ORD**: `ord/tcpServer.cpp:GetOrdConf*()` → 구조체 `_TOrdConf` (정의: `ord/tcpServer.h:145~159`)
- **VCM**: `vcm/tcpServer.cpp:GetVcmConf*()` → 구조체 `_TVcmConf` 계열
- **ETC**: `chk_cam_operate.sh:GetConfig_()` / `BG_Check_for_pim.sh` → bash 변수 (`jq -r ... | @tsv` tab-split)

ETC 그룹을 셸에서 파싱하는 `jq` 표현식 (chk_cam_operate.sh:172~181):

```bash
jq -r '[
    (.VCM.srt_enable // false),
    (.ETC.file_check_reboot // false),
    (.VCM.file_time_check // false),
    (.ETC.file_check_delay // 10),
    (.ETC.startup_grace_extra_sec // 10),
    (.ETC.init_cooldown_sec // 40),
    (.ETC.disconnect_init_interval_sec // 180),
    (.ETC.disconnect_init_grace_sec // 60)
] | @tsv' $FILE_JSON_
```

---

## 9. 변경 시 권장 검증 항목

```
┌────────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────┐
│ 키                                     │ 권장 검증 방법                                                                   │
├────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────┤
│ evt_copy_delay                         │ 이벤트 복사 로그 "sleep : Nsec" 확인 → 기대 지연과 일치                          │
│ copy_margin_sec                        │ 녹화 경계 이벤트(초입/말미)의 copyType 로그 분기 확인                            │
│ disk_limit_per, disk_limit_file        │ 임계값 근처에서 오래된 파일 삭제 동작                                            │
│ file_check_delay, file_check_reboot    │ 파일 미생성 시 재부팅 경로 트리거 확인                                           │
│ init_cooldown_sec, disconnect_init_*   │ 단절→init_cam 재호출 타이밍 로그 검증                                            │
│ srt_period, srt_delay, srt_set_index   │ SRT 파일의 엔트리 수/간격 실측                                                   │
│ ops_period, ops_delay                  │ OPS 데이터 수집 주기 실측                                                        │
└────────────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────┘
```
