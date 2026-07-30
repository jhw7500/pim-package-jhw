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

---

## PR #4 — fix(cam): 리셋 쓰기 실패 진단 로그 + 링크 판정 회귀 테스트 추가

PR #3 은 라운드 4 전원 CLEAN 상태로 rebase 머지했고, 블로킹 미만이라 미룬 아래 두 건을 후속 PR 로 분리했다.

| 리뷰어 | 지적 | 심각도 | 처리 |
|---|---|---|---|
| Gemini | 리셋 `i2ctransfer` 쓰기의 성공 여부를 확인하지 않음 | LOW | **resolved** — deserializer/serializer 쓰기 종료코드를 각각 잡아 실패 시 `local0.warning` 으로 남긴다. 최종 판정은 종전대로 재읽기로 하되 어느 쪽 쓰기가 실패했는지 진단에 남는다 |
| Claude | 검증이 시뮬레이션으로만 이뤄지고 테스트가 커밋되지 않음 | LOW | **resolved** — `test/cam_link/` 에 회귀 테스트 6종 추가. 하드웨어 없이 `bash test/cam_link/run_all.sh` 로 실행 |

라운드 4회를 돌았고 **블로킹(must-fix / P1 / critical / high) 지적은 4라운드 내내 0건**이었다.
아래는 블로킹 미만이지만 반영한 것과, 근거를 달아 반려한 것이다.

### 반영 (라운드 2~4)

| 라운드 | 리뷰어 | 지적 | 심각도 | 근거 |
|---|---|---|---|---|
| 2 | Claude | `config_default_test` 의 상수 블록 추출이 실패하면 빈 파일을 source 해 단정이 무의미해질 수 있음 | LOW | 의존 상수 6개 존재를 확인하고 없으면 중단 |
| 2 | Gemini | `t_extract_func` 정규식이 `fn() {` 공백 1개를 엄격 요구 | LOW | 공백에 유연하게 보완 |
| 2 | Gemini | 쓰기 실패 시나리오에 `/dev/null` 하위 경로 사용 | LOW | **일반 파일 하위 경로**로 변경. Gemini 가 권한 readonly 디렉터리는 root 가 퍼미션을 무시해 케이스가 조용히 무력화되므로 채택하지 않았다. 일반 파일 하위는 `mkdir` 이 ENOTDIR 로 실패해 root 여부와 무관하다 |
| 2 | Claude | `rc_des`/`rc_ser` 가 스크립트 전역에 남음 | LOW | 블록별 `rc_des_01`/`rc_des_23` 로 분리 + 종료코드 의미 주석 |
| 3 | Claude | `t_extract_func` 의 `/^\}/` 가 `} > /dev/null` 같은 행에서 끊겨 '절반짜리' 파일을 만들고 `[ -s ]` 검사를 통과함 | MEDIUM | 종료 조건을 `/^\}$/` 로 좁히고, 추출 결과를 서브셸에서 source 해 `type -t` 로 함수 파싱을 재확인 |
| 3 | Claude | 스텁 호출 수에 리셋 쓰기가 포함되는 계산 근거가 없음 | LOW | `lib.sh`·`flag_e2e_test.sh` 양쪽에 주석 |
| 4 | Claude | rc 위치 검사가 `modprobe` 다음 줄이 `rc1=$?` 가 아니면 내용 무관하게 실패 → 빈 줄·주석에도 오탐 | MEDIUM | 빈 줄·주석을 건너뛰고 실행 줄만 검사. `awk` 가 빈 값을 내는 경우도 명시적 실패로 처리 |
| 4 | Claude | logger 스텁 heredoc 의 인용 규칙이 묵시적 | LOW | `$WORK` 는 지금 확장, `\$*` 는 스텁 실행 시점 인자임을 주석 |

### 반려 (근거)

| 리뷰어 | 지적 | 근거 |
|---|---|---|
| Gemini | `$tag` 가 `CHK` 면 `[CHK][CHK:188]` 로 중복 출력될 수 있음 | **사실과 다름.** `tag=$(basename "$0")` (`:6`) 이라 실제 출력은 `[CHK][chk_cam_connect.sh:88]`. 1호기 로그로 확인 |
| Gemini | 테스트가 `sed`/`awk` 추출에 의존해 원본 스타일 변경에 취약 (3라운드 연속) | 지적은 타당하나 추출 실패가 **조용한 통과가 아닌 명시적 실패**로 드러난다(`type -t` 검증 + 빈 값 처리). Gemini 도 *"현재 수준에서는 충분"* / *"감내할 수 있는 수준"* 으로 평가. 로직을 별도 `.lib` 로 분리하는 것은 프로덕션 구조 변경이라 범위 밖 |
| Claude | 스텁 `$val` 에 작은따옴표가 들어오면 취약 | 호출처가 16진수 문자열만 전달. Claude 도 *"실질적 문제는 없지만"* 으로 기재 |
| Claude | `ls` 파이프라인으로 파일 목록 파싱 | 제어된 임시 디렉터리. Claude 도 *"현재 코드도 허용 범위 내"* |
| Claude | `sed` 구분자 `#` 와 경로 충돌 가능성 | `mktemp -d` 경로에 `#` 가 들어오지 않는다. Claude 도 *"실질적 위험은 낮습니다"* |

### 이 PR 범위 밖으로 남긴 항목
- 채널 ↔ GMSL2 링크 매핑 실측 확정 (드라이버 `max9296.c` 와 스크립트 상수가 서로 반대). 진단 로그가 원시값·비트·`link_status` 를 함께 남기므로 현장 로그로 확정 가능
- `disconnect_max_sec` 기본 활성화 여부 결정
- `i2ctransfer -f` 가 드라이버 점유 디바이스에 강제 접근하는 문제 (특히 리셋 write)
- 단일 채널 경로의 재시도·리셋 비대칭
