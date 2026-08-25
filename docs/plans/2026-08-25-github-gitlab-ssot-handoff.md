# GitHub–GitLab SSoT 인수인계 구현 계획

> **실행 방식:** 현재 세션에서 작업별 검증 체크포인트를 거쳐 순차 실행한다.

**목표:** GitHub `master`의 코드·문서를 검증 가능한 단일 정본으로 만들고, GitLab 보호 브랜치를 건드리지 않으면서 `feat/cam-link-diagnostics`에 필요한 코드와 인수인계 문서만 동기화한다.

**설계:** 동기화 범위는 기존 PIM 코드 범위와 명시적 파일 allowlist의 합으로 제한한다. 자동 바이너리 검증은 `off|warn|strict` 모드로 제공하고 기본은 비차단 경고다. GitLab 쓰기는 dry-run, 커밋 검토, 명시적 기능 브랜치 푸시 순서로 분리한다.

**기술:** Bash, rsync, Git, Python 3, Markdown, Notion

---

## Task 1: 기준 상태와 설계 고정

**Files:**
- Add: `docs/plans/2026-08-25-github-gitlab-ssot-handoff-design.md`
- Add: `docs/plans/2026-08-25-github-gitlab-ssot-handoff.md`

1. GitHub/GitLab 원격을 fetch하고 기준 SHA를 기록한다.
2. 기존 미커밋 변경이 인수인계 문서 범위인지 확인한다.
3. 설계 문서만 별도 커밋하여 이후 변경의 판단 기준을 고정한다.

검증:

```bash
git diff --check
git status --short --branch
```

## Task 2: 코드 기준 운영 문서 현행화

**Files:**
- Modify: `docs/file_check_reboot-behavior.md`
- Modify: `docs/pim-guardian-runbook.md`
- Modify: `docs/runbook_final_stall.md`
- Modify: `docs/session-lifecycle.md`
- Modify: `docs/ord_vcm_conf-settings-analysis.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `test/test_final_stall_scenarios.md`

1. `file_check_reboot`, `disconnect_max_sec`, FINAL STALL 및 세션 종료 조건을 현재 코드와 대조한다.
2. 제거된 `audit_srt_enable.sh`, `migrate_srt_enable.sh`를 현행 명령으로 안내하는 부분을 제거하거나 역사 기록으로 명확히 표시한다.
3. 변한 줄 번호 대신 설정 키, 함수, 로그 문자열을 근거로 설명한다.
4. 문서 명령과 경로가 실제 파일에 존재하는지 검사한다.

검증:

```bash
git diff --check
rg -n "audit_srt_enable|migrate_srt_enable|30초|2분" docs test/test_final_stall_scenarios.md
```

## Task 3: 동기화 allowlist와 보호 브랜치 가드

**Files:**
- Modify: `sync-to-gitlab.sh`
- Modify: `sync-from-gitlab.sh`
- Add: `test/sync_pim_scope_test.sh`
- Modify: `docs/GIT_RULES.md`

1. 실패하는 테스트로 선택 문서와 매니페스트만 복사되고 다른 `docs/`, `test/`, `.github/` 파일은 제외됨을 정의한다.
2. 저장소 경로를 환경변수로 덮어쓸 수 있게 하여 임시 저장소 테스트가 실제 작업 복제본을 건드리지 않도록 한다.
3. 양방향 스크립트에 동일한 파일 allowlist를 적용한다.
4. `sync-to-gitlab.sh --push`가 `master` 또는 `main`에서 파일 변경 전에 실패하도록 한다.
5. dry-run과 임시 저장소 테스트로 선택·제외·삭제 보호를 확인한다.

검증:

```bash
bash -n sync-to-gitlab.sh sync-from-gitlab.sh test/sync_pim_scope_test.sh
bash test/sync_pim_scope_test.sh
```

## Task 4: 선택 가능한 자동 바이너리 검증

**Files:**
- Add: `tools/run_binary_verification.sh`
- Add: `test/tools/run_binary_verification_test.sh`
- Modify: `build.sh`
- Modify: `docker/build.sh`
- Modify: `docs/docker-build.md`
- Modify: `docker/README.md`

1. 실패하는 테스트로 `off`, `warn`, `strict`의 종료 코드 계약을 정의한다.
2. 공통 실행 래퍼를 구현하고 기본 모드를 `warn`으로 둔다.
3. `build.sh`의 전체 빌드와 단일 모듈 빌드 종료 지점에서 래퍼를 호출한다.
4. Docker 빌드의 산출물 검사도 같은 모드를 따르게 하고 컨테이너에 모드를 전달한다.
5. 문서에 기본값, 비활성화 방법, 엄격 모드를 기록한다.

검증:

```bash
bash -n build.sh docker/build.sh tools/run_binary_verification.sh
bash test/tools/run_binary_verification_test.sh
python3 test/tools/verify_binaries_test.py
python3 tools/verify_binaries.py
```

## Task 5: Notion 구문서 수명주기 정리

**Notion pages:**
- `chk_cam_operate.sh 파일 검사·복구·재부팅 운영 명세`
- `file_check_reboot 동작 명세 (pim-package-jhw)`
- 관련 파일 인덱스·타이밍 참조 페이지

1. 쓰기 전 기존 페이지와 현재 참조 페이지를 다시 읽는다.
2. 구페이지 상단에 `대체됨` 표시와 현행 참조 링크를 추가한다.
3. 현재 참조 페이지가 GitHub `master` 코드의 파생 문서임을 유지한다.
4. 삭제나 휴지통 이동은 하지 않는다.

검증: 각 페이지를 다시 조회해 대체 표식과 링크를 확인한다.

## Task 6: 로컬 통합 검증과 리뷰

1. 코드 그래프로 변경 위험과 영향 흐름을 확인한다.
2. 셸 구문, 동기화 테스트, 바이너리 도구 테스트, 카메라 링크 테스트를 실행한다.
3. 문서의 파일·설정 키·제거 도구 참조를 검색한다.
4. 하드웨어가 필요한 FINAL STALL 보드 매트릭스는 별도로 미실행 표시한다.

검증:

```bash
git diff --check
bash test/cam_link/run_all.sh
bash test/test_init_cam_cleanup.sh
bash test/sync_pim_scope_test.sh
bash test/tools/run_binary_verification_test.sh
python3 test/tools/verify_binaries_test.py
```

## Task 7: GitHub `master` 반영

1. `origin`을 다시 fetch한다.
2. `master`와 `origin/master`가 fast-forward 가능한 상태인지 확인한다.
3. 변경을 목적별 커밋으로 나눈다.
4. GitHub `master`만 푸시하고 원격 SHA 일치를 확인한다.

중단 조건: 원격에 예상하지 못한 선행 커밋이 있거나 테스트가 실패하면 푸시하지 않는다.

## Task 8: GitLab 기능 브랜치 동기화

1. GitLab 로컬 작업 복제본의 변경 유무와 현재 브랜치를 확인한다.
2. `feat/cam-link-diagnostics`를 원격 최신 상태로 맞춘다.
3. GitLab `master`의 작업 전 SHA를 기록한다.
4. `sync-to-gitlab.sh --dry-run pim` 결과의 추가·수정·삭제를 검토한다.
5. `sync-to-gitlab.sh --commit pim`으로 로컬 커밋까지만 만든다.
6. 커밋 diff를 검토하고 대상 ref를 명시해 기능 브랜치에 푸시한다.
7. GitLab `master` SHA 불변, 기능 브랜치 원격 SHA 일치, allowlist 외 문서 미변경을 확인한다.

중단 조건: 삭제 가드 발생, GitLab 전용 변경 덮어쓰기 의심, 대상 브랜치 불일치, 보호 브랜치 SHA 변화 중 하나라도 발생하면 푸시하지 않는다.
