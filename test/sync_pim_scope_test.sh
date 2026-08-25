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
    ".github/binary-manifest.json"
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
write_fixture "$github" ".github/workflows/github-only.yml" "do not sync"

write_fixture "$gitlab" "docs/gitlab-only.md" "preserve gitlab doc"
write_fixture "$gitlab" "test/gitlab-only.sh" "preserve gitlab test"
write_fixture "$gitlab" ".github/workflows/gitlab-only.yml" "preserve gitlab workflow"

git_init "$github" master
git -C "$github" add -A
git -C "$github" commit -qm "fixture: github"

git_init "$gitlab" master
git -C "$gitlab" add -A
git -C "$gitlab" commit -qm "fixture: gitlab"

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
assert_absent "$gitlab/.github/workflows/github-only.yml"
[ -f "$gitlab/docs/gitlab-only.md" ] || fail "GitLab 전용 문서가 삭제됨"
[ -f "$gitlab/test/gitlab-only.sh" ] || fail "GitLab 전용 테스트가 삭제됨"
[ -f "$gitlab/.github/workflows/gitlab-only.yml" ] || fail "GitLab 전용 workflow가 삭제됨"

git -C "$gitlab" add -A
git -C "$gitlab" commit -qm "fixture: forward sync"

# 역방향도 같은 allowlist만 적용해야 한다.
write_fixture "$gitlab" "docs/session-lifecycle.md" "gitlab selected update"
write_fixture "$gitlab" "docs/gitlab-new-only.md" "do not sync back"
git -C "$gitlab" add -A
git -C "$gitlab" commit -qm "fixture: gitlab update"

GITHUB_REPO="$github" GITLAB_REPO="$gitlab" \
    bash "$ROOT/sync-from-gitlab.sh" pim >"$TMP_ROOT/from.log"

assert_same "$gitlab/docs/session-lifecycle.md" "$github/docs/session-lifecycle.md"
assert_absent "$github/docs/gitlab-new-only.md"
[ -f "$github/docs/github-only.md" ] || fail "GitHub 전용 문서가 삭제됨"

git -C "$github" add -A
git -C "$github" commit -qm "fixture: reverse sync"

# 보호 브랜치에서는 --push가 파일 복사나 commit 전에 거부되어야 한다.
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

if GITHUB_REPO="$github" GITLAB_REPO="$gitlab" \
        bash "$ROOT/sync-to-gitlab.sh" --push pim >"$TMP_ROOT/protected.log" 2>&1; then
    fail "GitLab master에서 --push가 허용됨"
fi

[ "$(git -C "$gitlab" rev-parse HEAD)" = "$before_sha" ] || \
    fail "보호 브랜치 검사 전에 GitLab commit이 생성됨"
[ "$(cat "$gitlab/docs/session-lifecycle.md")" = "$before_content" ] || \
    fail "보호 브랜치 검사 전에 GitLab 파일이 변경됨"

echo "PASS: PIM sync allowlist, reverse scope, protected branch guard"
