# GitHub–GitLab SSoT 인수인계 설계

**상태:** 승인됨 (2026-08-25)

**목표:** `pim-package-jhw`의 GitHub `master`를 PIM 코드의 단일 정본으로 두고, 검증된 변경만 GitLab 기능 브랜치로 전달한다. 저장소 문서와 Notion은 이 코드에서 파생된 설명 자료로 유지한다.

## 정본 우선순위

1. GitHub `master`에 커밋된 현재 코드가 실제 동작의 정본이다.
2. 저장소 문서는 같은 커밋의 코드를 설명해야 한다. 문서와 코드가 충돌하면 코드를 기준으로 문서를 고친다.
3. Notion은 결정 배경과 운영 맥락을 보존한다. 구현 세부가 저장소와 충돌하면 저장소를 따른다.
4. `release/`는 빌드 산출물이며 정본이나 동기화 입력이 아니다.

이 우선순위는 “미커밋 작업 디렉터리”를 정본으로 인정한다는 뜻이 아니다. 검증을 통과해 GitHub `master`에 커밋·푸시된 상태만 인수인계 기준이다.

## 저장소 경계

- GitHub 원격: `origin`
- GitLab 원격: `gitlab`
- GitLab 반영 대상: `feat/cam-link-diagnostics`
- GitLab `master`와 `main`에는 동기화 스크립트로 푸시하지 않는다.
- `ord`, `vcm`, `vsd`는 기존 서브모듈 매핑을 유지한다.
- `pim_gate`는 GitHub 저장소에 존재하지 않으므로 이번 GitHub 정본화와 PIM 본체 동기화에서 제외한다. 전체 패키지 빌드는 `pim_gate`가 있는 GitLab 작업 복제본에서 검증한다.
- GitLab 전용 변경은 GitHub 변경으로 덮기 전에 역방향 반영 여부를 검토한다. 이번 동기화에서도 GitLab 커밋을 삭제하거나 GitLab `master`를 재작성하지 않는다.

## PIM 동기화 범위

기존 PIM 코드 범위는 유지한다.

- 디렉터리: `dist/`, `patch/`, `upgrade_file/`, `tools/`, `docker/`
- 루트 파일: `build.sh`

모든 `docs/`와 `test/`를 복사하지 않고, 인수인계에 필요한 다음 파일만 양방향 allowlist로 관리한다.

- `docs/file_check_reboot-behavior.md`
- `docs/pim-guardian-runbook.md`
- `docs/runbook_final_stall.md`
- `docs/session-lifecycle.md`
- `docs/ord_vcm_conf-settings-analysis.md`
- `test/test_final_stall_scenarios.md`

바이너리 검증 도구가 실행 시 참조하는 `.github/binary-manifest.json`은 런타임 데이터 파일로 함께 동기화한다. `.github/workflows/`와 그 밖의 GitHub 전용 메타데이터는 동기화하지 않는다.

## 빌드 검증 정책

`build.sh`와 `docker/build.sh`의 기본 검증 모드는 `warn`이다. 바이너리 매니페스트나 산출물 검증에서 문제가 발견되어도 빌드 결과를 지우거나 기본 빌드를 차단하지 않고 경고를 남긴다.

- `PIM_VERIFY_BINARIES=off`: 자동 바이너리 검증 생략
- `PIM_VERIFY_BINARIES=warn`: 기본값. 검증 결과를 출력하되 빌드를 차단하지 않음
- `PIM_VERIFY_BINARIES=strict`: 검증 실패를 빌드 실패로 처리

매니페스트 갱신은 자동화하지 않는다. 바이너리 변경을 승인하는 작업자가 `tools/verify_binaries.py --update <경로>`를 명시적으로 실행하고 같은 커밋에서 검토해야 한다.

## 동기화 안전장치

1. 원격을 fetch하고 GitHub `master`와 `origin/master`의 선후 관계를 확인한다.
2. GitLab 대상 브랜치를 fetch하고 로컬 작업 복제본이 `feat/cam-link-diagnostics`인지 확인한다.
3. `sync-to-gitlab.sh --dry-run pim`의 변경·삭제 목록을 검토한다.
4. 실제 동기화는 우선 파일 또는 커밋까지만 수행한다. 스크립트의 `--push`는 보호 브랜치에서 거부되어야 한다.
5. GitLab 푸시는 대상 ref를 `feat/cam-link-diagnostics`로 명시한다. 암시적 `git push`로 `master`를 갱신하지 않는다.
6. 푸시 후 원격 브랜치 SHA와 트리 차이를 다시 조회한다.

## 문서와 Notion 수명주기

- 현행 운영 문서는 정확한 상수·조건·기본값을 코드에서 확인한다.
- 변하기 쉬운 줄 번호는 운영 계약으로 사용하지 않는다. 필요하면 함수명, 설정 키, 로그 문자열로 근거를 적는다.
- 역사적 기록은 지우지 않되, 제거된 도구를 현행 명령으로 오해할 수 있는 부분에는 `제거됨` 또는 `대체됨` 표시를 붙인다.
- 중복된 Notion 구문서는 삭제하지 않고 현재 참조 페이지로 대체되었음을 페이지 상단에 표시한다.
- 최종 인수인계 보고에는 실제로 실행한 검증과 실행하지 못한 하드웨어 검증을 구분한다.

## 완료 조건

- GitHub `master == origin/master`
- GitHub 작업 트리가 깨끗함
- 저장소 문서가 현재 코드와 모순되지 않음
- Notion의 현행 페이지는 GitHub `master`를 정본으로 지시하고 구페이지는 대체됨 표시
- 동기화 allowlist와 보호 브랜치 가드가 자동 테스트로 검증됨
- 빌드 검증 모드 `off`, `warn`, `strict` 계약이 자동 테스트로 검증됨
- GitLab `feat/cam-link-diagnostics`에 의도한 파일만 반영됨
- GitLab `master` SHA가 작업 전후 동일함
- 보드에서 실행하지 않은 항목은 완료로 보고하지 않음
