#!/bin/bash
set -euo pipefail

# =============================================================================
# sync-to-gitlab.sh — GitHub monorepo → GitLab 서브모듈 동기화
#
# 사용법:
#   ./sync-to-gitlab.sh ord          # ord만 동기화
#   ./sync-to-gitlab.sh vcm vsd      # vcm, vsd 동기화
#   ./sync-to-gitlab.sh all          # ord+vcm+vsd+pim 전부
#   ./sync-to-gitlab.sh --dry-run all # 실제 push 없이 미리보기
# =============================================================================

GITHUB_REPO="/home/jhw/ai/opencode/projects/pim-package-jhw"
GITLAB_REPO="/home/jhw/ai/opencode/projects/pim-package"

# 서브모듈 매핑: scope → GitLab 서브모듈 경로
declare -A SUBMODULE_MAP=(
    [ord]="ord"
    [vcm]="vcm"
    [vsd]="vsd"
)

# pim 본체 동기화 대상 디렉토리 (서브모듈 외)
PIM_DIRS=("dist" "patch" "upgrade_file" "tools" "release" "docker")
PIM_FILES=("build.sh")

DRY_RUN=false
TARGETS=()

# --- 인자 파싱 ---
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        all) TARGETS=("ord" "vcm" "vsd" "pim") ;;
        *) TARGETS+=("$arg") ;;
    esac
done

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "사용법: $0 [--dry-run] <ord|vcm|vsd|pim|all> [...]"
    echo ""
    echo "  ord, vcm, vsd  — 해당 서브모듈만 동기화"
    echo "  pim            — dist, patch, build.sh 등 본체 파일 동기화"
    echo "  all            — 전부 동기화"
    echo "  --dry-run      — 실제 push 없이 미리보기"
    exit 1
fi

# --- 유틸 함수 ---
log() { echo "=== $1 ==="; }
warn() { echo "⚠ $1"; }

get_github_commits() {
    local scope="$1"
    local last_sync_file="$GITLAB_REPO/.last-sync-${scope}"
    local since_commit=""

    if [ -f "$last_sync_file" ]; then
        since_commit=$(cat "$last_sync_file")
        git -C "$GITHUB_REPO" log --oneline "${since_commit}..HEAD" -- "${scope}/" 2>/dev/null || true
    else
        git -C "$GITHUB_REPO" log --oneline -10 -- "${scope}/" 2>/dev/null || true
    fi
}

get_pim_commits() {
    local last_sync_file="$GITLAB_REPO/.last-sync-pim"
    local since_commit=""
    local paths=()

    for d in "${PIM_DIRS[@]}"; do paths+=("${d}/"); done
    for f in "${PIM_FILES[@]}"; do paths+=("$f"); done

    if [ -f "$last_sync_file" ]; then
        since_commit=$(cat "$last_sync_file")
        git -C "$GITHUB_REPO" log --oneline "${since_commit}..HEAD" -- "${paths[@]}" 2>/dev/null || true
    else
        git -C "$GITHUB_REPO" log --oneline -10 -- "${paths[@]}" 2>/dev/null || true
    fi
}

save_sync_point() {
    local scope="$1"
    local current_sha
    current_sha=$(git -C "$GITHUB_REPO" rev-parse HEAD)
    echo "$current_sha" > "$GITLAB_REPO/.last-sync-${scope}"
}

# --- 서브모듈 동기화 ---
sync_submodule() {
    local scope="$1"
    local subdir="${SUBMODULE_MAP[$scope]}"

    log "${scope} 서브모듈 동기화"

    # GitHub 커밋 내역 수집
    local commits
    commits=$(get_github_commits "$scope")

    if [ -z "$commits" ]; then
        echo "  동기화할 변경사항 없음 (${scope})"
        return 0
    fi

    echo "  GitHub 커밋:"
    echo "$commits" | sed 's/^/    /'

    # rsync (GitHub → GitLab 서브모듈)
    echo "  파일 복사: ${GITHUB_REPO}/${subdir}/ → ${GITLAB_REPO}/${subdir}/"

    if [ "$DRY_RUN" = true ]; then
        rsync -avn --delete \
            --exclude='.git' \
            --exclude='build/' \
            "${GITHUB_REPO}/${subdir}/" "${GITLAB_REPO}/${subdir}/"
        echo "  [DRY-RUN] push 건너뜀"
        return 0
    fi

    rsync -a --delete \
        --exclude='.git' \
        --exclude='build/' \
        "${GITHUB_REPO}/${subdir}/" "${GITLAB_REPO}/${subdir}/"

    # GitLab 서브모듈에서 커밋 + push
    cd "${GITLAB_REPO}/${subdir}"

    if git diff --quiet && git diff --cached --quiet; then
        echo "  변경사항 없음 (이미 동기화됨)"
        cd "$GITHUB_REPO"
        return 0
    fi

    local sync_msg
    sync_msg="sync: GitHub 반영 ($(date +%Y-%m-%d))"$'\n\n'
    sync_msg+=$(echo "$commits" | sed 's/^/- /')

    git add -A
    git commit -m "$sync_msg"
    git push

    echo "  ${scope} 서브모듈 push 완료"
    cd "$GITHUB_REPO"

    save_sync_point "$scope"
}

# --- pim 본체 동기화 ---
sync_pim() {
    log "pim 본체 동기화"

    local commits
    commits=$(get_pim_commits)

    if [ -z "$commits" ]; then
        echo "  동기화할 변경사항 없음 (pim)"
        return 0
    fi

    echo "  GitHub 커밋:"
    echo "$commits" | sed 's/^/    /'

    # 디렉토리 복사
    for d in "${PIM_DIRS[@]}"; do
        if [ -d "${GITHUB_REPO}/${d}" ]; then
            echo "  복사: ${d}/"
            if [ "$DRY_RUN" = true ]; then
                rsync -avn --delete \
                    --exclude='.git' \
                    "${GITHUB_REPO}/${d}/" "${GITLAB_REPO}/${d}/"
            else
                rsync -a --delete \
                    --exclude='.git' \
                    "${GITHUB_REPO}/${d}/" "${GITLAB_REPO}/${d}/"
            fi
        fi
    done

    # 개별 파일 복사
    for f in "${PIM_FILES[@]}"; do
        if [ -f "${GITHUB_REPO}/${f}" ]; then
            echo "  복사: ${f}"
            if [ "$DRY_RUN" = false ]; then
                cp "${GITHUB_REPO}/${f}" "${GITLAB_REPO}/${f}"
            fi
        fi
    done

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] push 건너뜀"
        return 0
    fi

    # GitLab pim-package에서 커밋 + push
    cd "$GITLAB_REPO"

    if git diff --quiet && git diff --cached --quiet; then
        echo "  변경사항 없음 (이미 동기화됨)"
        cd "$GITHUB_REPO"
        return 0
    fi

    local sync_msg
    sync_msg="sync: GitHub 반영 ($(date +%Y-%m-%d))"$'\n\n'
    sync_msg+=$(echo "$commits" | sed 's/^/- /')

    git add -A
    git commit -m "$sync_msg"
    git push

    echo "  pim 본체 push 완료"
    cd "$GITHUB_REPO"

    save_sync_point "pim"
}

# --- 서브모듈 참조 업데이트 ---
update_submodule_refs() {
    log "GitLab pim-package 서브모듈 참조 업데이트"

    cd "$GITLAB_REPO"

    local changed=false
    for scope in "${!SUBMODULE_MAP[@]}"; do
        local subdir="${SUBMODULE_MAP[$scope]}"
        # 서브모듈 참조가 변경되었는지 확인
        if ! git diff --quiet -- "$subdir"; then
            changed=true
        fi
    done

    if [ "$changed" = false ]; then
        echo "  서브모듈 참조 변경 없음"
        cd "$GITHUB_REPO"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] 서브모듈 참조 커밋 건너뜀"
        cd "$GITHUB_REPO"
        return 0
    fi

    git add ord vcm vsd 2>/dev/null || true
    if ! git diff --cached --quiet; then
        git commit -m "chore: 서브모듈 참조 업데이트 ($(date +%Y-%m-%d))"
        git push
        echo "  서브모듈 참조 업데이트 push 완료"
    fi

    cd "$GITHUB_REPO"
}

# --- 메인 실행 ---
cd "$GITHUB_REPO"

log "동기화 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
[ "$DRY_RUN" = true ] && warn "DRY-RUN 모드 — 실제 변경 없음"
echo ""

has_submodule=false

for target in "${TARGETS[@]}"; do
    case "$target" in
        ord|vcm|vsd)
            sync_submodule "$target"
            has_submodule=true
            ;;
        pim)
            sync_pim
            ;;
        *)
            warn "알 수 없는 대상: $target (ord, vcm, vsd, pim, all 중 선택)"
            ;;
    esac
    echo ""
done

# 서브모듈이 동기화되었으면 참조 업데이트
if [ "$has_submodule" = true ]; then
    update_submodule_refs
fi

log "동기화 완료"
