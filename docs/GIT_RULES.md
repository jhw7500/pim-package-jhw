# Git 커밋 규칙 (pim-package-jhw)

## 개요

이 레포는 GitHub에서 monorepo로 관리하며, GitLab 서브모듈 구조와 동기화한다.
커밋 시 **모듈 단위 분리**를 필수로 지켜야 동기화 스크립트가 정상 동작한다.

## 작업 순서와 push 승인

1. `pim-package-jhw`에서 변경·문서·바이너리·검증을 먼저 완료한다.
2. 로컬 커밋과 전체 검증 결과를 확인한다.
3. 사용자 승인을 받은 뒤에만 GitHub로 push한다.
4. GitHub 반영이 끝난 뒤 회사 GitLab 기능 브랜치 동기화를 시작한다.
5. GitLab도 로컬 커밋과 diff를 먼저 확인하고, 별도 사용자 승인 후 push한다.

GitHub와 GitLab 모두 승인 없는 원격 push를 하지 않는다. 회사 GitLab의
`master`에는 직접 push하지 않고 기능 브랜치와 MR을 사용한다.

## 커밋 메시지 형식

[Conventional Commits](https://www.conventionalcommits.org/) 기반:

```
<type>(<scope>): <subject>

[body]
```

### Type (필수)

| Type | 용도 |
|------|------|
| `feat` | 새 기능 |
| `fix` | 버그 수정 |
| `chore` | 빌드, 바이너리 업데이트, 잡일 |
| `refactor` | 리팩터링 (기능 변경 없음) |
| `docs` | 문서 |
| `test` | 테스트 |
| `build` | 빌드 시스템 변경 |
| `ci` | CI/CD 워크플로우 변경 |
| `perf` | 성능 개선 |
| `style` | 코드 스타일 (포맷팅 등) |

### Scope (필수)

커밋이 영향을 주는 모듈을 scope로 지정한다.
**하나의 커밋에 하나의 scope만 사용한다.**

| Scope | 대상 디렉토리 | GitLab 동기화 대상 |
|-------|-------------|-------------------|
| `ord` | `ord/` | GitLab 서브모듈: `hwjo/ord.git` |
| `vcm` | `vcm/` | GitLab 서브모듈: `hwjo/_vcm.git` |
| `vsd` | `vsd/` | GitLab 서브모듈: `mhkim/vsd.git` |
| `dist` | `dist/` | GitLab pim-package 본체 |
| `pim` | `build.sh`, `patch/`, `upgrade_file/`, `tools/`, `release/` 등 | GitLab pim-package 본체 |
| `ci` | `.github/` | GitHub 전용 (GitLab 동기화 안 함) |
| `docs` | `docs/` | GitHub 전용 (GitLab 동기화 안 함) |

### Subject (필수)

- 한글 또는 영문
- 최대 100자
- 마침표 없음

## 핵심 규칙: 모듈 분리 커밋

### 규칙 1: 하나의 커밋에 하나의 scope

```bash
# 좋음
git commit -m "feat(ord): TCP 서버 타임아웃 추가"
git commit -m "fix(vcm): IPC 버퍼 크기 조정"

# 나쁨 — 여러 모듈 섞임
git commit -m "feat: ord TCP 타임아웃 + vcm IPC 수정"
```

### 규칙 2: scope가 다른 파일을 같이 stage하지 않음

```bash
# 좋음
git add ord/
git commit -m "feat(ord): TCP 서버 타임아웃 추가"
git add vcm/
git commit -m "fix(vcm): IPC 버퍼 크기 조정"

# 나쁨
git add ord/ vcm/
git commit -m "feat: 여러 수정"
```

### 규칙 3: dist 바이너리 업데이트는 별도 커밋

```bash
git add dist/modules/max9296.ko
git commit -m "chore(dist): max9296 바이너리 업데이트 (v2.1)"
```

### 규칙 4: CI/docs 변경은 GitLab 동기화 불필요 표시

```bash
git commit -m "ci: shellcheck 워크플로우 추가"
git commit -m "docs: GIT_RULES 문서 추가"
```

## GitLab 동기화

### 동기화 대상

| GitHub scope | GitLab 대상 | 방법 |
|-------------|------------|------|
| `ord` | `hwjo/ord.git` 서브모듈 | rsync → 서브모듈 레포 push |
| `vcm` | `hwjo/_vcm.git` 서브모듈 | rsync → 서브모듈 레포 push |
| `vsd` | `mhkim/vsd.git` 서브모듈 | rsync → 서브모듈 레포 push |
| `dist/`, `patch/`, `upgrade_file/`, `tools/`, `docker/`, `build.sh` | `jkpark/pim-package` 본체 | PIM 코드 allowlist |
| 인수인계 문서 5개 + FINAL STALL 테스트 명세 | `jkpark/pim-package` 본체 | 파일 allowlist |
| `.github/binary-manifest.json` | 각 저장소 로컬 | 동기화 안 함 — 저장소별 바이너리 증명서 |
| 그 밖의 `docs/`, `test/`, `.github/workflows/` | 동기화 안 함 | GitHub 전용 또는 저장소별 문서 |

정확한 파일 목록은 `sync-to-gitlab.sh`와 `sync-from-gitlab.sh`의
`PIM_FILES`가 양방향 공통 계약이다. `release/`는 빌드 산출물이므로 포함하지 않는다.
`sc16is7xx_ext.ko`는 두 저장소가 의도적으로 다른 정식 바이너리를 유지하므로,
`.github/binary-manifest.json`도 자동 동기화하지 않는다. 각 저장소에서 실제
바이너리와 함께 갱신하고 `tools/verify_binaries.py --strict`로 검증한다.

### 동기화 스크립트

```bash
# 특정 모듈만
./sync-to-gitlab.sh ord

# PIM 본체 변경 검토 후 로컬 GitLab commit까지만 생성
./sync-to-gitlab.sh --dry-run pim
./sync-to-gitlab.sh --commit pim
```

`--push`는 대상 GitLab 저장소가 `master`, `main` 또는 detached HEAD이면 파일을
복사하기 전에 중단한다. 실제 푸시는 기능 브랜치를 확인한 뒤 대상 ref를 명시한다.
현재 인수인계 대상은 `feat/cam-link-diagnostics`이며 GitLab `master`에는 푸시하지
않는다.

테스트나 별도 작업 복제본에서는 `GITHUB_REPO`, `GITLAB_REPO` 환경변수로 기본
경로를 덮어쓸 수 있다.

동기화 커밋 메시지에 GitHub 커밋 내역이 자동으로 포함된다:

```
sync: GitHub 반영 (2026-04-05)

- feat(ord): TCP 서버 타임아웃 추가 (abc1234)
- fix(ord): null 체크 누락 수정 (def5678)
```

## 예시 워크플로우

```bash
# 1. ord에서 기능 개발
vi ord/main.cpp
git add ord/
git commit -m "feat(ord): TCP 서버 타임아웃 추가"

# 2. vcm 버그 수정
vi vcm/ipc.cpp
git add vcm/
git commit -m "fix(vcm): IPC 버퍼 오버플로우 수정"

# 3. 바이너리 업데이트
cp /path/to/new/max9296.ko dist/modules/
git add dist/modules/max9296.ko
git commit -m "chore(dist): max9296 바이너리 업데이트 (v2.1)"

# 4. 전체 검증 후 사용자 승인을 받아 GitHub에 push
git push origin master

# 5. GitLab 기능 브랜치에서 dry-run과 commit
./sync-to-gitlab.sh --dry-run pim
./sync-to-gitlab.sh --commit pim

# 6. diff 검토 후 별도 사용자 승인을 받아 기능 브랜치를 명시해 push
git -C /home/jhw/ai/opencode/projects/pim-package \
  push origin HEAD:refs/heads/feat/cam-link-diagnostics
```
