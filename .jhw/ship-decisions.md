# ship 리뷰 지적 처리 이력

## PR #3 — fix(cam): 카메라 링크 판정·복구 경로 결함 4건 수정

블로킹 임계: `must-fix` (기본). 라운드 1~3 동안 블로킹(must-fix / P1 / critical / high) 지적은 **0건**이었다.
아래는 블로킹 미만이지만 타당하다고 판단해 반영했거나, 근거와 함께 반려한 항목이다.

| 리뷰어 | 지적 | 심각도 | 처리 | 근거 |
|---|---|---|---|---|
| Codex | Detect persistent CTRL3 read failures | P2 | **resolved** | `read_fail` verdict 신설로 i2c 읽기 실패와 미정의 유효값을 분리 (커밋 `cb9d1aa`). Codex 리뷰는 `25d7e2f` 대상이며, 코멘트가 diff 이동으로 `cb9d1aa`에 재앵커된 것 |
| Claude | `DISCONNECT_REBOOT_FLAG` 쓰기 실패 시 리부팅 루프 | MEDIUM | **resolved** | 쓰기 성공을 확인한 뒤에만 리부팅. 실패 시 `local0.err` 남기고 에스컬레이션 건너뜀 |
| Gemini | 플래그 경로가 휘발성이면 리부팅 루프 | MEDIUM | **resolved** | `/var/log/cantops` 는 영구 저장소임을 확인(`chk_mmc.sh` 가 `/tmp/chk_mmc_var`(휘발)와 `/var/log/cantops/mmc_mode`(보존)를 구분해 사용, 로그 보존 한도 10GB). 추가로 휘발성인 `/tmp` 폴백을 제거 |
| Gemini | 전역 변수로 상태 전달 | MEDIUM | **declined** | `$(...)` 는 서브셸이라 함수가 설정한 비트 필드가 호출자에 전달되지 않는다. 반환 문자열 하나로는 mode/locked/error/cmu 4개 값을 진단 로그에 넘길 수 없어 의도적으로 전역을 사용했고 코드에 근거 주석을 남겼다 |
| Gemini | `read_fail` 이 일시적 NACK 에도 즉시 에러 | MEDIUM | **부분 반영** | 양 채널 경로는 읽기 재시도 3회 + 리셋 후에 판정하므로 즉시가 아니다. 단일 채널 경로는 기존 동작 보존(아래 항목과 동일 사유) |
| Claude | `errb_only` 에서 불필요한 3회 재시도 | LOW | **resolved** | `errb_only` 도 Phase 1 조기 종료. i2c 호출이 8회 → 4회로 감소함을 실측 |
| Claude | "recovered after reset" 이 읽기 재시도 회복에도 출력 | LOW | **resolved** | `recovered (read retry N)` / `recovered (reset)` 로 회복 경로를 구분. 중복 로그도 제거 |
| Claude, Gemini | 단일 채널 경로에 재시도·리셋 없음 | LOW | **declined** | 기존 동작 보존이 이 PR의 명시적 범위. 양 채널과의 비대칭은 별도 이슈로 다루는 것이 안전 |
| Gemini | `init_cooldown_sec` 30→40 확인 요청 | LOW | **확인** | 패키지 배포 설정(`config/ord_vcm_conf.json`)·`update_ordvcmconf.sh`·`chk_cam_operate.sh` 와 일치시킨 의도된 변경. 설정 파일 없이 동작하던 장비는 쿨다운이 10초 길어진다 |

### 라운드 3 (`7ee55bd`)

두 리뷰어 모두 블로킹 0건을 명시했다 — Claude *"블로킹 이슈 없음"*, Gemini *"No blocking issues found"*.

| 리뷰어 | 지적 | 심각도 | 처리 | 근거 |
|---|---|---|---|---|
| Gemini | `modprobe max9296` 실패해도 `imx8-media-dev` 를 계속 로드 | MEDIUM | **resolved** | `rc1` 실패 시 상위 모듈을 시도하지 않고 즉시 중단. 실패 모듈별로 로그를 분리해 원인 식별이 쉬워졌다 |
| Claude | 초기 판정이 `errb_only` 일 때 Phase 1 루프 1회 진입 | LOW | **resolved** | 루프 진입 전에 건너뛴다. i2c 호출이 4회 → 2회로 감소함을 실측 |
| Gemini | `DISCONNECT_REBOOT_FLAG` 잔류로 에스컬레이션 영구 누락 | MEDIUM | **declined** | 삭제 경로가 `cam_disconnect_flag==0 && drv_disc==0`(연결 회복) 시 동작하고 cooldown 만 지나면 도달한다. 카메라를 수리하면 회복 → 플래그 삭제 → 다음 episode 정상 동작. 하드웨어가 계속 죽어 있는 동안 재리부팅하지 않는 것은 의도된 루프 방지 동작 |
| Gemini | 드라이버 활성 상태에서 Serializer(0x40) 강제 쓰기 | MEDIUM | **declined** | 기존 코드와 동일한 리스크로 PR 설명에 이미 범위 밖으로 명시. Gemini 도 인지 사항으로 표기 |
| Gemini | `_cfg_num` 이 음수를 처리하지 않음 | LOW | **declined** | 사실과 다름. `^[0-9]+$` 가 이미 음수를 거부한다. 실측: `-5` → 기본값 치환 |
| Gemini | 전역 변수 오염 가능성 | LOW | **declined** | 라운드 2와 동일 사유(서브셸). 함수 진입 시 초기화하고 있음 |
| Claude | `unknown` 을 `error` 레벨로 기록 | LOW | **declined** | 미정의 레지스터 값은 조사가 필요한 신호이므로 `error` 유지. 메시지에 `no error flag` 를 명시해 혼동을 줄였다 |
| Claude | `reboot` 뒤 `return 0` → `return 1` 권장 | LOW | **declined** | 호출부가 `if maybe_init_cam_on_disconnect; then timer=0; sleep 5; continue; fi` 다. 리부팅 발동 후 루프를 재시작하는 편이 실환경에서 안전하므로 `return 0` 유지 |

### 이 PR 범위 밖으로 남긴 항목
- 채널 ↔ GMSL2 링크 매핑 실측 확정 (드라이버 `max9296.c` 와 스크립트 상수가 서로 반대). 진단 로그가 원시값·비트·`link_status` 를 함께 남기므로 현장 로그로 확정 가능
- `disconnect_max_sec` 기본 활성화 여부 결정
- `i2ctransfer -f` 가 드라이버 점유 디바이스에 강제 접근하는 문제 (특히 리셋 write)
- 단일 채널 경로의 재시도·리셋 비대칭
