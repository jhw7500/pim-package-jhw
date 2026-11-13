# Git 커밋 규칙 (pim-package-jhw)

## 개요

이 레포는 GitHub에서 monorepo로 관리하며, GitLab 서브모듈 구조와 동기화한다.
커밋 시 **모듈 단위 분리**를 필수로 지켜야 동기화 스크립트가 정상 동작한다.

## 작업 순서와 push 승인

1. `pim-package-jhw`에서 변경·문서·바이너리·검증을 먼저 완료한다.
2. 로컬 커밋과 전체 검증 결과를 확인한다.
3. 사용자 승인을 받은 뒤에만 GitHub로 push한다.
4. GitHub 반영이 끝난 뒤 GitLab master에서 새 `sync/github-<날짜>` 브랜치를 만들어 동기화를 시작한다.
5. GitLab도 로컬 커밋과 diff를 먼저 확인하고, 별도 사용자 승인 후 push한다.

GitHub와 GitLab 모두 승인 없는 원격 push를 하지 않는다. 회사 GitLab의
`master`에는 push하거나 머지하지 않고, 동기화 결과는 `sync/github-<날짜>` 브랜치에만 올린다.

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
| `build.sh`가 패키지에 넣는 문서(`docs/max9296/V4L2_CTRL_GUIDE.md`, `docs/camera-startup-timing.md`) | `jkpark/pim-package` 본체 | 파일 allowlist |
| `.github/binary-manifest.json` | 각 저장소 로컬 | 동기화 안 함 — 저장소별 바이너리 증명서 |
| `dist/pim/opt/pim/driver/laird_backport.tar` | 각 저장소 로컬 | 검사·동기화 안 함 — Summit 아카이브는 별도 관리 |
| 그 밖의 `docs/`, `test/`, `.github/workflows/` | 동기화 안 함 | GitHub 전용 또는 저장소별 문서 |

정확한 파일 목록은 `sync-to-gitlab.sh`와 `sync-from-gitlab.sh`의
`PIM_FILES`가 양방향 공통 계약이다. `release/`는 빌드 산출물이므로 포함하지 않는다.
`sc16is7xx_ext.ko`는 두 저장소가 의도적으로 다른 정식 바이너리를 유지하므로,
`.github/binary-manifest.json`도 자동 동기화하지 않는다. 각 저장소에서 실제
바이너리와 함께 갱신하고 `tools/verify_binaries.py --strict`로 검증한다.
`laird_backport.tar`는 이 매니페스트 검사와 양방향 동기화에서 모두 제외하며,
GitHub·GitLab 패키지에 이미 있는 파일을 각각 그대로 보존한다.
`hantro_vc8000e_ext.ko`(VPU 인코더 수정 모듈, 소스 `jhw7500/imx-hantro`)는 `dist/`의 다른
드라이버처럼 GitLab으로 동기화한다. 사내 정식 패키지에도 #191 수정이 들어가야 하기 때문이다(#196).
매니페스트는 동기화하지 않으므로, 처음 반영할 때 GitLab 쪽 `.github/binary-manifest.json`에 같은
항목을 넣고 `tools/verify_binaries.py --strict`로 검증한다. 이 저장소는 이 파일을 LFS로 추적하므로,
동기화된 파일이 LFS 포인터가 아니라 실제 ELF인지도 확인한다.

`build.sh`가 `docs/`에서 패키지(`/opt/pim/docs/`)로 복사하는 문서는 모두 `PIM_FILES`에 있어야
한다. 빠지면 GitLab에서 만든 패키지에 옛 판이 실리거나 문서가 빠진다.
`test/sync_pim_scope_test.sh`가 이 조건과 두 스크립트의 `PIM_FILES`가 같은지를 검사한다.

### 역방향 동기화 주의

`sync-from-gitlab.sh`는 같은 allowlist를 `rsync --delete --checksum`으로 GitLab에서 GitHub로 쓴다.

- 실행 전에 `--dry-run`으로 덮어쓸 파일과 지울 파일을 확인한다. 덮어쓰기는 어느 쪽이 최신인지
  스크립트가 판단하지 못한다.
- 정방향 결과가 GitLab `master`에 머지되기 전에는 GitLab `master`의 파일이 GitHub보다 옛 판이다.
  이 상태에서 역방향을 돌리면 GitHub의 새 내용이 옛 판으로 바뀐다.
- GitHub이 추적하는 동기화 경로(`PIM_DIRS`의 디렉터리, `PIM_FILES`의 파일)가 GitLab에 통째로 없으면
  pim scope를 건너뛴다. 스크립트는 경고를 내고 0으로 끝난다. GitLab이 그 경로를 아직 받지 못한
  경우와 일부러 지운 경우를 구분할 수 없기 때문이다. 지우는 것이 맞으면 `--force`로 실행한다.
  삭제는 같은 commit에 들어간다. 디렉터리 안의 일부 파일 삭제는 이 검사 대상이 아니다.
- GitHub 작업 트리에서 추적 경로가 지워진 채 커밋되지 않은 상태도 로컬 수정으로 보고 건너뛴다.

### 동기화 스크립트

`GITLAB_REPO`에는 기본값이 없으므로 항상 GitLab 작업 복제본 경로를 지정한다.
`GITHUB_REPO`를 생략하면 스크립트가 있는 저장소를 쓴다. 두 경로가 같은 Git
저장소(링크된 worktree 포함)를 가리키면 스크립트가 중단한다.

```bash
export GITLAB_REPO=<GitLab 작업 복제본 경로>

# 동기화마다 GitLab master에서 sync 브랜치를 새로 만든다. 이전 sync 브랜치는 잇지 않는다.
# --no-track: upstream을 origin/master로 잡지 않아, 손으로 git push 해도 master로 가지 않는다.
git -C "$GITLAB_REPO" fetch --prune origin
git -C "$GITLAB_REPO" switch --no-track -c "sync/github-$(date +%F)" origin/master
git -C "$GITLAB_REPO" submodule update --init

# 특정 모듈만. 서브모듈을 동기화하면 그 서브모듈에도 같은 이름의 sync 브랜치를 만든다.
git -C "$GITLAB_REPO/ord" switch -c "sync/github-$(date +%F)"
./sync-to-gitlab.sh ord

# PIM 본체 변경 검토 후 로컬 GitLab commit까지만 생성
./sync-to-gitlab.sh --dry-run pim
./sync-to-gitlab.sh --commit pim
```

`--dry-run`이 아니면(파일만 sync, `--commit`, `--push`) 쓰려는 GitLab 저장소(본체와
대상 서브모듈)가 `sync/github-*` 브랜치일 때만 진행한다. `master`·`main`·detached
HEAD와 다른 기능 브랜치에서는 파일을 복사하기 전에 중단한다. `--push`는 검사한 sync
브랜치와 같은 이름의 `origin` 브랜치로만 push한다. 직접 push할 때도 대상 ref를 명시하고,
GitLab `master`에는 푸시하지 않는다.

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

# 5. GitLab 작업 복제본에서 sync 브랜치를 새로 만들고 dry-run과 commit
export GITLAB_REPO=<GitLab 작업 복제본 경로>
git -C "$GITLAB_REPO" fetch --prune origin
git -C "$GITLAB_REPO" switch --no-track -c "sync/github-$(date +%F)" origin/master
./sync-to-gitlab.sh --dry-run pim
./sync-to-gitlab.sh --commit pim

# 6. diff 검토 후 별도 사용자 승인을 받아 sync 브랜치를 명시해 push
git -C "$GITLAB_REPO" push origin "HEAD:refs/heads/sync/github-<날짜>"
```
