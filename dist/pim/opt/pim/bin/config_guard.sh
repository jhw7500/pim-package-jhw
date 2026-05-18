#!/bin/bash
# config_guard.sh — 부팅 시 edgeconf_pim.json / ord_vcm_conf.json 유효성 검증 및 복구.
#
# 정상 부팅 시퀀스에는 두 JSON을 복구하는 안전망이 없다. 빈/손상된 상태로 부팅되면
# vcm/ord/vsd 데몬이 get_json_config()에서 -1을 반환하고, chk_cam_operate.sh는
# 카메라 채널이 모두 false로 잡혀 카메라가 뜨지 않는다. 본 스크립트는 데몬 기동 전
# (pim-config-guard.service oneshot)에서 두 JSON을 검증하고 필요시 복원한다.
#
# 복구 우선순위:
#   edgeconf_pim.json :  현재본 → /root/shared_v/backup/edgeconf_pim.json.bak → /etc/defaultconf.json
#   ord_vcm_conf.json :  현재본 → /root/shared_v/backup/ord_vcm_conf.json.bak → /opt/pim/config/ord_vcm_conf.json
#
# 백업 갱신 정책:
#   부팅 시 두 JSON 모두 valid 통과하면 현재본을 /root/shared_v/backup/ 으로 복사
#   (cmp 로 내용 동일 시 skip → eMMC write 절감). 갱신 실패는 fail-soft (main exit 0 유지).
#   운영 중 vsd 등으로 설정 변경 시에는 다음 부팅까지 .bak 에 반영되지 않음 — 한계 인지.
#
# 유효 조건 (모두 통과):
#   1) [ -s "$f" ]                       (존재 + 크기 > 0)
#   2) jq -e . "$f"                       (파싱 가능 + null/false 아님)
#   3) 필수 헤더 존재
#        edgeconf : .VHL_CAM
#        ord_vcm  : .VCM 과 .ORD
#
# 동작:
#   - 정상이면 조용히 통과.
#   - 폴백 복구 시 logger 로 사유 기록.
#   - default/seed 폴백(운영자 데이터 손실 가능)은 local0.emerg 로 기록.
#   - 두 JSON 중 어느 하나라도 복구 불가능하면 exit 1 — pim-config-guard.service 가
#     failed 상태가 되며 운영자가 journalctl 로 사유 확인 후 개입해야 한다.

set -u
trap '_unexpected_failure $? $LINENO' ERR

tag=$(basename "$0")
KEY=CFG-GUARD

BACKUP_DIR="/root/shared_v/backup"

EDGE_PATH="/root/shared_v/edgeconf_pim.json"
EDGE_BACKUP="${BACKUP_DIR}/edgeconf_pim.json.bak"
EDGE_DEFAULT="/etc/defaultconf.json"

ORD_PATH="/root/shared_v/ord_vcm_conf.json"
ORD_BACKUP="${BACKUP_DIR}/ord_vcm_conf.json.bak"
ORD_SEED="/opt/pim/config/ord_vcm_conf.json"

EDGE_REQUIRED_HEADERS=(".VHL_CAM")
ORD_REQUIRED_HEADERS=(".VCM" ".ORD")

log_info()  { logger -p local0.info   "[$KEY][$tag:${BASH_LINENO[0]}] $*"; echo "[$KEY] $*"; }
log_notice(){ logger -p local0.notice "[$KEY][$tag:${BASH_LINENO[0]}] $*"; echo "[$KEY] $*"; }
log_warn()  { logger -p local0.warning "[$KEY][$tag:${BASH_LINENO[0]}] $*"; echo "[$KEY][WARN] $*" >&2; }
log_emerg() { logger -p local0.emerg  "[$KEY][$tag:${BASH_LINENO[0]}] $*"; echo "[$KEY][EMERG] $*" >&2; }

_unexpected_failure() {
    local ec=$1
    local line=$2
    log_emerg "unexpected failure (exit=$ec line=$line cmd=${BASH_COMMAND:-?})"
}

# Validate a JSON file: exists, non-empty, parses, and contains required headers.
# Args: <path> <header1> [<header2> ...]
# Returns: 0 valid, non-zero invalid (1=missing/empty, 2=parse, 3=header)
validate_json() {
    local f=$1
    shift
    [ -s "$f" ] || return 1
    jq -e . "$f" > /dev/null 2>&1 || return 2
    local hdr
    for hdr in "$@"; do
        jq -e "has(\"${hdr#.}\")" "$f" > /dev/null 2>&1 || return 3
    done
    return 0
}

# Atomic copy: copy to a temp path in the same dir, sync, then rename.
atomic_copy() {
    local src=$1 dst=$2
    local dir
    dir=$(dirname "$dst")
    local tmp="${dir}/.cfgguard.$$.$(basename "$dst")"
    cp "$src" "$tmp" || return 1
    sync "$tmp" 2>/dev/null || true
    mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
    sync "$dst" 2>/dev/null || true
    return 0
}

# Restore edgeconf_pim.json.
# Returns 0 on valid-or-restored, 1 on unrecoverable.
restore_edgeconf() {
    if validate_json "$EDGE_PATH" "${EDGE_REQUIRED_HEADERS[@]}"; then
        log_info "edgeconf valid: $EDGE_PATH"
        return 0
    fi
    local rc=$?
    log_warn "edgeconf invalid (code=$rc): $EDGE_PATH"

    if validate_json "$EDGE_BACKUP" "${EDGE_REQUIRED_HEADERS[@]}"; then
        if atomic_copy "$EDGE_BACKUP" "$EDGE_PATH"; then
            log_notice "edgeconf restored from backup: $EDGE_BACKUP"
            return 0
        fi
        log_warn "edgeconf backup copy failed: $EDGE_BACKUP -> $EDGE_PATH"
    elif [ -e "$EDGE_BACKUP" ]; then
        log_warn "edgeconf backup also invalid: $EDGE_BACKUP"
    else
        log_warn "edgeconf no backup found ($EDGE_BACKUP)"
    fi

    if validate_json "$EDGE_DEFAULT" "${EDGE_REQUIRED_HEADERS[@]}"; then
        if atomic_copy "$EDGE_DEFAULT" "$EDGE_PATH"; then
            log_emerg "edgeconf restored from $EDGE_DEFAULT — operator data WIPED (vhl_name/line/floor/NETWORK/SENSORS)"
            return 0
        fi
        log_emerg "edgeconf default copy failed: $EDGE_DEFAULT -> $EDGE_PATH"
        return 1
    fi

    log_emerg "edgeconf UNRECOVERABLE — all sources invalid (current/backup/default)"
    return 1
}

# Restore ord_vcm_conf.json.
# Returns 0 on valid-or-restored, 1 on unrecoverable.
restore_ord_vcm() {
    if validate_json "$ORD_PATH" "${ORD_REQUIRED_HEADERS[@]}"; then
        log_info "ord_vcm valid: $ORD_PATH"
        return 0
    fi
    local rc=$?
    log_warn "ord_vcm invalid (code=$rc): $ORD_PATH"

    if validate_json "$ORD_BACKUP" "${ORD_REQUIRED_HEADERS[@]}"; then
        if atomic_copy "$ORD_BACKUP" "$ORD_PATH"; then
            log_notice "ord_vcm restored from backup: $ORD_BACKUP"
            return 0
        fi
        log_warn "ord_vcm backup copy failed: $ORD_BACKUP -> $ORD_PATH"
    elif [ -e "$ORD_BACKUP" ]; then
        log_warn "ord_vcm backup also invalid: $ORD_BACKUP"
    else
        log_warn "ord_vcm no backup found ($ORD_BACKUP)"
    fi

    if validate_json "$ORD_SEED" "${ORD_REQUIRED_HEADERS[@]}"; then
        if atomic_copy "$ORD_SEED" "$ORD_PATH"; then
            log_emerg "ord_vcm restored from package seed: $ORD_SEED"
            return 0
        fi
        log_emerg "ord_vcm seed copy failed: $ORD_SEED -> $ORD_PATH"
        return 1
    fi

    log_emerg "ord_vcm UNRECOVERABLE — all sources invalid (current/backup/seed)"
    return 1
}



# Refresh one backup file from a validated current copy.
# Skip if content is identical (eMMC wear). Fail-soft: returns 0 always.
# Args: <current_path> <backup_path> <label>
refresh_one_backup() {
    local src=$1 dst=$2 label=$3
    if [ ! -f "$src" ]; then
        return 0
    fi
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi
    if atomic_copy "$src" "$dst"; then
        log_info "$label backup refreshed: $dst"
    else
        log_warn "$label backup refresh failed: $src -> $dst (continuing)"
    fi
    return 0
}

# Refresh /root/shared_v/backup/ snapshots from validated current copies.
# Only called when BOTH JSONs passed validation/restore. Fail-soft.
update_backups() {
    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        log_warn "backup dir create failed: $BACKUP_DIR (skip refresh)"
        return 0
    fi
    refresh_one_backup "$EDGE_PATH" "$EDGE_BACKUP" "edgeconf"
    refresh_one_backup "$ORD_PATH"  "$ORD_BACKUP"  "ord_vcm"
}

main() {
    if ! command -v jq >/dev/null 2>&1; then
        log_emerg "jq not found — cannot validate JSON; aborting"
        exit 1
    fi

    if [ ! -d /root/shared_v ]; then
        mkdir -p /root/shared_v || {
            log_emerg "/root/shared_v missing and mkdir failed"
            exit 1
        }
    fi

    local edge_rc=0 ord_rc=0
    restore_edgeconf || edge_rc=$?
    restore_ord_vcm  || ord_rc=$?

    if [ "$edge_rc" -ne 0 ] || [ "$ord_rc" -ne 0 ]; then
        log_emerg "config guard FAILED (edge=$edge_rc ord=$ord_rc) — downstream daemons will likely fail; operator intervention required"
        exit 1
    fi

    update_backups

    log_info "config guard OK"
    exit 0
}

main "$@"
