#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sync-pim-scope.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

write_fixture() {
    local root=$1 path=$2 content=$3
    mkdir -p "$root/$(dirname "$path")"
    printf '%s\n' "$content" > "$root/$path"
}

assert_same() {
    cmp -s "$1" "$2" || fail "파일 내용 불일치: $1 != $2"
}

assert_absent() {
    [ ! -e "$1" ] || fail "동기화 제외 파일이 생성됨: $1"
}

git_init() {
    local repo=$1 branch=$2
    git -C "$repo" init -q -b "$branch"
    git -C "$repo" config user.name "sync scope test"
    git -C "$repo" config user.email "sync-scope@example.invalid"
}

# 명령이 실패하고 로그에 기대한 거부 사유가 있어야 한다. 다른 이유로 실패한 것을
# 통과로 읽지 않으려고 사유 문구까지 확인한다.
expect_refusal() {
    local label=$1 reason=$2 log=$3
    shift 3
    if "$@" >"$log" 2>&1; then
        fail "${label}: 실행이 허용됨"
    fi
    grep -qF -- "$reason" "$log" || fail "${label}: 거부 사유가 다름 — $(tail -n 1 "$log")"
}

# 이 검사는 저장소 경로 환경변수를 무시하는 회귀를 잡는다. dry-run만 사용하므로
# 구현 전에도 실제 작업 복제본을 수정하지 않는다.
missing_source="$TMP_ROOT/missing-source"
missing_target="$TMP_ROOT/missing-target"
if GITHUB_REPO="$missing_source" GITLAB_REPO="$missing_target" \
        bash "$ROOT/sync-to-gitlab.sh" --dry-run pim >"$TMP_ROOT/missing-to.log" 2>&1; then
    fail "sync-to-gitlab.sh가 테스트용 누락 경로 대신 하드코딩 경로를 사용함"
fi
if GITHUB_REPO="$missing_source" GITLAB_REPO="$missing_target" \
        bash "$ROOT/sync-from-gitlab.sh" --dry-run pim >"$TMP_ROOT/missing-from.log" 2>&1; then
    fail "sync-from-gitlab.sh가 테스트용 누락 경로 대신 하드코딩 경로를 사용함"
fi

github="$TMP_ROOT/github"
gitlab="$TMP_ROOT/gitlab"
mkdir -p "$github" "$gitlab"

selected=(
    "docs/file_check_reboot-behavior.md"
    "docs/pim-guardian-runbook.md"
    "docs/runbook_final_stall.md"
    "docs/session-lifecycle.md"
    "docs/ord_vcm_conf-settings-analysis.md"
    "test/test_final_stall_scenarios.md"
)

for path in "${selected[@]}"; do
    write_fixture "$github" "$path" "github selected: $path"
done
write_fixture "$github" "dist/pim/code.txt" "github dist"
write_fixture "$github" "tools/tool.txt" "github tool"
write_fixture "$github" "docker/README.md" "github docker"
write_fixture "$github" "build.sh" "github build"
write_fixture "$github" "docs/github-only.md" "do not sync"
write_fixture "$github" "test/github-only.sh" "do not sync"
write_fixture "$github" "test/tools/github-only.sh" "do not sync nested tools"
write_fixture "$github" ".github/binary-manifest.json" "github local manifest"
write_fixture "$github" ".github/workflows/github-only.yml" "do not sync"
write_fixture "$github" "dist/pim/opt/pim/driver/laird_backport.tar" \
    "github local Summit archive"

write_fixture "$gitlab" "docs/gitlab-only.md" "preserve gitlab doc"
write_fixture "$gitlab" "test/gitlab-only.sh" "preserve gitlab test"
write_fixture "$gitlab" ".github/binary-manifest.json" "gitlab repository local manifest"
write_fixture "$gitlab" ".github/workflows/gitlab-only.yml" "preserve gitlab workflow"
write_fixture "$gitlab" "dist/pim/opt/pim/driver/laird_backport.tar" \
    "gitlab local Summit archive"

# dry-run은 checksum으로 변경을 찾는다. 실제 복사도 같은 기준이어야 하므로,
# size와 mtime은 같지만 내용은 다른 선택 파일을 만든다.
write_fixture "$gitlab" "docs/session-lifecycle.md" \
    "gitlab selected: docs/session-lifecycle.md"
touch -r "$github/docs/session-lifecycle.md" "$gitlab/docs/session-lifecycle.md"

git_init "$github" master
git -C "$github" add -A
git -C "$github" commit -qm "fixture: github"

git_init "$gitlab" master
git -C "$gitlab" add -A
git -C "$gitlab" commit -qm "fixture: gitlab"
# GitLab 쪽 쓰기는 GitLab master에서 새로 만든 sync/github-* 브랜치에서만 한다.
git -C "$gitlab" switch -qc sync/github-fixture

# GITLAB_REPO에는 기본값이 없다. 미설정과 빈 문자열 모두 거부한다(git -C ""는 현재
# 디렉터리를 대상으로 삼는다). dry-run만 쓰므로 기본값이 남은 옛 스크립트로 돌려도
# 실제 작업 복제본을 바꾸지 않는다.
for script in sync-to-gitlab.sh sync-from-gitlab.sh; do
    expect_refusal "${script} GITLAB_REPO 미설정" "GITLAB_REPO가 필요하다" \
        "$TMP_ROOT/unset-${script}.log" \
        env -u GITLAB_REPO GITHUB_REPO="$github" bash "$ROOT/$script" --dry-run pim
    expect_refusal "${script} GITLAB_REPO 빈 값" "GITLAB_REPO가 필요하다" \
        "$TMP_ROOT/empty-${script}.log" \
        env GITHUB_REPO="$github" GITLAB_REPO= bash "$ROOT/$script" --dry-run pim
done

# 두 경로가 같은 Git 저장소면 같은 경로든 링크된 worktree든 거부한다.
git -C "$github" worktree add -q --detach "$TMP_ROOT/github-worktree"
for script in sync-to-gitlab.sh sync-from-gitlab.sh; do
    for same in "$github" "$TMP_ROOT/github-worktree"; do
        expect_refusal "${script} 같은 저장소 ${same##*/}" "같은 Git 저장소" \
            "$TMP_ROOT/same-${script}-${same##*/}.log" \
            env GITHUB_REPO="$github" GITLAB_REPO="$same" bash "$ROOT/$script" --dry-run pim
    done
done
git -C "$github" worktree remove --force "$TMP_ROOT/github-worktree"

# GITHUB_REPO를 생략하면 스크립트가 있는 저장소를 쓴다. 스크립트를 별도 fixture
# 저장소에 복사해 실행하고, 실제 작업 복제본이 아니라 그 저장소를 잡는지 본다.
self_source="$TMP_ROOT/self-source"
mkdir -p "$self_source"
git_init "$self_source" master
cp "$ROOT/sync-to-gitlab.sh" "$ROOT/sync-from-gitlab.sh" "$self_source/"
git -C "$self_source" add -A
git -C "$self_source" commit -qm "fixture: self source"
self_top=$(git -C "$self_source" rev-parse --show-toplevel)
for script in sync-to-gitlab.sh sync-from-gitlab.sh; do
    env -u GITHUB_REPO GITLAB_REPO="$gitlab" bash "$self_source/$script" --dry-run pim \
        >"$TMP_ROOT/default-${script}.log" 2>&1 || fail "${script}: GITHUB_REPO 생략 dry-run 실패"
    grep -qxF "GitHub: ${self_top}" "$TMP_ROOT/default-${script}.log" || \
        fail "${script}: GITHUB_REPO 기본값이 스크립트가 있는 저장소가 아님"
done

GITHUB_REPO="$github" GITLAB_REPO="$gitlab" \
    bash "$ROOT/sync-to-gitlab.sh" pim >"$TMP_ROOT/to.log"

for path in "${selected[@]}"; do
    assert_same "$github/$path" "$gitlab/$path"
done
assert_same "$github/dist/pim/code.txt" "$gitlab/dist/pim/code.txt"
assert_same "$github/tools/tool.txt" "$gitlab/tools/tool.txt"
assert_same "$github/docker/README.md" "$gitlab/docker/README.md"
assert_same "$github/build.sh" "$gitlab/build.sh"
assert_absent "$gitlab/docs/github-only.md"
assert_absent "$gitlab/test/github-only.sh"
assert_absent "$gitlab/test/tools/github-only.sh"
assert_absent "$gitlab/.github/workflows/github-only.yml"
[ "$(cat "$gitlab/.github/binary-manifest.json")" = "gitlab repository local manifest" ] || \
    fail "GitLab 저장소 전용 binary manifest가 덮어써짐"
[ "$(cat "$gitlab/dist/pim/opt/pim/driver/laird_backport.tar")" = \
    "gitlab local Summit archive" ] || fail "GitLab Summit tar가 정방향 sync로 덮어써짐"
[ -f "$gitlab/docs/gitlab-only.md" ] || fail "GitLab 전용 문서가 삭제됨"
[ -f "$gitlab/test/gitlab-only.sh" ] || fail "GitLab 전용 테스트가 삭제됨"
[ -f "$gitlab/.github/workflows/gitlab-only.yml" ] || fail "GitLab 전용 workflow가 삭제됨"

git -C "$gitlab" add -A
git -C "$gitlab" commit -qm "fixture: forward sync"

# 역방향도 같은 allowlist만 적용해야 한다.
write_fixture "$gitlab" "docs/session-lifecycle.md" "gitlab selected update"
write_fixture "$gitlab" "docs/gitlab-new-only.md" "do not sync back"
write_fixture "$gitlab" "test/tools/gitlab-new-only.sh" "do not sync nested tools back"
git -C "$gitlab" add -A
git -C "$gitlab" commit -qm "fixture: gitlab update"

GITHUB_REPO="$github" GITLAB_REPO="$gitlab" \
    bash "$ROOT/sync-from-gitlab.sh" pim >"$TMP_ROOT/from.log"

assert_same "$gitlab/docs/session-lifecycle.md" "$github/docs/session-lifecycle.md"
assert_absent "$github/docs/gitlab-new-only.md"
assert_absent "$github/test/tools/gitlab-new-only.sh"
[ "$(cat "$github/.github/binary-manifest.json")" = "github local manifest" ] || \
    fail "GitHub 저장소 전용 binary manifest가 덮어써짐"
[ "$(cat "$github/dist/pim/opt/pim/driver/laird_backport.tar")" = \
    "github local Summit archive" ] || fail "GitHub Summit tar가 역방향 sync로 덮어써짐"
[ -f "$github/docs/github-only.md" ] || fail "GitHub 전용 문서가 삭제됨"
[ -f "$github/test/tools/github-only.sh" ] || fail "GitHub 전용 중첩 test/tools 파일이 삭제됨"

git -C "$github" add -A
git -C "$github" commit -qm "fixture: reverse sync"

# PIM 자동 commit은 허용 경로만 stage해야 한다. 실제 작업 복제본에는 vsd 서브모듈
# 수정과 HANDOFF.md가 공존할 수 있으므로, 전역 git add -A는 인수인계 범위를 오염시킨다.
git -C "$gitlab" switch -qc sync/github-scoped-commit
write_fixture "$github" "docs/session-lifecycle.md" "scoped commit candidate"
git -C "$github" add -A
git -C "$github" commit -qm "fixture: scoped commit candidate"
write_fixture "$gitlab" "HANDOFF.md" "unrelated handoff"
write_fixture "$gitlab" "vsd/local-change.txt" "unrelated submodule-style change"

GITHUB_REPO="$github" GITLAB_REPO="$gitlab" \
    bash "$ROOT/sync-to-gitlab.sh" --commit pim >"$TMP_ROOT/scoped-commit.log"

if git -C "$gitlab" ls-tree -r --name-only HEAD | \
        grep -Eq '^(HANDOFF\.md|vsd/)'; then
    fail "PIM commit이 allowlist 밖 기존 작업을 포함함"
fi
[ -f "$gitlab/HANDOFF.md" ] || fail "PIM commit이 HANDOFF.md를 제거함"
[ -f "$gitlab/vsd/local-change.txt" ] || fail "PIM commit이 vsd 작업을 제거함"
git -C "$gitlab" switch -q master

# 보호 브랜치에서는 쓰기 모드가 파일 복사나 commit 전에 거부되어야 한다.
write_fixture "$github" "docs/session-lifecycle.md" "protected branch candidate"
git -C "$github" add -A
git -C "$github" commit -qm "fixture: protected branch candidate"
before_sha=$(git -C "$gitlab" rev-parse HEAD)
before_content=$(cat "$gitlab/docs/session-lifecycle.md")

# 모드 우선순위는 dry-run > push다. 실제 쓰기가 없으므로 보호 브랜치에서도
# 시뮬레이션은 허용하고 작업 트리를 바꾸지 않아야 한다.
if ! GITHUB_REPO="$github" GITLAB_REPO="$gitlab" \
        bash "$ROOT/sync-to-gitlab.sh" --dry-run --push pim \
        >"$TMP_ROOT/protected-dry-run.log" 2>&1; then
    fail "보호 브랜치에서 쓰기 없는 --dry-run까지 거부됨"
fi
[ "$(git -C "$gitlab" rev-parse HEAD)" = "$before_sha" ] || \
    fail "보호 브랜치 dry-run이 GitLab commit을 생성함"
[ "$(cat "$gitlab/docs/session-lifecycle.md")" = "$before_content" ] || \
    fail "보호 브랜치 dry-run이 GitLab 파일을 변경함"

# 쓰기 모드 셋(파일만·--commit·--push) 모두 sync/github-* 브랜치에서만 허용한다.
# master·main뿐 아니라 다른 기능 브랜치와 detached HEAD도 거부하고, 거부 뒤에도
# HEAD와 파일 내용이 그대로여야 한다.
assert_refused_without_write() {
    local label=$1 log=$2
    shift 2
    local head content
    head=$(git -C "$gitlab" rev-parse HEAD)
    content=$(cat "$gitlab/docs/session-lifecycle.md")
    expect_refusal "$label" "sync/github-<날짜>" "$log" "$@"
    [ "$(git -C "$gitlab" rev-parse HEAD)" = "$head" ] || fail "${label}: GitLab commit이 생성됨"
    [ "$(cat "$gitlab/docs/session-lifecycle.md")" = "$content" ] || \
        fail "${label}: GitLab 파일이 바뀜"
}

for mode in "" --commit --push; do
    assert_refused_without_write "master ${mode:-파일만}" "$TMP_ROOT/master${mode}.log" \
        env GITHUB_REPO="$github" GITLAB_REPO="$gitlab" \
        bash "$ROOT/sync-to-gitlab.sh" ${mode:+"$mode"} pim
done
git -C "$gitlab" switch -qc feat/other
for mode in "" --commit --push; do
    assert_refused_without_write "feat/other ${mode:-파일만}" "$TMP_ROOT/feat${mode}.log" \
        env GITHUB_REPO="$github" GITLAB_REPO="$gitlab" \
        bash "$ROOT/sync-to-gitlab.sh" ${mode:+"$mode"} pim
done
git -C "$gitlab" switch -q --detach
assert_refused_without_write "detached 파일만" "$TMP_ROOT/detached.log" \
    env GITHUB_REPO="$github" GITLAB_REPO="$gitlab" bash "$ROOT/sync-to-gitlab.sh" pim
git -C "$gitlab" switch -q master

# 서브모듈 대상은 서브모듈과 GitLab 본체를 모두 검사한다. 서브모듈을 commit하면
# 본체에도 .last-sync-<scope>와 서브모듈 참조 commit을 쓰기 때문이다.
write_fixture "$github" "ord/main.txt" "github ord"
git -C "$github" add -A
git -C "$github" commit -qm "fixture: ord"
mkdir -p "$gitlab/ord"
git_init "$gitlab/ord" master
write_fixture "$gitlab/ord" "main.txt" "gitlab ord"
git -C "$gitlab/ord" add -A
git -C "$gitlab/ord" commit -qm "fixture: gitlab ord"

git -C "$gitlab/ord" switch -qc sync/github-ord
expect_refusal "본체 master·서브모듈 sync 브랜치" "sync/github-<날짜>" "$TMP_ROOT/sub-parent.log" \
    env GITHUB_REPO="$github" GITLAB_REPO="$gitlab" bash "$ROOT/sync-to-gitlab.sh" ord
[ "$(cat "$gitlab/ord/main.txt")" = "gitlab ord" ] || fail "본체가 master인데 서브모듈 파일이 바뀜"

git -C "$gitlab" switch -q sync/github-fixture
git -C "$gitlab/ord" switch -q master
expect_refusal "본체 sync 브랜치·서브모듈 master" "sync/github-<날짜>" "$TMP_ROOT/sub-child.log" \
    env GITHUB_REPO="$github" GITLAB_REPO="$gitlab" bash "$ROOT/sync-to-gitlab.sh" ord
[ "$(cat "$gitlab/ord/main.txt")" = "gitlab ord" ] || fail "서브모듈이 master인데 파일이 바뀜"

git -C "$gitlab/ord" switch -q sync/github-ord
GITHUB_REPO="$github" GITLAB_REPO="$gitlab" \
    bash "$ROOT/sync-to-gitlab.sh" ord >"$TMP_ROOT/sub-ok.log" 2>&1 || \
    fail "본체와 서브모듈이 모두 sync 브랜치인데 ord 동기화가 거부됨"
assert_same "$github/ord/main.txt" "$gitlab/ord/main.txt"

echo "PASS: repo paths, write branch guard, PIM allowlist, reverse scope, submodule guard"
