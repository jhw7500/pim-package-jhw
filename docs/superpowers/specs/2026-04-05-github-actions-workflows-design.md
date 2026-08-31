# GitHub Actions 워크플로우 설계

## 개요

pim-package-jhw GitHub 레포에 CI/CD 및 AI 자동화 워크플로우를 구축한다.
Hybrid 접근법: AI 워크플로우는 `jhw7500/automation` 공유 레포를 재사용하고,
CI/빌드/릴리즈는 프로젝트 고유 standalone 워크플로우로 구성한다.

## 파일 구조

```
.github/
  workflow-config.yml              # 워크플로우 enable/disable 토글 + automation_ref 버전 핀
  commitlint.config.js             # conventional commits 규칙 설정
  workflows/
    # === AI 자동화 (jhw7500/automation 호출) ===
    claude-code-review.yml         # PR 열릴 때 자동 Claude 코드 리뷰
    claude.yml                     # @claude 멘션으로 Issue/PR 대화
    gemini-auto-review.yml         # PR 열릴 때 자동 Gemini 리뷰
    gemini-dispatch.yml            # PR/Issue 이벤트 중앙 디스패처
    gemini-issue-triage.yml        # 수동 이슈 분류 (workflow_dispatch)
    gemini-scheduled-triage.yml    # 자동 이슈 분류 (스케줄/수동)
    bump-automation-ref.yml        # workflow-config.yml 버전 변경 시 모든 ref 자동 업데이트 PR

    # === 프로젝트 고유 (standalone) ===
    shellcheck.yml                 # 셸 스크립트 정적 분석
    commitlint.yml                 # conventional commits 규칙 검사
    release.yml                    # 태그 push 시 릴리즈 패키지 생성
    update-binaries.yml            # max9296/gstApp/sc16is7xx 바이너리 자동 업데이트
```

## 1. AI 자동화 워크플로우

### 설계 원칙

- `jhw7500/automation@v1.28`의 공유 워크플로우를 `uses:`로 호출
- 프로젝트별 파일은 트리거 + 권한 + `uses:` 호출만 포함 (로직 없음)
- `workflow-config.yml`에서 enable/disable 토글 관리
- `bump-automation-ref.yml`로 버전 업데이트 자동화

### claude-code-review.yml

- 트리거: `pull_request: [opened, synchronize]`
- fork PR 제외 (`github.event.pull_request.head.repo.fork == false`)
- `jhw7500/automation/.github/workflows/claude-code-review.yml@v1.28` 호출

### claude.yml

- 트리거: `issue_comment`, `pull_request_review_comment`, `issues: [opened, assigned]`, `pull_request_review: [submitted]`
- `jhw7500/automation/.github/workflows/claude.yml@v1.28` 호출

### gemini-auto-review.yml

- 트리거: `pull_request: [opened, synchronize]`
- `jhw7500/automation/.github/workflows/gemini-auto-review.yml@v1.28` 호출

### gemini-dispatch.yml

- 트리거: `pull_request_review_comment`, `pull_request_review`, `pull_request: [opened]`, `issues: [opened, reopened]`, `issue_comment`
- `jhw7500/automation/.github/workflows/gemini-dispatch.yml@v1.28` 호출

### gemini-issue-triage.yml

- 트리거: `workflow_dispatch` (issue_number 입력)
- 이슈 정보 fetch 후 `jhw7500/automation/.github/workflows/gemini-triage.yml@v1.28` 호출

### gemini-scheduled-triage.yml

- 트리거: `workflow_dispatch`
- `jhw7500/automation/.github/workflows/gemini-scheduled-triage.yml@v1.28` 호출
- 기본 disabled (workflow-config.yml에서 `enabled: false`)

### bump-automation-ref.yml

- 트리거: `.github/workflow-config.yml` 변경 push
- `workflow-config.yml`의 `automation_ref` 값이 바뀌면 모든 워크플로우 파일의 `@vX.XX` 참조를 자동 업데이트하는 PR 생성

## 2. 프로젝트 고유 워크플로우

### shellcheck.yml

- 트리거: `**.sh` 파일 변경 시 push/PR + `workflow_dispatch`
- `vars.SHELLCHECK_ENABLED` 게이트
- 대상 파일:
  - `build.sh`
  - `dist/` 내 셸 스크립트 (존재하는 것만)
  - `tools/` 내 스크립트 (존재하는 것만)
- `shellcheck -x -s bash -S error -f gcc`로 에러 수준만 차단 (경고는 통과)
- `$GITHUB_STEP_SUMMARY`에 결과 출력

### commitlint.yml

- 트리거: `pull_request: [opened, synchronize, reopened]`
- `vars.COMMITLINT_ENABLED` 게이트
- `wagoid/commitlint-github-action@v6` 사용
- conventional commits 규칙 적용:
  - type: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `build`, `ci`, `perf`, `style`
  - scope: 선택사항
  - 한글 subject 허용 (max-length: 100)
- `.github/commitlint.config.js` 설정 파일:
  ```js
  module.exports = {
    extends: ['@commitlint/config-conventional'],
    rules: {
      'header-max-length': [2, 'always', 100],
      'subject-empty': [2, 'never'],
      'type-empty': [2, 'never'],
      'type-enum': [2, 'always', [
        'feat', 'fix', 'chore', 'refactor', 'docs',
        'test', 'build', 'ci', 'perf', 'style'
      ]],
      // 한글 커밋 메시지 허용
      'subject-case': [0],
    },
  };
  ```

### release.yml

- 트리거: `v*` 태그 push
- 동작:
  1. checkout
  2. `dist/` 기반 tar.gz 아카이브 생성: `pim-package-$TAG.tar.gz`
  3. `softprops/action-gh-release@v2`로 GitHub Release 생성
  4. `generate_release_notes: true`로 변경사항 자동 요약
- 아티팩트: tar.gz 파일 첨부

### update-binaries.yml

- 트리거:
  - `repository_dispatch: [binary-update]` (소스 레포에서 호출)
  - `workflow_dispatch` (수동, source 입력)
- 동작:
  1. checkout
  2. 소스별 아티팩트 다운로드:
     - max9296/sc16is7xx: `*.ko` -> `dist/modules/`
     - gstApp: `gstApp*` -> `dist/bin/`
  3. `peter-evans/create-pull-request@v6`으로 자동 PR 생성
- 소스 레포 측 설정 (별도 작업):
  - `peter-evans/repository-dispatch@v3`로 pim-package-jhw에 이벤트 전송
  - `secrets.PIM_PACKAGE_PAT` 필요 (repo 권한)

## 3. workflow-config.yml

```yaml
automation_ref: v1.28

workflows:
  shellcheck:
    enabled: true
    description: "Shell script static analysis"
  commitlint:
    enabled: true
    description: "Conventional commits enforcement"
  claude:
    enabled: true
    description: "Claude AI integration (@claude mention)"
  claude-code-review:
    enabled: true
    auto: true
    description: "Claude automatic PR review"
  gemini-dispatch:
    enabled: true
    description: "Central dispatcher for Gemini commands"
  gemini-auto-review:
    enabled: true
    auto: true
    description: "Automatic PR review with Gemini"
  gemini-scheduled-triage:
    enabled: false
    description: "Scheduled issue triage (disabled by default)"
```

## 4. Git LFS 설정

`.gitattributes`에 바이너리 트래킹 규칙 추가:

```
*.ko filter=lfs diff=lfs merge=lfs -text
dist/**/*.bin filter=lfs diff=lfs merge=lfs -text
dist/bin/gstApp* filter=lfs diff=lfs merge=lfs -text
```

## 5. GitHub Repo Variables 설정 (수동)

GitHub Settings > Secrets and variables > Actions > Variables에서:

| Variable | Value | 용도 |
|----------|-------|------|
| `SHELLCHECK_ENABLED` | `true` | shellcheck 워크플로우 활성화 |
| `COMMITLINT_ENABLED` | `true` | commitlint 워크플로우 활성화 |

## 6. GitHub Secrets 설정 (수동)

소스 레포(max9296 등)에서 pim-package-jhw로 dispatch 이벤트를 보내려면:

| Secret | 용도 |
|--------|------|
| `PIM_PACKAGE_PAT` | repository_dispatch용 PAT (repo 권한) |

automation 공유 워크플로우에 필요한 secrets는 `secrets: inherit`로 전달.
기존 wlan-package에서 사용 중인 secrets가 동일하게 필요.

## 구현 순서

1. `.github/workflow-config.yml` + `.github/commitlint.config.js` 생성
2. AI 워크플로우 7개 생성 (wlan-package에서 복사)
3. `shellcheck.yml` 생성 (pim 파일 목록 맞춤)
4. `commitlint.yml` 생성
5. `release.yml` 생성
6. `update-binaries.yml` 생성
7. `.gitattributes` LFS 규칙 추가
8. `bump-automation-ref.yml` 생성
9. 커밋 + push
10. GitHub repo variables/secrets 수동 설정 안내
