#!/bin/bash
set -euo pipefail

# =============================================================================
# sync-from-gitlab.sh — GitLab 회사 repo → GitHub 개인 monorepo 동기화
#
# 사용법:
#   ./sync-from-gitlab.sh ord                  # ord 파일만 sync (commit/push 없음)
#   ./sync-from-gitlab.sh --commit pim         # pim 파일 sync + commit (push 없음)
#   ./sync-from-gitlab.sh --push all           # ord+vcm+vsd+pim 전부 sync + commit + push
#   ./sync-from-gitlab.sh --dry-run all        # rsync 시뮬레이션만 (commit/push 없음)
#
# 모드 우선순위: --dry-run > 기본(파일만) < --commit < --push
#
# 전제: 사용자가 미리 GitLab repo와 ord/vcm/vsd 서브모듈을 git pull한 상태.
#
# 메시지 prefix `sync-back:` — sync-to-gitlab.sh의 filter_sync_back이 자동 제외하여
# 같은 변경이 다시 GitLab으로 mirror back 되는 것을 차단.
# 역방향: GitLab의 `sync: GitHub 반영` / `chore: 서브모듈 참조 업데이트` commit은
# loopback이므로 GitHub commit 메시지에서 제외.
# =============================================================================

GITHUB_REPO="/home/jhw/ai/opencode/projects/pim-package-jhw"
GITLAB_REPO="/home/jhw/ai/opencode/projects/pim-package"

# 서브모듈 매핑: scope → GitLab 서브모듈 경로
declare -A SUBMODULE_MAP=(
    [ord]="ord"
    [vcm]="vcm"
    [vsd]="vsd"
)

# pim 본체 동기화 대상 (서브모듈 외)
PIM_DIRS=("dist" "patch" "upgrade_file" "tools" "docker")
PIM_FILES=("build.sh")

DRY_RUN=false
DO_COMMIT=false
DO_PUSH=false
FORCE=false
TARGETS=()

# --- 인자 파싱 ---
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --commit)  DO_COMMIT=true ;;
        --push)    DO_COMMIT=true; DO_PUSH=true ;;
        --force)   FORCE=true ;;
        all)       TARGETS=("ord" "vcm" "vsd" "pim") ;;
        *)         TARGETS+=("$arg") ;;
    esac
done

if [ ${#TARGETS[@]} -eq 0 ]; then
    cat <<EOF
사용법: $0 [--dry-run|--commit|--push] [--force] <ord|vcm|vsd|pim|all> [...]

방향: GitLab → GitHub (sync-to-gitlab.sh의 역방향)
전제: GitLab repo와 ord/vcm/vsd 서브모듈을 미리 git pull한 상태

대상:
  ord, vcm, vsd  — 해당 서브모듈만 동기화
  pim            — dist, patch, upgrade_file, tools, docker, build.sh 동기화
  all            — 전부 동기화

모드 (기본은 파일만 sync, commit/push 없음):
  --dry-run      — rsync 시뮬레이션만 (실제 파일 변경 없음, 안전 검사 스킵)
  --commit       — 파일 sync + GitHub repo에 commit (push 없음)
  --push         — 파일 sync + commit + GitHub origin push

안전 검사 (rsync --delete가 로컬 수정/untracked 파일을 덮어쓰는 것 방지):
  기본          — 동기화 대상 경로에 modified/untracked 파일 있으면 해당 scope skip
  --force       — 안전 검사 우회 (위험: 로컬 수정사항 손실 가능)
EOF
    exit 1
fi

# --- 유틸 함수 ---
log() { echo "=== $1 ==="; }
warn() { echo "⚠ $1"; }

# 동기화 대상 경로에 로컬 수정/untracked 파일이 있는지 검사
# 인자: <scope> <path1> <path2> ...
# 반환: 0=clean, 1=dirty (이 경우 stderr에 dirty 파일 목록 출력)
# marker 파일(.last-sync-from-gitlab-{scope})은 스크립트가 갱신하므로 검사에서 제외
check_clean_paths() {
    local scope="$1"
    shift
    local paths=("$@")
    [ ${#paths[@]} -eq 0 ] && return 0

    # 존재하는 경로만 git status 검사 대상으로 사용
    local exist_paths=()
    local p
    for p in "${paths[@]}"; do
        [ -e "$GITHUB_REPO/$p" ] && exist_paths+=("$p")
    done
    [ ${#exist_paths[@]} -eq 0 ] && return 0

    local marker=".last-sync-from-gitlab-${scope}"
    local dirty
    dirty=$(git -C "$GITHUB_REPO" status --porcelain -- "${exist_paths[@]}" 2>/dev/null \
        | grep -v -E " ${marker}$" || true)

    if [ -n "$dirty" ]; then
        warn "scope '${scope}': 로컬 수정/untracked 파일 존재 — sync 차단"
        echo "$dirty" | sed 's/^/    /'
        echo "    → commit/stash 후 재시도, 또는 위험 감수 후 --force 사용"
        return 1
    fi
    return 0
}

# GitLab → GitHub 방향 loopback 제외:
#  - "sync: GitHub 반영" : sync-to-gitlab.sh가 GitHub→GitLab으로 푸시한 commit
#  - "chore: 서브모듈 참조 업데이트" : sync-to-gitlab.sh가 만드는 ref bump commit
filter_loopback() {
    grep -Ev '^[a-f0-9]+ (sync: GitHub 반영|chore: 서브모듈 참조 업데이트)' || true
}

# rsync dry-run으로 실제 변경/신규/삭제될 파일 목록만 추출 (디렉토리 제외)
# .last-sync-from-gitlab-* stale에 강건 — 변경되지 않은 파일의 commits는 자동 제외됨
rsync_dry_changed_files() {
    # --checksum: 기본 비교는 size+mtime 이라 내용이 같아도 mtime 만 다르면 변경으로
    # 잡힌다. 그 목록으로 커밋 메시지를 만들면 실제로 바뀌지 않은 파일이 딸려 온다.
    #
    # 종료코드를 확인한다. 삼키고 파이프로 넘기면 awk 의 상태만 남아, rsync 실패가
    # 빈 목록이 되어 '변경 없음'으로 읽힌다.
    local out rc=0 errf
    errf=$(mktemp)
    out=$(rsync -an --delete --checksum -i --out-format='%i|%n' \
        --filter=':- .gitignore' \
        --exclude='.git' \
        --exclude='upgrade_file/dpkg/pimwebserver_*.deb' \
        --exclude='dist/pim/opt/pim/driver/sc16is7xx_ext.ko' \
        "$@" 2>"$errf") || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "rsync 실패(rc=${rc}): $(head -3 "$errf" | tr '\n' ' ')" >&2
        rm -f "$errf"
        return 1
    fi
    rm -f "$errf"

    printf '%s\n' "$out" \
        | awk -F'|' '
            {
                c = substr($1, 1, 1)
                if (c == ">" || c == "<" || c == "c" || c == "*") {
                    if (substr($2, length($2), 1) != "/") print $2
                }
            }'
}

# 변경 파일에 한정한 git log 추출
# 인자: <repo_dir> <last_sync_file> <files...>
# 각 commit subject 뒤에 [실제 sync된 file 목록] 첨부 — file-level 책임 표시
git_log_for_files() {
    local repo_dir="$1"
    local last_sync_file="$2"
    shift 2
    local files=("$@")
    [ ${#files[@]} -eq 0 ] && return 0

    local log_range="-10"
    if [ -f "$last_sync_file" ]; then
        log_range="$(cat "$last_sync_file")..HEAD"
    fi

    local raw_log
    raw_log=$(git -C "$repo_dir" log --format='%H %s' $log_range -- "${files[@]}" 2>/dev/null \
        | filter_loopback)
    [ -z "$raw_log" ] && return 0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local sha=${line%% *}
        local subject=${line#* }
        local short=${sha:0:7}
        local commit_files
        commit_files=$(git -C "$repo_dir" show --name-only --format='' "$sha" 2>/dev/null || true)
        local matched=()
        local f
        for f in "${files[@]}"; do
            if grep -qFx -- "$f" <<< "$commit_files"; then
                matched+=("$f")
            fi
        done
        if [ ${#matched[@]} -gt 0 ]; then
            local IFS=','
            local files_str="${matched[*]}"
            echo "${short} ${subject} [${files_str//,/, }]"
        else
            echo "${short} ${subject}"
        fi
    done <<< "$raw_log"
}

# scope의 sync point 갱신
#  - pim       : GitLab 본체 HEAD SHA
#  - 서브모듈   : 각 서브모듈 HEAD SHA
# marker 위치 : GITHUB_REPO 루트의 .last-sync-from-gitlab-{scope}
save_sync_point() {
    local scope="$1"
    local source_dir
    if [ "$scope" = "pim" ]; then
        source_dir="$GITLAB_REPO"
    else
        source_dir="${GITLAB_REPO}/${SUBMODULE_MAP[$scope]}"
    fi
    local current_sha
    current_sha=$(git -C "$source_dir" rev-parse HEAD)
    echo "$current_sha" > "$GITHUB_REPO/.last-sync-from-gitlab-${scope}"
}

# commit/push 분기 처리
# args: $1=commit_msg, $2=label, $3=save_scope, $4=add_paths_str (공백 구분 경로)
finalize_commit() {
    local commit_msg="$1"
    local label="$2"
    local save_scope="$3"
    local add_paths_str="$4"

    cd "$GITHUB_REPO"

    if [ "$DO_COMMIT" = false ]; then
        echo "  [FILES-ONLY] 파일 sync 완료. GitHub repo 검토 후 수동 commit 필요"
        echo "    (--commit 또는 --push 옵션으로 자동 commit 가능)"
        return 0
    fi

    # marker 파일을 같은 commit에 포함시키기 위해 commit 전에 갱신
    save_sync_point "$save_scope"

    local marker_file=".last-sync-from-gitlab-${save_scope}"

    # 존재하는 경로만 add — 누락된 PIM_DIRS/FILES (예: 새 repo) 안전 처리
    local paths=()
    local p
    # shellcheck disable=SC2206
    local raw_paths=( $add_paths_str "$marker_file" )
    for p in "${raw_paths[@]}"; do
        [ -e "$p" ] && paths+=("$p")
    done

    if [ ${#paths[@]} -eq 0 ]; then
        echo "  add 대상 경로 없음 (스킵)"
        return 0
    fi

    git add -A -- "${paths[@]}"

    if git diff --cached --quiet; then
        echo "  변경사항 없음 (이미 동기화됨)"
        return 0
    fi

    git commit -m "$commit_msg"
    echo "  ${label} commit 완료"

    if [ "$DO_PUSH" = true ]; then
        git push
        echo "  ${label} push 완료"
    else
        echo "  [NO-PUSH] commit만 생성됨. push는 수동으로 실행하세요"
    fi
}

# --- 서브모듈 동기화 (GitLab 서브모듈 → GitHub 평탄 디렉토리) ---
sync_submodule() {
    local scope="$1"
    local subdir="${SUBMODULE_MAP[$scope]}"
    local sub_repo="${GITLAB_REPO}/${subdir}"

    log "${scope} 서브모듈 동기화 (GitLab → GitHub)"

    if [ ! -d "$sub_repo" ]; then
        warn "GitLab 서브모듈 디렉토리 없음: $sub_repo (스킵)"
        return 0
    fi

    # 안전 검사: dry-run/force가 아닌 경우 로컬 수정사항 검사
    if [ "$DRY_RUN" = false ] && [ "$FORCE" = false ]; then
        check_clean_paths "$scope" "$subdir" || return 1
    fi

    # 1. dry-run으로 변경 파일 추출
    local changed_files
    changed_files=$(rsync_dry_changed_files \
        "${sub_repo}/" "${GITHUB_REPO}/${subdir}/")

    if [ -z "$changed_files" ]; then
        echo "  동기화할 변경사항 없음 (${scope})"
        return 0
    fi

    # 2. 변경 파일에 한정한 GitLab 서브모듈 log 추출
    local file_args=()
    while IFS= read -r f; do
        [ -n "$f" ] && file_args+=("$f")
    done <<< "$changed_files"

    local commits
    commits=$(git_log_for_files "$sub_repo" \
        "$GITHUB_REPO/.last-sync-from-gitlab-${scope}" "${file_args[@]}")

    if [ -n "$commits" ]; then
        echo "  GitLab ${scope} 커밋:"
        echo "$commits" | sed 's/^/    /'
    else
        echo "  GitLab ${scope} 커밋: (변경 파일이 추적된 commits에 매핑되지 않음 — file restoration 가능성)"
        commits="(no matching commits — file restoration or out-of-band change)"
    fi

    # 3. rsync (GitLab 서브모듈 → GitHub 평탄 디렉토리)
    echo "  파일 복사: ${sub_repo}/ → ${GITHUB_REPO}/${subdir}/"

    if [ "$DRY_RUN" = true ]; then
        rsync -avn --delete --checksum \
            --filter=':- .gitignore' \
            --exclude='.git' \
            --exclude='upgrade_file/dpkg/pimwebserver_*.deb' \
            --exclude='dist/pim/opt/pim/driver/sc16is7xx_ext.ko' \
            "${sub_repo}/" "${GITHUB_REPO}/${subdir}/"
        echo "  [DRY-RUN] commit/push 건너뜀"
        return 0
    fi

    rsync -a --delete \
        --filter=':- .gitignore' \
        --exclude='.git' \
        --exclude='upgrade_file/dpkg/pimwebserver_*.deb' \
        --exclude='dist/pim/opt/pim/driver/sc16is7xx_ext.ko' \
        "${sub_repo}/" "${GITHUB_REPO}/${subdir}/"

    local sync_msg
    sync_msg="sync-back: GitLab ${scope} 반영 ($(date +%Y-%m-%d))"$'\n\n'
    sync_msg+=$(echo "$commits" | sed 's/^/- /')

    finalize_commit "$sync_msg" "${scope} 서브모듈" "$scope" "$subdir"
}

# --- pim 본체 동기화 ---
sync_pim() {
    log "pim 본체 동기화 (GitLab → GitHub)"

    # 안전 검사: dry-run/force가 아닌 경우 로컬 수정사항 검사
    if [ "$DRY_RUN" = false ] && [ "$FORCE" = false ]; then
        check_clean_paths "pim" "${PIM_DIRS[@]}" "${PIM_FILES[@]}" || return 1
    fi

    # PIM_DIRS + PIM_FILES을 단일 rsync include 패턴으로 통합
    # source가 GitLab repo 루트라 루트 .gitignore가 per-directory merge로 자동 적용
    local rsync_includes=()
    local d f
    for d in "${PIM_DIRS[@]}"; do
        rsync_includes+=(--include="${d}/" --include="${d}/**")
    done
    for f in "${PIM_FILES[@]}"; do
        rsync_includes+=(--include="${f}")
    done

    # 1. dry-run으로 변경 파일 추출
    local changed_files
    changed_files=$(rsync_dry_changed_files \
        "${rsync_includes[@]}" \
        --exclude='*' \
        "${GITLAB_REPO}/" "${GITHUB_REPO}/")

    if [ -z "$changed_files" ]; then
        echo "  동기화할 변경사항 없음 (pim)"
        return 0
    fi

    # 2. GitLab 본체 log 추출
    local file_args=()
    while IFS= read -r f; do
        [ -n "$f" ] && file_args+=("$f")
    done <<< "$changed_files"

    local commits
    commits=$(git_log_for_files "$GITLAB_REPO" \
        "$GITHUB_REPO/.last-sync-from-gitlab-pim" "${file_args[@]}")

    if [ -n "$commits" ]; then
        echo "  GitLab pim 커밋:"
        echo "$commits" | sed 's/^/    /'
    else
        echo "  GitLab pim 커밋: (변경 파일이 추적된 commits에 매핑되지 않음 — file restoration 가능성)"
        commits="(no matching commits — file restoration or out-of-band change)"
    fi

    echo "  복사: ${PIM_DIRS[*]} ${PIM_FILES[*]}"

    # 제외 규칙은 반드시 include 앞에 둔다. rsync 는 먼저 매칭되는 규칙이 이기므로
    # --include='upgrade_file/**' 뒤에 놓으면 도달하지 못해 무력화된다.
    # (sync-to-gitlab.sh 의 sync_pim 도 같은 문제였다.)
    if [ "$DRY_RUN" = true ]; then
        rsync -avn --delete --checksum \
            --filter=':- .gitignore' \
            --exclude='.git' \
            --exclude='upgrade_file/dpkg/pimwebserver_*.deb' \
            --exclude='dist/pim/opt/pim/driver/sc16is7xx_ext.ko' \
            "${rsync_includes[@]}" \
            --exclude='*' \
            "${GITLAB_REPO}/" "${GITHUB_REPO}/"
        echo "  [DRY-RUN] commit/push 건너뜀"
        return 0
    fi

    rsync -a --delete \
        --filter=':- .gitignore' \
        --exclude='.git' \
        --exclude='upgrade_file/dpkg/pimwebserver_*.deb' \
        --exclude='dist/pim/opt/pim/driver/sc16is7xx_ext.ko' \
        "${rsync_includes[@]}" \
        --exclude='*' \
        "${GITLAB_REPO}/" "${GITHUB_REPO}/"

    local sync_msg
    sync_msg="sync-back: GitLab pim 반영 ($(date +%Y-%m-%d))"$'\n\n'
    sync_msg+=$(echo "$commits" | sed 's/^/- /')

    local add_paths
    add_paths="${PIM_DIRS[*]} ${PIM_FILES[*]}"

    finalize_commit "$sync_msg" "pim 본체" "pim" "$add_paths"
}

# --- 메인 실행 ---
cd "$GITHUB_REPO"

log "동기화 시작 (GitLab → GitHub) ($(date '+%Y-%m-%d %H:%M:%S'))"
[ "$DRY_RUN" = true ] && warn "DRY-RUN 모드 — 실제 변경 없음"
[ "$DRY_RUN" = false ] && [ "$DO_COMMIT" = false ] && warn "FILES-ONLY 모드 — 파일만 sync, commit/push 없음"
[ "$DO_COMMIT" = true ] && [ "$DO_PUSH" = false ] && warn "COMMIT 모드 — commit만, push 없음"
[ "$DO_PUSH" = true ] && warn "PUSH 모드 — commit + push 자동 진행"
echo ""

for target in "${TARGETS[@]}"; do
    # 각 scope의 안전 검사 실패는 set -e를 우회해 다른 scope 진행 허용
    case "$target" in
        ord|vcm|vsd) sync_submodule "$target" || true ;;
        pim)         sync_pim || true ;;
        *)           warn "알 수 없는 대상: $target (ord, vcm, vsd, pim, all 중 선택)" ;;
    esac
    echo ""
done

log "동기화 완료"
