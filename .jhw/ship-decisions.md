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

### 이 PR 범위 밖으로 남긴 항목
- 채널 ↔ GMSL2 링크 매핑 실측 확정 (드라이버 `max9296.c` 와 스크립트 상수가 서로 반대). 진단 로그가 원시값·비트·`link_status` 를 함께 남기므로 현장 로그로 확정 가능
- `disconnect_max_sec` 기본 활성화 여부 결정
- `i2ctransfer -f` 가 드라이버 점유 디바이스에 강제 접근하는 문제 (특히 리셋 write)
- 단일 채널 경로의 재시도·리셋 비대칭
