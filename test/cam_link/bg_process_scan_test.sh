#!/usr/bin/env bash
# Deterministic /proc disappearance races; no target processes or hardware.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/pim-bg-scan.XXXXXX")
trap 'rm -rf -- "$W"' EXIT
export PIM_LIB="$ROOT/dist/pim/opt/pim/lib" PIM_BIN="$ROOT/dist/pim/opt/pim/bin"
export PIM_CAMERA_BG_CHECKER="$PIM_BIN/BG_Check_for_pim.sh"
source "$PIM_LIB/cam_recovery_actions.sh"

# Keep the real matcher/parser/scanner. Only inject process exits or EACCES
# at read boundaries, so races do not depend on scheduler timing or test UID.
eval "$(declare -f cam_bg_argv_matches | sed '1s/cam_bg_argv_matches/scan_real_argv_matches/')"
fixture() {
    local pid=$1 start=$2 layout=$3 dir="$PIM_CAMERA_PROCESS_ROOT/$1"
    mkdir -p "$dir"
    {
        printf '%s (BG Check) S' "$pid"
        for _ in {1..18}; do printf ' 0'; done
        printf ' %s 0\n' "$start"
    } > "$dir/stat"
    case "$layout" in
        direct) printf '%s\0004\000' "$PIM_CAMERA_BG_CHECKER" ;;
        shebang) printf '/bin/bash\000%s\0004\000' "$PIM_CAMERA_BG_CHECKER" ;;
        unrelated) printf '/bin/bash\000unrelated.sh\0004\000' ;;
        trailing) printf '%s\0004\000extra\000' "$PIM_CAMERA_BG_CHECKER" ;;
        invalid_direct_delay) printf '%s\000invalid\000' "$PIM_CAMERA_BG_CHECKER" ;;
        invalid_shebang_delay) printf '/bin/bash\000%s\000invalid\000' "$PIM_CAMERA_BG_CHECKER" ;;
    esac > "$dir/cmdline"
}
retire_candidate() {
    rm -f -- "$candidate/cmdline" "$candidate/stat"
    rmdir -- "$candidate"
    touch "$injected"
}
# shellcheck disable=SC2329  # invoked by the sourced production scanner
cam_bg_argv_matches() {
    local rc=0
    if [[ $1 == "$candidate/cmdline" && $phase == before_argv ]]; then
        retire_candidate
    fi
    inside_argv=1
    scan_real_argv_matches "$@" || rc=$?
    inside_argv=0
    if [[ $1 == "$candidate/cmdline" ]]; then
        case "$phase" in
            before_stat) retire_candidate ;;
            missing_stat) rm -f -- "$candidate/stat"; touch "$injected" ;;
        esac
    fi
    return "$rc"
}
# shellcheck disable=SC2329  # invoked by sourced readability checks
function [() {
    local rc=0
    if [[ $# == 3 && $1 == -r && $2 == "$candidate/cmdline" && $phase == unreadable_argv ]]; then
        touch "$injected"
        return 1
    fi
    builtin [ "$@" || rc=$?
    if [[ $# == 3 && $1 == -r && $2 == "$candidate/cmdline" && ${inside_argv:-0} == 1 && $rc == 0 ]]; then
        case "$phase" in
            argv_open_gone) retire_candidate ;;
            argv_open_error) rm -f -- "$candidate/cmdline"; touch "$injected" ;;
        esac
    fi
    return "$rc"
}
# shellcheck disable=SC2329  # invoked by the sourced stat parser
cat() {
    if [[ $# == 1 && $1 == "$candidate/stat" && $phase == stat_read_gone ]]; then
        retire_candidate
    fi
    command cat "$@"
}

check_scan() (
    local name=$1 phase=$2 want_rc=$3 want_records=$4 layout=${5:-direct} survivor=${6:-yes}
    export PIM_CAMERA_PROCESS_ROOT="$W/$name/proc"
    local candidate="$PIM_CAMERA_PROCESS_ROOT/101" injected="$W/$name/injected" inside_argv=0
    local records rc=0 present_rc=0
    mkdir -p "$PIM_CAMERA_PROCESS_ROOT"
    [[ $layout == none ]] || fixture 101 1001 "$layout"
    [[ $survivor == no ]] || fixture 900 9000 shebang
    case "$phase" in
        malformed_stat) printf 'malformed\n' > "$candidate/stat" ;;
        inspect_error) touch "$PIM_CAMERA_PROCESS_ROOT/.inspect_error" ;;
    esac
    records=$(cam_bg_checker_records "$PIM_CAMERA_BG_CHECKER") || rc=$?
    if [[ $rc != "$want_rc" || $records != "$want_records" ]]; then
        printf 'FAIL %s: want rc=%s records=%q; got rc=%s records=%q\n' "$name" "$want_rc" "$want_records" "$rc" "$records" >&2
        return 1
    fi
    case "$phase" in
        before_argv|before_stat|missing_stat|unreadable_argv|argv_open_gone|argv_open_error|stat_read_gone)
            [[ -f $injected ]] || { printf 'FAIL %s: injection not reached\n' "$name" >&2; return 1; } ;;
    esac
    # A vanished BG alone is absent (1), not an inspection error (2) or ready (0).
    if [[ $want_rc == 0 && -z $want_records ]]; then
        cam_bg_checker_present "$PIM_CAMERA_BG_CHECKER" || present_rc=$?
        [[ $present_rc == 1 ]] || { printf 'FAIL %s: absent BG rc=%s\n' "$name" "$present_rc" >&2; return 1; }
    fi
    printf 'PASS %s\n' "$name"
)

failures=0
check_scan empty_scan stable 0 '' none no || failures=$((failures + 1))
check_scan exact_layouts stable 0 $'101 1001\n900 9000' || failures=$((failures + 1))
check_scan unrelated_argv stable 0 '900 9000' unrelated || failures=$((failures + 1))
check_scan trailing_argv stable 0 '900 9000' trailing || failures=$((failures + 1))
check_scan invalid_direct_delay stable 0 '900 9000' invalid_direct_delay || failures=$((failures + 1))
check_scan invalid_shebang_delay stable 0 '900 9000' invalid_shebang_delay || failures=$((failures + 1))
# These must fail if a disappeared candidate poisons the entire scan.
check_scan unrelated_exit before_argv 0 '900 9000' unrelated || failures=$((failures + 1))
check_scan bg_exit_before_argv before_argv 0 '900 9000' || failures=$((failures + 1))
check_scan bg_exit_before_open argv_open_gone 0 '900 9000' || failures=$((failures + 1))
check_scan bg_exit_before_stat before_stat 0 '900 9000' || failures=$((failures + 1))
check_scan bg_exit_during_stat_read stat_read_gone 0 '900 9000' || failures=$((failures + 1))
check_scan only_bg_exits before_argv 0 '' direct no || failures=$((failures + 1))
# These must fail if errors from existing/uninspectable processes are swallowed.
check_scan live_unreadable_argv unreadable_argv 2 '' || failures=$((failures + 1))
check_scan live_argv_open_error argv_open_error 2 '' || failures=$((failures + 1))
check_scan live_missing_stat missing_stat 2 '' || failures=$((failures + 1))
check_scan live_malformed_stat malformed_stat 2 '' || failures=$((failures + 1))
check_scan inspection_error inspect_error 2 '' || failures=$((failures + 1))
printf 'BG process scan: %s failure(s)\n' "$failures"
[[ $failures == 0 ]]
