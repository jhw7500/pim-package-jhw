#!/bin/bash
set -euo pipefail

# =============================================================================
# sync-to-gitlab.sh — GitHub monorepo → GitLab 서브모듈 동기화
#
# 사용법:
#   ./sync-to-gitlab.sh ord                  # ord 파일만 sync (commit/push 없음)
#   ./sync-to-gitlab.sh --commit pim         # pim 파일 sync + commit (push 없음)
#   ./sync-to-gitlab.sh --push all           # ord+vcm+vsd+pim 전부 sync + commit + push
#   ./sync-to-gitlab.sh --dry-run all        # rsync 시뮬레이션만 (commit/push 없음)
#
# 모드 우선순위: --dry-run > 기본(파일만) < --commit < --push
#
# 메시지 prefix `sync-back:` 가진 GitHub commit은 GitLab sync 메시지에서 자동 제외
# (회사 측에서 GitHub로 가져온 변경이 다시 GitLab으로 sync되는 것 방지)
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
# release/는 빌드 산출물이므로 제외 (.gitignore와 정합)
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
사용법: $0 [--dry-run|--commit|--push] <ord|vcm|vsd|pim|all> [...]

대상:
  ord, vcm, vsd  — 해당 서브모듈만 동기화
  pim            — dist, patch, build.sh 등 본체 파일 동기화
  all            — 전부 동기화

모드 (기본은 파일만 sync, commit/push 없음):
  --dry-run      — rsync 시뮬레이션만 (실제 파일 변경 없음)
  --commit       — 파일 sync + GitLab repo에 commit (push 없음)
  --push         — 파일 sync + commit + GitLab origin push

안전 검사:
  기본           — 이 sync 로 GitLab 에서 파일이 '삭제'되면 중단한다.
                   GitLab 에만 있는 파일이라는 뜻이고, 역방향 동기화가 밀렸을 때
                   회사 측 작업이 사라지는 경로다. 덮어쓰기는 방향을 알 수 없어
                   판정하지 않으니 dry-run 으로 확인하라.
  --force        — 안전 검사 우회 (삭제를 감수)
EOF
    exit 1
fi

# --- 유틸 함수 ---
log() { echo "=== $1 ==="; }
warn() { echo "⚠ $1"; }

# 이 sync 로 GitLab 에서 '지워질' 파일이 있는지 미리 잡는다.
#
# 배경: 역방향(GitLab→GitHub) 동기화가 밀린 채로 정방향을 돌리면 GitLab 에만 있는
# 작업이 사라진다. 실제로 10커밋(pimwebserver 1.1.0 등)이 밀린 상태로 돌릴 뻔했고
# dry-run 을 눈으로 본 덕에 걸렸다.
#
# 덮어쓰기는 판정하지 않는다. 내용 비교만으로는 'GitHub 가 앞섰다'와 'GitLab 이
# 앞섰다'를 구분할 수 없는데, 전자가 바로 정방향 sync 의 정상 경로다. 방향을
# 모르는 채로 막으면 정상 sync 를 매번 차단한다(그렇게 만들었다가 되돌렸다).
#
# 반면 '지워질 파일'은 모호하지 않다 — GitLab 에만 있다는 뜻이고, --delete 로
# 사라지면 되돌릴 수 없다. 앞선 사고도 정확히 삭제(.deb, override.conf)였다.
# 덮어쓰기는 커밋 전 diff 로 확인할 수 있지만 삭제는 그 전에 이미 끝난다.
#
# $1=scope  $2.. = 정방향(GitHub→GitLab) rsync 인자
check_delete_pending() {
    local scope="$1"; shift
    local deletions count rc=0

    deletions=$(rsync_dry_deletions "$@") || rc=$?
    if [ "$rc" -ne 0 ]; then
        # 판정 불가를 '문제 없음'으로 넘기면 가드가 없는 것과 같다.
        warn "${scope}: 삭제 대상 확인용 rsync 가 실패해 판정할 수 없다."
        if [ "$DRY_RUN" = true ]; then
            warn "  [DRY-RUN] 경고만 하고 계속한다."
            return 0
        fi
        if [ "$FORCE" = true ]; then
            warn "  [FORCE] 판정 없이 계속한다."
            return 0
        fi
        echo "중단했다. 원인을 확인하거나 --force 로 강행하라." >&2
        exit 1
    fi
    [ -z "$deletions" ] && return 0

    count=$(printf '%s\n' "$deletions" | grep -c .)
    warn "${scope}: 이 sync 로 GitLab 에서 ${count}건이 삭제된다."
    printf '%s\n' "$deletions" | sed 's/^/    /' >&2
    warn "  GitLab 에만 있는 파일이다. 역방향 동기화가 밀린 것은 아닌지 확인하라."
    warn "  ./sync-from-gitlab.sh ${scope}"
    warn "  참고: 덮어쓰기는 방향을 알 수 없어 검사하지 않는다. GitLab 이 앞선 파일이"
    warn "        있는지는 위 dry-run 목록을 직접 확인해야 한다."

    if [ "$DRY_RUN" = true ]; then
        warn "  [DRY-RUN] 경고만 하고 계속한다."
        return 0
    fi
    if [ "$FORCE" = true ]; then
        warn "  [FORCE] 삭제를 감수하고 계속한다."
        return 0
    fi
    echo "중단했다. 의도한 삭제라면 --force 로 강행하라." >&2
    exit 1
}

# sync-back: prefix 메시지를 가진 commit은 GitLab sync에서 제외
# (회사 측 변경을 GitHub에 통합한 commit이 다시 GitLab으로 sync되는 것 방지)
filter_sync_back() {
    grep -v '^[a-f0-9]\+ sync-back:' || true
}

# rsync dry-run으로 실제 변경/신규/삭제될 파일 목록만 추출 (디렉토리 제외)
# .last-sync-pim stale에 강건 — 변경되지 않은 파일의 commits는 자동 제외됨
# 인자: rsync에 전달할 옵션/include/exclude/src/dst 모두 그대로 패스스루
# rsync dry-run 의 원시 항목(%i|%n)을 그대로 돌려준다. 아래 두 추출기의 공통부다.
#
# --checksum: rsync 기본 비교는 size+mtime 이라 내용이 같아도 mtime 만 다르면
# 변경으로 잡힌다(역방향 sync 직후가 그렇다). 그 목록으로 커밋 메시지를 만들면
# 실제로 바뀌지도 않은 파일의 커밋이 딸려 온다. 여기서는 정확도가 우선이다.
#
# 종료코드를 반드시 확인한다. 이전에는 2>/dev/null 로 삼키고 파이프로 넘겨 awk 의
# 상태만 남았다. rsync 가 실패하면 빈 목록이 나오고 호출부는 '변경 없음'으로 읽는데,
# 가드에서는 그게 곧 무력화다. stderr 는 임시 파일로 받아 성공 경로의 파싱을
# 오염시키지 않는다.
rsync_dry_raw() {
    local out rc=0
    # stderr 는 가리지 않고 그대로 흘려보낸다. 임시 파일로 받으면 Ctrl+C 나 set -e
    # 중단 때 /tmp 에 남고, 정작 사용자는 원본 메시지를 못 본다.
    out=$(rsync -an --delete --checksum -i --out-format='%i|%n' \
        --filter=':- .gitignore' \
        --exclude='.git' \
        --exclude='upgrade_file/dpkg/pimwebserver_*.deb' \
        --exclude='dist/pim/opt/pim/driver/sc16is7xx_ext.ko' \
        "$@") || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "rsync 실패(rc=${rc}) — 위 오류 참고" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

rsync_dry_changed_files() {
    # pipefail 에 기대지 않는다. 안전 가드가 전역 설정 하나에 매달리면, 나중에
    # 그 설정이 빠졌을 때 실패가 조용히 '변경 없음'으로 바뀐다.
    local raw
    raw=$(rsync_dry_raw "$@") || return 1
    printf '%s\n' "$raw" \
        | awk -F'|' '
            {
                c = substr($1, 1, 1)
                # > 송신, < 수신, c 새 항목 생성, * 메시지(deleting 등)
                if (c == ">" || c == "<" || c == "c" || c == "*") {
                    # 디렉토리 항목(%n 끝이 /) 제외
                    if (substr($2, length($2), 1) != "/") print $2
                }
            }'
}

# 삭제될 항목만 뽑는다. rsync -i 는 삭제에 '*deleting' 을 준다.
rsync_dry_deletions() {
    local raw
    raw=$(rsync_dry_raw "$@") || return 1
    printf '%s\n' "$raw" \
        | awk -F'|' '
            $1 ~ /deleting/ {
                if (substr($2, length($2), 1) != "/") print $2
            }'
}

# 변경 파일에 한정한 git log 추출 (since..HEAD 또는 -10 fallback)
# 변경 파일 기반이므로 .last-sync-pim이 stale이어도 영향 받지 않은 commit은 포함되지 않음
# 각 commit subject 뒤에 [실제 sync된 file 목록] 첨부 — file-level 책임 표시
# (통합 commit이 sync 범위 밖 파일까지 다뤘더라도 메시지엔 sync된 파일만 노출됨)
git_log_for_files() {
    local last_sync_file="$1"
    shift
    local files=("$@")
    [ ${#files[@]} -eq 0 ] && return 0

    local log_range="-10"
    if [ -f "$last_sync_file" ]; then
        log_range="$(cat "$last_sync_file")..HEAD"
    fi

    local raw_log
    raw_log=$(git -C "$GITHUB_REPO" log --format='%H %s' $log_range -- "${files[@]}" 2>/dev/null \
        | filter_sync_back)
    [ -z "$raw_log" ] && return 0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local sha=${line%% *}
        local subject=${line#* }
        local short=${sha:0:7}
        local commit_files
        commit_files=$(git -C "$GITHUB_REPO" show --name-only --format='' "$sha" 2>/dev/null || true)
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

save_sync_point() {
    local scope="$1"
    local current_sha
    current_sha=$(git -C "$GITHUB_REPO" rev-parse HEAD)
    echo "$current_sha" > "$GITLAB_REPO/.last-sync-${scope}"
}

# commit/push 분기 처리 — sync_submodule, sync_pim, update_submodule_refs에서 공통 사용
# args: $1=commit_dir, $2=commit_msg, $3=label, $4=save_scope (빈 값이면 save_sync_point 스킵)
finalize_commit() {
    local commit_dir="$1"
    local commit_msg="$2"
    local label="$3"
    local save_scope="${4:-}"

    cd "$commit_dir"

    if git diff --quiet && git diff --cached --quiet; then
        echo "  변경사항 없음 (이미 동기화됨)"
        cd "$GITHUB_REPO"
        return 0
    fi

    if [ "$DO_COMMIT" = false ]; then
        echo "  [FILES-ONLY] 파일 sync 완료. GitLab repo 검토 후 수동 commit 필요"
        echo "    (--commit 또는 --push 옵션으로 자동 commit 가능)"
        cd "$GITHUB_REPO"
        return 0
    fi

    # .last-sync-{scope}를 commit 전에 갱신해서 같은 commit에 포함되게 함
    # (이전: commit 후 갱신 → working tree에만 남아 다음 sync까지 dirty 상태)
    # 서브모듈의 경우 .last-sync-{scope}는 GITLAB_REPO 루트에 있으므로
    # 서브모듈 commit에는 포함 안 되고 update_submodule_refs에서 add됨
    [ -n "$save_scope" ] && save_sync_point "$save_scope"

    git add -A
    git commit -m "$commit_msg"
    echo "  ${label} commit 완료"

    if [ "$DO_PUSH" = true ]; then
        git push
        echo "  ${label} push 완료"
    else
        echo "  [NO-PUSH] commit만 생성됨. push는 수동으로 실행하세요"
    fi

    cd "$GITHUB_REPO"
}

# --- 서브모듈 동기화 ---
sync_submodule() {
    local scope="$1"
    local subdir="${SUBMODULE_MAP[$scope]}"

    log "${scope} 서브모듈 동기화"

    check_delete_pending "$scope" \
        "${GITHUB_REPO}/${subdir}/" "${GITLAB_REPO}/${subdir}/"

    # 1. 실제 변경될 파일 dry-run으로 먼저 추출 (.last-sync-pim stale 영향 차단)
    local changed_files
    changed_files=$(rsync_dry_changed_files \
        "${GITHUB_REPO}/${subdir}/" "${GITLAB_REPO}/${subdir}/")

    if [ -z "$changed_files" ]; then
        echo "  동기화할 변경사항 없음 (${scope})"
        return 0
    fi

    # 2. 변경 파일에 한정해서 GitHub commits 추출 (subdir/ prefix 부여)
    local file_args=()
    while IFS= read -r f; do
        [ -n "$f" ] && file_args+=("${subdir}/${f}")
    done <<< "$changed_files"

    local commits
    commits=$(git_log_for_files "$GITLAB_REPO/.last-sync-${scope}" "${file_args[@]}")

    if [ -n "$commits" ]; then
        echo "  GitHub 커밋:"
        echo "$commits" | sed 's/^/    /'
    else
        echo "  GitHub 커밋: (변경 파일이 추적된 commits에 매핑되지 않음 — file restoration 가능성)"
        commits="(no matching commits — file restoration or out-of-band change)"
    fi

    # 3. rsync (GitHub → GitLab 서브모듈)
    echo "  파일 복사: ${GITHUB_REPO}/${subdir}/ → ${GITLAB_REPO}/${subdir}/"

    if [ "$DRY_RUN" = true ]; then
        rsync -avn --delete --checksum \
            --filter=':- .gitignore' \
            --exclude='.git' \
            --exclude='upgrade_file/dpkg/pimwebserver_*.deb' \
            --exclude='dist/pim/opt/pim/driver/sc16is7xx_ext.ko' \
            "${GITHUB_REPO}/${subdir}/" "${GITLAB_REPO}/${subdir}/"
        echo "  [DRY-RUN] commit/push 건너뜀"
        return 0
    fi

    rsync -a --delete \
        --filter=':- .gitignore' \
        --exclude='.git' \
        --exclude='upgrade_file/dpkg/pimwebserver_*.deb' \
        --exclude='dist/pim/opt/pim/driver/sc16is7xx_ext.ko' \
        "${GITHUB_REPO}/${subdir}/" "${GITLAB_REPO}/${subdir}/"

    local sync_msg
    sync_msg="sync: GitHub 반영 ($(date +%Y-%m-%d))"$'\n\n'
    sync_msg+=$(echo "$commits" | sed 's/^/- /')

    finalize_commit "${GITLAB_REPO}/${subdir}" "$sync_msg" "${scope} 서브모듈" "$scope"
}

# --- pim 본체 동기화 ---
sync_pim() {
    log "pim 본체 동기화"

    # PIM_DIRS + PIM_FILES을 단일 rsync include 패턴으로 통합
    # source를 GitHub repo 루트로 잡아 루트 .gitignore가 per-directory merge로 자동 적용됨
    # → 사용자가 .gitignore에 패턴 추가하면 자동으로 동기화에서도 제외 (별도 관리 불필요)
    local rsync_includes=()
    for d in "${PIM_DIRS[@]}"; do
        rsync_includes+=(--include="${d}/" --include="${d}/**")
    done
    for f in "${PIM_FILES[@]}"; do
        rsync_includes+=(--include="${f}")
    done

    check_delete_pending "pim" \
        "${rsync_includes[@]}" --exclude='*' "${GITHUB_REPO}/" "${GITLAB_REPO}/"

    # 1. 실제 변경될 파일 dry-run으로 먼저 추출 (.last-sync-pim stale 영향 차단)
    local changed_files
    changed_files=$(rsync_dry_changed_files \
        "${rsync_includes[@]}" \
        --exclude='*' \
        "${GITHUB_REPO}/" "${GITLAB_REPO}/")

    if [ -z "$changed_files" ]; then
        echo "  동기화할 변경사항 없음 (pim)"
        return 0
    fi

    # 2. 변경 파일에 한정해서 GitHub commits 추출
    local file_args=()
    while IFS= read -r f; do
        [ -n "$f" ] && file_args+=("$f")
    done <<< "$changed_files"

    local commits
    commits=$(git_log_for_files "$GITLAB_REPO/.last-sync-pim" "${file_args[@]}")

    if [ -n "$commits" ]; then
        echo "  GitHub 커밋:"
        echo "$commits" | sed 's/^/    /'
    else
        echo "  GitHub 커밋: (변경 파일이 추적된 commits에 매핑되지 않음 — file restoration 가능성)"
        commits="(no matching commits — file restoration or out-of-band change)"
    fi

    echo "  복사: ${PIM_DIRS[*]} ${PIM_FILES[*]}"

    # 제외 규칙은 반드시 include 앞에 둔다. rsync 는 먼저 매칭되는 규칙이 이기므로
    # --include='dist/**' 뒤에 놓으면 도달하지 못해 무력화된다. 실제로 그 상태였고,
    # 그 결과 GitLab 에만 있던 pimwebserver_*.deb 가 --delete 대상에 올랐다.
    # (제외된 파일은 --delete 에서 보호되므로 순서만 맞으면 삭제되지 않는다.)
    if [ "$DRY_RUN" = true ]; then
        rsync -avn --delete --checksum \
            --filter=':- .gitignore' \
            --exclude='.git' \
            --exclude='upgrade_file/dpkg/pimwebserver_*.deb' \
            --exclude='dist/pim/opt/pim/driver/sc16is7xx_ext.ko' \
            "${rsync_includes[@]}" \
            --exclude='*' \
            "${GITHUB_REPO}/" "${GITLAB_REPO}/"
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
        "${GITHUB_REPO}/" "${GITLAB_REPO}/"

    local sync_msg
    sync_msg="sync: GitHub 반영 ($(date +%Y-%m-%d))"$'\n\n'
    sync_msg+=$(echo "$commits" | sed 's/^/- /')

    finalize_commit "$GITLAB_REPO" "$sync_msg" "pim 본체" "pim"
}

# --- 서브모듈 참조 업데이트 ---
update_submodule_refs() {
    log "GitLab pim-package 서브모듈 참조 업데이트"

    cd "$GITLAB_REPO"

    local changed=false
    local sync_files=()
    for scope in "${!SUBMODULE_MAP[@]}"; do
        local subdir="${SUBMODULE_MAP[$scope]}"
        # 서브모듈 참조가 변경되었는지 확인
        if ! git diff --quiet -- "$subdir"; then
            changed=true
        fi
        # .last-sync-{scope} 파일도 변경 여부 확인 (sync_submodule이 갱신했을 수 있음)
        local sync_file=".last-sync-${scope}"
        if [ -f "$sync_file" ] && ! git diff --quiet -- "$sync_file"; then
            changed=true
            sync_files+=("$sync_file")
        fi
    done

    if [ "$changed" = false ]; then
        echo "  서브모듈 참조 변경 없음"
        cd "$GITHUB_REPO"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] 서브모듈 참조 commit/push 건너뜀"
        cd "$GITHUB_REPO"
        return 0
    fi

    if [ "$DO_COMMIT" = false ]; then
        echo "  [FILES-ONLY] 서브모듈 참조 변경 감지. GitLab repo에서 수동 commit 필요"
        echo "    (--commit 또는 --push 옵션으로 자동 commit 가능)"
        cd "$GITHUB_REPO"
        return 0
    fi

    git add ord vcm vsd 2>/dev/null || true
    # .last-sync-{scope} 파일도 함께 add (working tree dirty 잔존 방지)
    [ ${#sync_files[@]} -gt 0 ] && git add "${sync_files[@]}"
    if ! git diff --cached --quiet; then
        git commit -m "chore: 서브모듈 참조 업데이트 ($(date +%Y-%m-%d))"
        echo "  서브모듈 참조 commit 완료"

        if [ "$DO_PUSH" = true ]; then
            git push
            echo "  서브모듈 참조 push 완료"
        else
            echo "  [NO-PUSH] commit만 생성됨. push는 수동으로 실행하세요"
        fi
    fi

    cd "$GITHUB_REPO"
}

# --- 메인 실행 ---
cd "$GITHUB_REPO"

log "동기화 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
[ "$DRY_RUN" = true ] && warn "DRY-RUN 모드 — 실제 변경 없음"
[ "$DRY_RUN" = false ] && [ "$DO_COMMIT" = false ] && warn "FILES-ONLY 모드 — 파일만 sync, commit/push 없음"
[ "$DO_COMMIT" = true ] && [ "$DO_PUSH" = false ] && warn "COMMIT 모드 — commit만, push 없음"
[ "$DO_PUSH" = true ] && warn "PUSH 모드 — commit + push 자동 진행"
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
