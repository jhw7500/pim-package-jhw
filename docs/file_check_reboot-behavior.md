# `file_check_reboot` 동작 명세

`ord_vcm_conf.json`의 `.ETC.file_check_reboot` 값이 `chk_cam_operate.sh` 루프에서 어떻게 해석되고, 어떤 조건에서 재부팅을 트리거하는지 정리한다.

## 1. 설정 경로 및 로딩

| 항목 | 값 |
|------|----|
| JSON 파일 | `/root/shared_v/ord_vcm_conf.json` |
| 스크립트 변수 `FILE_JSON_` | `/root/shared_v/ord_vcm_conf.json` (`chk_cam_operate.sh:849`) |
| JSON 키 | `.ETC.file_check_reboot` |
| 로컬 변수명 | `file_chk_reboot` |
| 기본 JSON 배포값 | `true` (`release/pim/opt/pim/config/ord_vcm_conf.json:42`) |
| 스크립트 파싱 기본값 | `false` (키 누락 시, `chk_cam_operate.sh:174`) |
| 판정식 | `[[ "$file_chk_reboot" == *"$ENABLE_VAL"* ]]` (`ENABLE_VAL="true"`) |

### 로딩 코드 (`chk_cam_operate.sh:167-186`)
```bash
GetConfig_() {
    IFS=$'\t' read -r \
        srt_en file_chk_reboot time_rec_en file_check_delay \
        ... < <(
        jq -r '[
            (.VCM.srt_enable // false),
            (.ETC.file_check_reboot // false),
            ...
        ] | @tsv' "$FILE_JSON_"
    )
}
```

판정은 문자열 포함(`*"true"*`) 방식이므로 `"true"` 문자열이면 활성, 그 외(`false`, 누락, 잘못된 값)는 **비활성**으로 간주한다.

## 2. 동작 분기 요약

`file_check_reboot`는 `chk_cam_operate.sh` 메인 루프에서 **3개의 재부팅 분기**를 제어한다. 각 분기는 모두 점진적 복구(kill_test → init_cam)가 실패하고 `retry_total` 한계를 초과한 최종 단계에서 동작한다.

| # | 분기 위치 | 트리거 조건 | `true`일 때 | `false`(또는 누락)일 때 |
|---|-----------|-------------|-------------|-------------------------|
| 1 | `chk_cam_operate.sh:991` | 드라이버 모듈(max9296 / imx8_media_dev) 미로딩 + `retry_total > 5` | `reboot` 즉시 재부팅 | retry 3종 카운터 전부 0으로 리셋 후 루프 계속 |
| 2 | `chk_cam_operate.sh:1146` | 시작 후 채널별 녹화 파일 미생성(file count mismatch) + `retry_total > 5` | `reboot` 즉시 재부팅 | 동일하게 카운터 리셋 후 계속 |
| 3 | `chk_cam_operate.sh:1217` | `rst_time` 초과까지 전체 녹화 파일 미생성(시작 실패) + `retry_total > 4` | `reboot` 즉시 재부팅 | 동일하게 카운터 리셋 후 계속 |

### 재부팅 직전 복구 단계 (참고)

| 분기 | `retry_total` 단계별 행동 |
|------|---------------------------|
| 드라이버 로드 실패 | `≤ 5` → `init_cam.sh`; `> 5` → **reboot 또는 리셋** |
| 파일 체크 실패 | `≤ 3` → `kill_test.sh`; `≤ 5` → `init_cam.sh`; `> 5` → **reboot 또는 리셋** |
| 시작 실패 | `≤ 2` → `kill_test.sh`; `≤ 4` → `init_cam.sh`; `> 4` → **reboot 또는 리셋** |

## 3. 값별 동작 정리

### `true` (기본 배포값)
- **3가지 실패 상황에서 최종 수단으로 `reboot` 호출**.
- 로그: `local0.emerg` 레벨로 `rebooting because ...` 출력 후 `sleep 1`, `reboot`.
- 하드웨어 수준 문제(예: I2C 링크 장애, 드라이버 hang)를 강제 하드 리셋으로 해소.
- 단점: 재부팅으로 인해 진행 중인 녹화가 중단될 수 있음.

### `false`
- **어떤 실패 상황에서도 재부팅 없음**.
- 로그: `local0.notice` 레벨로 `retry count reset because file_check_reboot is not true` 출력.
- `retry`, `retry_boot`, `retry_total`을 모두 0으로 리셋하여 복구 사이클(kill_test → init_cam)을 **무한 반복**.
- 장점: 재부팅으로 인한 녹화 중단 방지.
- 단점: 하드웨어 장애 시 소프트 복구로는 해결 불가능하여 카메라 불능 상태가 지속될 수 있음.

### 누락/잘못된 값
- `jq // false` 기본값에 의해 `false`로 처리 → 위 **`false` 동작과 동일**.

## 4. 재부팅 예외 (값과 무관)

`file_check_reboot=true`라도 다음 조건에서는 **절대 재부팅하지 않는다**:

| 예외 | 확인 위치 | 이유 |
|------|-----------|------|
| 카메라 disconnect 상태 (`cam_disconnect_flag != 0`) | `chk_cam_operate.sh:1002, 1158, 1228` | 카메라 물리 분리는 재부팅으로 해결되지 않음. disconnect 루프에서 `init_cam` 주기 실행으로 복구 시도 |
| init cooldown 중 (`in_init_cooldown` / `cam_in_init_cooldown`) | `chk_cam_operate.sh:1132, 1203` | `init_cam.sh` 직후 `init_cooldown_sec`(기본 30s) 내에는 재시도 건너뜀 |
| 드라이버 sysfs disconnect 비트 세트 (`drv_disc != 0`) | `chk_cam_operate.sh:1160, 1231` | 드라이버 레벨 링크 손실과 구분된 처리 경로 사용 |
| 모든 채널 비활성(`csi1_en=0 && csi2_en=0`) | `chk_cam_operate.sh:1196` | 시작 실패 분기에서 바로 `continue` |

## 5. 관련 참조

- 세션 복구 단계 표: `docs/session-lifecycle.md:160` (`6회 이상 reboot` 항목)
- JSON 업데이트 스크립트(키 누락 시 `true` 기본 주입): `dist/pim/opt/pim/bin/update_ordvcmconf.sh:76`
- 설정 파일 기본 내용: `release/pim/opt/pim/config/ord_vcm_conf.json`, `ord/docs/ord_vcm_conf.json`

## 6. 운영 가이드

- **정상 운영(기본)**: `true` 유지. 드라이버/파일시스템 hang을 자동 복구.
- **디버깅/라이브 관찰 시**: `false`로 설정하여 재부팅 없이 로그 수집 가능. 단 실제 장애 발생 시 수동 개입 필요.
- **변경 후**: `chk_cam_operate.sh`는 시작 시 한 번만 JSON을 읽으므로(`GetConfig_` 호출 위치: 921행, 루프 내 재로딩 없음) **값 변경 후에는 프로세스 재시작 필요**.
