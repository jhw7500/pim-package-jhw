#!/usr/bin/env bash

PIM_CAMERA_RUN_DIR="${PIM_CAMERA_RUN_DIR:-/run/pim-camera}"
PIM_CAMERA_STATE_DIR="${PIM_CAMERA_STATE_DIR:-/var/lib/pim-camera}"
PIM_CAMERA_BOOT_ID_FILE="${PIM_CAMERA_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
PIM_CAMERA_PROC_ROOT="${PIM_CAMERA_PROC_ROOT:-/proc}"
PIM_CAMERA_RUNTIME_JSON="${PIM_CAMERA_RUNTIME_JSON:-$PIM_CAMERA_RUN_DIR/config/pim_runtime.json}"

_cr_owner_file() { printf '%s/owner.json' "$PIM_CAMERA_RUN_DIR"; }
_cr_recovery_dir() { printf '%s/recovery' "$PIM_CAMERA_RUN_DIR"; }
_cr_pending_file() { printf '%s/pending.json' "$(_cr_recovery_dir)"; }
_cr_active_file() { printf '%s/active.json' "$(_cr_recovery_dir)"; }
_cr_result_file() { printf '%s/results/%s.json' "$(_cr_recovery_dir)" "$1"; }
_cr_state_file() { printf '%s/recovery/state.json' "$PIM_CAMERA_STATE_DIR"; }
_cr_monitor_wait_file() { printf '%s/monitor_wait.pid' "$PIM_CAMERA_RUN_DIR"; }
_cr_history_file() { printf '%s/recovery/history/%s.json' "$PIM_CAMERA_STATE_DIR" "$1"; }
_cr_service_file() { printf '%s/service-state.json' "$PIM_CAMERA_STATE_DIR"; }
_cr_now() { date +%s; }
# 구간 계측. PIM_CAMERA_TIMING_LOG 가 설정될 때만 기록한다(기본 off).
# EPOCHREALTIME 은 bash 5.0+ 내장이라 fork 가 없다 — 보드 실측 100회 8ms.
# date 는 100회 480ms 라 계측이 측정을 왜곡한다.
_cr_timing() {
    [ -n "${PIM_CAMERA_TIMING_LOG:-}" ] || return 0
    printf '%s %s\n' "${EPOCHREALTIME:-0}" "$1" >> "$PIM_CAMERA_TIMING_LOG" 2>/dev/null
    return 0
}
_cr_uuid() { cat /proc/sys/kernel/random/uuid; }
_cr_proc_start() {
    local stat tail
    stat=$(cat "$PIM_CAMERA_PROC_ROOT/$1/stat" 2>/dev/null) || return 1
    tail=${stat##*) }
    set -- $tail
    [ $# -ge 20 ] || return 1
    printf '%s\n' "${20}"
}

# python3 를 띄워 fsync 하던 것을 coreutils sync 로 바꾼다. sync FILE 은
# coreutils 8.24+ 에서 해당 파일에 fsync(2) 를 호출하므로 의미가 같다.
# 보드 실측: python3 2회 216ms, sync 2회 3ms. 구형 coreutils 가 인자를 무시하고
# 전체 sync 를 하더라도 내구성은 더 강해지므로 안전하다.
# 함수 이름은 유지한다 — 여러 테스트가 이 이름을 no-op 으로 재정의한다.
_cr_fsync_file() { sync "$1"; }
_cr_fsync_dir() { sync "$1"; }
_cr_atomic_write() {
    local target=$1 data=$2 dir tmp
    dir=$(dirname "$target"); mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$data" > "$tmp" || ! _cr_fsync_file "$tmp" || ! mv -f "$tmp" "$target" || ! _cr_fsync_dir "$dir"; then rm -f "$tmp"; return 1; fi
}
_cr_remove() { local dir; dir=$(dirname "$1"); rm -f "$1" && _cr_fsync_dir "$dir"; }
_cr_move() { mv "$1" "$2" && _cr_fsync_dir "$(dirname "$2")"; }
_cr_lock_call() {
    local fd rc
    mkdir -p "$PIM_CAMERA_RUN_DIR" || return 70
    exec {fd}>"$PIM_CAMERA_RUN_DIR/recovery.lock" || return 70
    flock -n "$fd" || { exec {fd}>&-; return 75; }
    "$@"; rc=$?; flock -u "$fd"; exec {fd}>&-; return "$rc"
}
_cr_lock_call_wait() {
    local wait=$1 fd rc
    shift
    mkdir -p "$PIM_CAMERA_RUN_DIR" || return 70
    exec {fd}>"$PIM_CAMERA_RUN_DIR/recovery.lock" || return 70
    if flock -E 75 -w "$wait" "$fd"; then
        "$@"; rc=$?
        flock -u "$fd"
        exec {fd}>&-
        return "$rc"
    else
        rc=$?
        exec {fd}>&-
        return "$rc"
    fi
}
# 요청할 수 있는 action 과 counter 에 기록되는 action 은 같지 않다.  이 목록은 전자이고,
# 후자는 아래 jq 술어 public_action 과 _cr_state_template 의 네 키다.  gstapp_stop 은
# 여기에만 있다 — 정지는 escalation 의미가 없고(_cl_gstapp_failures 는 gstapp_restart 만
# 읽는다), counter 를 주면 state.json 의 키 집합이 바뀌어 이미 배포된 보드의 파일이
# _cr_state_valid 에서 거부된다.  countered:false 경로는 ord_restart 등이 쓰는 기존 길이다.
_cr_public_action() { case "$1" in gstapp_restart|gstapp_stop|module_reload|camera_hard_reset|reboot_fallback) return 0;; esac; return 1; }
_cr_request_type() { _cr_public_action "$1" || [ "$1" = apply_config ]; }
_cr_owner_json() { cat "$(_cr_owner_file)" 2>/dev/null; }

# 같은 프로세스 안의 jq 호출 메모 (이슈 #150). 보드에서 jq 1회가 ~307ms 인데, 소유자
# 가드는 요청 한 건 동안 같은 owner 문서·같은 인자로 같은 필터를 수십 번 다시 돌렸다.
# 키는 jq 인자 전체와 입력 문자열 전체이고 판정은 jq 필터 그대로라 결과가 기존과 같다 —
# 여기서 쓰는 필터들은 env·now 를 읽지 않으므로 입력이 같으면 출력도 같다. 비교 논리를
# bash 로 옮기지 않는 것이 핵심이다(다중 문서 owner·끝 개행 필드에서 판정이 갈린다).
# rc 0 결과만 저장한다: 일시적 실패를 캐시하면 장수 데몬의 가드가 owner 가 바뀔 때까지
# 굳는다. 항목이 상한을 넘으면 비운다. /proc 생존 확인은 호출부에서 매번 그대로 한다.
declare -gA _CR_JQ_MEMO=()
# 상한 두 개 — 어느 쪽이든 넘으면 비운다. 항목: 요청 한 건이 항목을 20여 개 남기므로, 64 이면
# 오래 도는 데몬이 2~3건마다 메모를 통째로 비워 그 요청에서 owner·런타임 가드의 jq 를 3~5회 다시
# 띄웠다(이슈 #168, 같은 데몬에서 연속 12건 실측). 크기: 키에는 입력 문서가 통째로 들어간다 —
# 큰 필드(예: 100KiB reason)가 든 요청이 이어지면 항목 상한만으로는 수십 MiB 를 붙들 수 있어,
# 키·값의 바이트 수 합을 따로 묶는다(평소 요청 한 건은 수십 KiB 다). 문자 수가 아니라 바이트로
# 센다 — UTF-8 로케일에서 한글·이모지는 한 글자가 3~4 바이트다.
_CR_JQ_MEMO_MAX=512
_CR_JQ_MEMO_BYTE_MAX=2097152
_CR_JQ_MEMO_BYTES=0
# n 개 항목, b 바이트를 더 넣을 자리가 없으면 비운다. 함께 남아야 하는 항목들은 넣기 전에 한 번에
# 자리를 잡는다 — 그 사이에 비워지면 먼저 넣은 것이 사라진다. b 가 빈 메모에도 들어가지 않으면
# 비우지 않고 1 이다 — 그 항목은 담지 않는다(담으면 누계가 상한을 넘는다). 1 은 if 나 || 로 받는다.
_cr_jq_memo_room() {
    [ "$2" -le "$_CR_JQ_MEMO_BYTE_MAX" ] || return 1
    if [ $(( ${#_CR_JQ_MEMO[@]} + $1 )) -gt "$_CR_JQ_MEMO_MAX" ] || [ $(( _CR_JQ_MEMO_BYTES + $2 )) -gt "$_CR_JQ_MEMO_BYTE_MAX" ]; then
        _CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
    fi
}
# 결과는 출력하지 않고 첫 인자로 받은 변수에 넣는다. $(...) 로 부르면 서브셸이라 저장한
# 메모가 부모 셸에 남지 않는다(실측: 36회 중 33회가 다시 jq 를 띄웠다).
_cr_jq_memo() {
    local _cr_memo_var=$1 _cr_memo_input=$2 _cr_memo_key _cr_memo_out _cr_memo_size
    shift 2
    printf -v _cr_memo_key '%s\037' "$@"
    _cr_memo_key+=$'\036'"$_cr_memo_input"
    if [ -n "${_CR_JQ_MEMO[$_cr_memo_key]+x}" ]; then
        printf -v "$_cr_memo_var" '%s' "${_CR_JQ_MEMO[$_cr_memo_key]}"
        return 0
    fi
    _cr_memo_out=$(jq "$@" <<<"$_cr_memo_input") || return $?
    _cr_byte_length _cr_memo_size "$_cr_memo_key$_cr_memo_out"
    if _cr_jq_memo_room 1 "$_cr_memo_size"; then
        _CR_JQ_MEMO[$_cr_memo_key]=$_cr_memo_out
        _CR_JQ_MEMO_BYTES=$(( _CR_JQ_MEMO_BYTES + _cr_memo_size ))
    fi
    printf -v "$_cr_memo_var" '%s' "$_cr_memo_out"
}
# 메모에 값을 미리 넣는다. 한 번의 jq 로 문서를 만든 연산이, 그 문서에 다음 연산이
# 부를 추출(.id, .owner)의 답도 같은 jq 에서 계산해 넣는다. 값은 그 jq 호출이 냈을
# 출력과 바이트까지 같아야 한다 — tojson 은 jq -c 와 같은 직렬화를 쓴다.
_cr_jq_memo_put() {
    local _cr_memo_value=$1 _cr_memo_input=$2 _cr_memo_key _cr_memo_size _cr_memo_old _cr_memo_new=1
    shift 2
    printf -v _cr_memo_key '%s\037' "$@"
    _cr_memo_key+=$'\036'"$_cr_memo_input"
    # 이미 있는 키는 값만 바뀐다 — 옛 항목의 크기를 빼고 센다. 같은 요청을 검증할 때마다 다시
    # 넣는 곳(_cr_request_schema 의 .type)이 있어, 두 번 세면 크기 상한에 헛닿아 메모를 비운다.
    if [ -n "${_CR_JQ_MEMO[$_cr_memo_key]+x}" ]; then
        _cr_byte_length _cr_memo_old "$_cr_memo_key${_CR_JQ_MEMO[$_cr_memo_key]}"
        _CR_JQ_MEMO_BYTES=$(( _CR_JQ_MEMO_BYTES - _cr_memo_old ))
        _cr_memo_new=0
    fi
    _cr_byte_length _cr_memo_size "$_cr_memo_key$_cr_memo_value"
    if _cr_jq_memo_room "$_cr_memo_new" "$_cr_memo_size"; then
        _CR_JQ_MEMO[$_cr_memo_key]=$_cr_memo_value
        _CR_JQ_MEMO_BYTES=$(( _CR_JQ_MEMO_BYTES + _cr_memo_size ))
    elif [ "$_cr_memo_new" -eq 0 ]; then
        # 옛 항목은 누계에서 이미 뺐다 — 남기면 세지 않는 항목이 된다. 드문 길이라 통째로 비운다.
        _CR_JQ_MEMO=(); _CR_JQ_MEMO_BYTES=0
    fi
    return 0
}
# 메모에 그 호출의 답이 있으면 0. 인자는 _cr_jq_memo_put 의 입력부터와 같다.
_cr_jq_memo_has() {
    local _cr_memo_input=$1 _cr_memo_key
    shift
    printf -v _cr_memo_key '%s\037' "$@"
    _cr_memo_key+=$'\036'"$_cr_memo_input"
    [ -n "${_CR_JQ_MEMO[$_cr_memo_key]+x}" ]
}

# jq 한 번이 보드(A53, loadavg 5.7)에서 412ms 다. 같은 문서를 필드마다 새 프로세스로
# 파싱하면 owner 검증 한 번에 3초가 든다. 필터를 변수로 두고 한 번의 jq 로 합친다.
# 조건 자체는 바꾸지 않는다 — 검증을 줄이는 게 아니라 프로세스 스폰만 줄인다.
# 예외 하나: boot_id·invocation_id·token 에 문자셋 제약을 더했다. 세 값은 전부
# /proc/sys/kernel/random 의 UUID 에서 나오는데 스키마는 "비어 있지만 않으면 됨"
# 이었다. 개행이 든 값이 통과하면 한 번의 jq 로 여러 필드를 받아 오는 쪽의
# 프레이밍이 어긋나므로, 실제 생성기가 내는 문자만 받도록 불변식을 명시한다.
# lifecycle 은 문자열이어야 한다. index() 는 배열 인자를 부분 배열로 찾아서
# ["ACTIVE"] 도 통과시켰다 — 이 필터를 쓰는 판정 모두에 걸리는 구멍이라 여기서
# 막는다 (이슈 #150).
_CR_OWNER_SCHEMA_FILTER='type == "object" and (.boot_id|type == "string" and test("^[A-Za-z0-9._:-]+$")) and (.invocation_id|type == "string" and test("^[A-Za-z0-9._:-]+$")) and (.pid|type == "number" and floor == . and . > 0) and (.proc_start_time|type == "string" and test("^[0-9]+$")) and (.token|type == "string" and test("^[A-Za-z0-9._:-]+$")) and (.created_at|type == "number" and floor == . and . > 0) and (.lifecycle as $l | ($l|type) == "string" and (["STARTING","ACTIVE","APPLYING_CONFIG","RECOVERING","DEGRADED","STOPPING"] | index($l) != null))'
_CR_OWNER_LIVE_MATCH_FILTER='(.boot_id == $boot) and ($ei == "" or .invocation_id == $ei) and ($et == "" or .token == $et)'
# _cr_owner_snapshot_live 의 jq 프로그램. 메모 키가 이 문자열 그대로이므로 접기 필터도 이
# 변수로 같은 프로그램을 돌린다.
_CR_OWNER_LIVE_PROGRAM="if (($_CR_OWNER_SCHEMA_FILTER) and ($_CR_OWNER_LIVE_MATCH_FILTER)) then [(.pid|tostring), .proc_start_time] | join(\"\\n\") else empty end"
_CR_OWNER_EXPORTED_MATCH_FILTER='($b != "" and .boot_id == $b) and ($iv != "" and .invocation_id == $iv) and ($p != "" and (.pid|tostring) == $p) and ($ps != "" and .proc_start_time == $ps) and ($tk != "" and .token == $tk) and ($ca != "" and (.created_at|tostring) == $ca)'
# cam_executor_assert_context 의 루프는 빈 값 검사 없이 동등 비교만 한다. 그 의미를
# 그대로 옮기려면 non-empty 조건이 없는 필터가 따로 필요하다.
_CR_OWNER_EXPORTED_EQ_FILTER='(.boot_id == $b) and (.invocation_id == $iv) and ((.pid|tostring) == $p) and (.proc_start_time == $ps) and (.token == $tk) and ((.created_at|tostring) == $ca)'

_cr_owner_schema() {
    jq -e "$_CR_OWNER_SCHEMA_FILTER" >/dev/null
}
_cr_owner_snapshot_live() {
    local owner=$1 expected_invocation=${2:-} expected_token=${3:-} boot fields pid start actual
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || return 69
    _cr_jq_memo fields "$owner" -r --arg boot "$boot" --arg ei "$expected_invocation" --arg et "$expected_token" \
        "$_CR_OWNER_LIVE_PROGRAM" || return 69
    [ -n "$fields" ] || return 69
    { IFS= read -r pid; IFS= read -r start; } <<<"$fields"
    actual=$(_cr_proc_start "$pid")
    [ -n "$actual" ] && [ "$actual" = "$start" ] || return 69
}
_cr_owner_snapshot_lifecycle_in() {
    local owner=$1 lifecycle allowed
    _cr_jq_memo lifecycle "$owner" -r .lifecycle || return 69
    shift
    for allowed in "$@"; do [ "$lifecycle" = "$allowed" ] && return 0; done
    return 69
}
# 두 문서의 스키마 검증과 6키 비교를 한 번의 jq 로 끝낸다. 기존에는 schema 2회 +
# 키마다 2회 = 14회였고, 이 함수는 _cr_record_owner_ready 를 통해 recovery 경로의
# 모든 가드가 지난다 (camera_hard_reset 은 가드를 25회 부른다).
_CR_OWNER_IMMUTABLE_EQ_FILTER='($a.boot_id == $b.boot_id) and ($a.invocation_id == $b.invocation_id) and ($a.pid == $b.pid) and ($a.proc_start_time == $b.proc_start_time) and ($a.token == $b.token) and ($a.created_at == $b.created_at)'
# _cr_owner_immutable_equal 의 jq 프로그램. 메모 키가 이 문자열 그대로이므로 레코드 가드 접기도
# 이 변수로 같은 프로그램을 돌린다.
_CR_OWNER_IMMUTABLE_PROGRAM="(\$a | ($_CR_OWNER_SCHEMA_FILTER)) and (\$b | ($_CR_OWNER_SCHEMA_FILTER)) and $_CR_OWNER_IMMUTABLE_EQ_FILTER"
_cr_owner_immutable_equal() {
    local saved=$1 current=$2
    local _verdict
    _cr_jq_memo _verdict "" -e -n --argjson a "$saved" --argjson b "$current" \
      "$_CR_OWNER_IMMUTABLE_PROGRAM" \
      >/dev/null 2>&1 || return 1
}
# cam_executor_assert_context 전용. schema + live(boot/invocation/token) + exported 6필드
# 비교를 한 번의 jq 로 끝내고, /proc 확인에 필요한 pid·proc_start_time 과 분기에 쓸
# lifecycle 만 돌려준다. 기존에는 snapshot_live / exported_fields_equal /
# snapshot_lifecycle_in 이 각각 jq 를 띄워 호출당 3회였다.
# 프로그램과 인자는 lifecycle 쓰기가 답을 메모에 넣을 때도 같은 것을 쓴다 (이슈 #168): 메모 키가
# 인자 전부와 프로그램이다. 인자 헬퍼는 boot, ei, et, skip 을 받고 env 6필드는 지금 값을 넣어
# _CR_EXECUTOR_ARGS 를 채운다.
_CR_OWNER_EXECUTOR_PROGRAM="if ($_CR_OWNER_SCHEMA_FILTER)
          and ($_CR_OWNER_EXPORTED_EQ_FILTER)
          and (\$skip == \"1\" or ((.boot_id == \$boot)
               and (\$ei == \"\" or .invocation_id == \$ei)
               and (\$et == \"\" or .token == \$et)))
       then [(.pid|tostring), .proc_start_time, .lifecycle] | join(\"\\n\") else empty end"
_cr_executor_snapshot_args() {
    _CR_EXECUTOR_ARGS=(-r --arg boot "$1" --arg ei "$2" --arg et "$3" --arg skip "$4"
        --arg b "${PIM_CAMERA_OWNER_BOOT_ID:-}" --arg iv "${PIM_CAMERA_OWNER_INVOCATION:-}"
        --arg p "${PIM_CAMERA_OWNER_PID:-}" --arg ps "${PIM_CAMERA_OWNER_PROC_START_TIME:-}"
        --arg tk "${PIM_CAMERA_OWNER_TOKEN:-}" --arg ca "${PIM_CAMERA_OWNER_CREATED_AT:-}")
}
# 메모로 부르고 값을 출력한다. 호출자는 $(...) 로 받으므로 메모를 새로 넣지는 못하지만, 이 프로세스가
# 미리 넣은 답(lifecycle 쓰기)은 서브셸에서도 읽힌다.
_cr_owner_executor_snapshot() {
    local owner=$1 out
    _cr_executor_snapshot_args "$2" "$3" "$4" "$5"
    _cr_jq_memo out "$owner" "${_CR_EXECUTOR_ARGS[@]}" "$_CR_OWNER_EXECUTOR_PROGRAM" || return $?
    printf '%s' "$out"
}
# cam liveness 의 주기 guard 전용. schema + exported 6필드 + 현재 boot + ACTIVE 를
# 한 번의 jq 로 판정하고, 매 호출마다 다시 확인할 /proc tuple 만 돌려준다.
_cr_owner_monitor_snapshot() {
    local owner=$1 boot=$2
    jq -rs --arg boot "$boot" \
          --arg b "${PIM_CAMERA_OWNER_BOOT_ID:-}" --arg iv "${PIM_CAMERA_OWNER_INVOCATION:-}" \
          --arg p "${PIM_CAMERA_OWNER_PID:-}" --arg ps "${PIM_CAMERA_OWNER_PROC_START_TIME:-}" \
          --arg tk "${PIM_CAMERA_OWNER_TOKEN:-}" --arg ca "${PIM_CAMERA_OWNER_CREATED_AT:-}" \
      "if (length == 1)
          and (.[0] | ($_CR_OWNER_SCHEMA_FILTER)
               and ($_CR_OWNER_EXPORTED_MATCH_FILTER)
               and (.boot_id == \$boot)
               and (.lifecycle == \"ACTIVE\"))
       then (.[0] | [(.pid|tostring), .proc_start_time] | join(\"\\n\")) else empty end" <<<"$owner"
}
_cr_owner_matches_exported_context() {
    local verdict
    _cr_jq_memo verdict "$1" -r --arg b "${PIM_CAMERA_OWNER_BOOT_ID:-}" --arg iv "${PIM_CAMERA_OWNER_INVOCATION:-}" \
          --arg p "${PIM_CAMERA_OWNER_PID:-}" --arg ps "${PIM_CAMERA_OWNER_PROC_START_TIME:-}" \
          --arg tk "${PIM_CAMERA_OWNER_TOKEN:-}" --arg ca "${PIM_CAMERA_OWNER_CREATED_AT:-}" \
        "((($_CR_OWNER_SCHEMA_FILTER) and ($_CR_OWNER_EXPORTED_MATCH_FILTER)) | tostring)" || return 69
    [ "$verdict" = true ] || return 69
}
# owner lifecycle 를 같은 프로세스에서 반복 조회하는 monitor 경로용 캐시. 파일이
# atomic rename 되면 stat identity 가 달라져 다음 호출에서 반드시 다시 파싱한다.
_CR_LIFECYCLE_KEY=""
_CR_LIFECYCLE_VAL=""
_cr_load_owner_lifecycle() {
    local stamp
    stamp=$(stat -c '%d:%i:%s:%y' "$(_cr_owner_file)" 2>/dev/null) || stamp=""
    if [ -n "$stamp" ] && [ "$stamp" = "$_CR_LIFECYCLE_KEY" ]; then
        return 0
    fi
    _CR_LIFECYCLE_VAL=$(jq -r '.lifecycle // empty' "$(_cr_owner_file)" 2>/dev/null) || return 1
    _CR_LIFECYCLE_KEY=$stamp
}
cam_owner_assert() { local owner; owner=$(_cr_owner_json); _cr_owner_snapshot_live "$owner" "${1:-}" "${2:-}"; }
# _cr_owner_lifecycle_in 의 두 가드는 같은 owner 텍스트에 jq 를 하나씩 띄운다(live 판정, -r
# .lifecycle). 이 owner 텍스트가 메모에 처음이면 — 새 프로세스(submit 의 cam-recoveryctl)이거나
# owner 가 막 바뀐 경우 — 두 답을 jq 한 번으로 구해 메모에 넣는다 (이슈 #150). 가드는 그대로
# 돌아 메모에서 찾는다. 판정은 바꾸지 않는다: 문서가 하나이고 답이 줄 하나로 바이트까지 같게
# 옮겨질 때만 넣는다 — live 는 같은 프로그램($_CR_OWNER_LIVE_PROGRAM)을 돌려 출력이 없으면 빈
# 값("0"), 하나이고 숫자\n숫자면 "+pid:start", lifecycle 은 대문자·밑줄 문자열이면 "+값", 그 밖은
# "-"(넣지 않음). 넣지 못하면 가드가 예전처럼 jq 를 띄운다(이때 jq 1회가 더 든다). jq 가 실패해도
# 넣지 않을 뿐이고 그 stderr 는 버린다 — 오류는 가드의 jq 가 예전처럼 낸다.
# 두 답을 내는 조각은 owner 문서 하나($o)를 받아 두 줄을 낸다. owner 를 쓰는 jq 도 같은 조각으로
# 쓴 문서의 답을 낸다(_cr_owner_set_lifecycle_locked). 넣는 것은 _cr_owner_guard_put 이 한다.
_CR_OWNER_GUARD_ANSWERS='([ try [ $o | '"$_CR_OWNER_LIVE_PROGRAM"' ] catch null ] | .[0]) as $l
    | (if ($l | type) == "array" and ($l | length) == 0 then "0"
       elif ($l | type) == "array" and ($l | length) == 1 and ($l[0] | type == "string" and test("\\A[0-9]+\\n[0-9]+\\z")) then "+" + ($l[0] | split("\n") | join(":"))
       else "-" end),
      ($o | if type == "object" and (.lifecycle | type == "string" and test("\\A[A-Z_]+\\z")) then "+" + .lifecycle else "-" end)'
_CR_OWNER_GUARD_FOLD_FILTER='if length != 1 then "-", "-" else .[0] as $o | '"$_CR_OWNER_GUARD_ANSWERS"' end'
# _cr_owner_export_fields 의 jq 프로그램. 메모 키가 이 문자열이므로 lifecycle 쓰기의 jq 도 이 변수로
# 같은 프로그램을 돌려 답을 낸다 (이슈 #168).
_CR_OWNER_EXPORT_PROGRAM="if ($_CR_OWNER_SCHEMA_FILTER) then [.boot_id,.invocation_id,(.pid|tostring),.proc_start_time,.token,(.created_at|tostring)] | join(\"\\n\") else empty end"
# 그 답을 한 줄로: 출력이 하나이고 여섯 줄 모두 공백 없는 출력 가능 ASCII 일 때만 "+" 와 탭으로 이은
# 여섯 필드, 그 밖은 "-". 그러면 jq -r 출력을 $(...) 로 받은 값과 바이트까지 같고 줄 나눔도 같다.
# executor 스냅샷의 답(이슈 #168): 가드는 ei·et 로 env 의 invocation·token 을 넘기므로 같은 값으로
# 다시 묶어 같은 프로그램을 돈다. 출력이 하나이고 숫자\n숫자\n대문자 꼴일 때만 "+pid:start:lifecycle".
_CR_OWNER_EXECUTOR_ANSWER='([ try [ $o | ($iv) as $ei | ($tk) as $et | '"$_CR_OWNER_EXECUTOR_PROGRAM"' ] catch null ] | .[0]) as $e
    | if ($e | type) == "array" and ($e | length) == 1 and ($e[0] | type == "string" and test("\\A[0-9]+\\n[0-9]+\\n[A-Z_]+\\z")) then "+" + ($e[0] | split("\n") | join(":")) else "-" end'
_CR_OWNER_EXPORT_ANSWER='([ try [ $o | '"$_CR_OWNER_EXPORT_PROGRAM"' ] catch null ] | .[0]) as $x
    | if ($x | type) == "array" and ($x | length) == 1 and ($x[0] | type == "string" and test("\\A[!-~]+(\\n[!-~]+){5}\\z")) then "+" + ($x[0] | split("\n") | join("\t")) else "-" end'
_cr_owner_guard_put() {
    local owner=$1 boot=$2 live_answer=$3 lifecycle_answer=$4 live need
    # 두 답은 함께 남아야 한다: 메모가 상한 바로 아래면 두 번째 넣기가 메모를 비워 첫 답을
    # 지운다 — 그러면 lifecycle 답만 남아 접기는 건너뛰고 live 가드가 jq 를 띄운다. 둘을 넣을
    # 자리를 먼저 잡는다(키는 owner 텍스트와 프로그램, 값은 몇 줄이다).
    _cr_byte_length need "$owner$owner$_CR_OWNER_LIVE_PROGRAM$boot"
    _cr_jq_memo_room 2 $(( need + 256 )) || return 0
    case "$live_answer" in
        0) _cr_jq_memo_put "" "$owner" -r --arg boot "$boot" --arg ei "" --arg et "" "$_CR_OWNER_LIVE_PROGRAM" ;;
        +*:*) live=${live_answer#+}
              _cr_jq_memo_put "${live%%:*}"$'\n'"${live#*:}" "$owner" -r --arg boot "$boot" --arg ei "" --arg et "" "$_CR_OWNER_LIVE_PROGRAM" ;;
    esac
    [ "$lifecycle_answer" = - ] || _cr_jq_memo_put "${lifecycle_answer#+}" "$owner" -r .lifecycle
}
_cr_owner_guard_fold() {
    local owner=$1 boot out plan=()
    [ -n "$owner" ] || return 0
    ! _cr_jq_memo_has "$owner" -r .lifecycle || return 0
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || return 0
    out=$(jq -rs --arg boot "$boot" --arg ei "" --arg et "" "$_CR_OWNER_GUARD_FOLD_FILTER" <<<"$owner" 2>/dev/null) || return 0
    mapfile -t plan <<<"$out"
    [ "${#plan[@]}" -eq 2 ] || return 0
    _cr_owner_guard_put "$owner" "$boot" "${plan[0]}" "${plan[1]}"
}
_cr_owner_lifecycle_in() { local owner; owner=$(_cr_owner_json); _cr_owner_guard_fold "$owner"; _cr_owner_snapshot_live "$owner" || return 69; _cr_owner_snapshot_lifecycle_in "$owner" "$@"; }
# _cr_record_owner_ready 의 jq 프로그램(메모 키가 이 문자열 그대로다).
_CR_RECORD_READY_PROGRAM="if (length == 1) then .[0] | if ((\$a | ($_CR_OWNER_SCHEMA_FILTER)) and ($_CR_OWNER_SCHEMA_FILTER) and ($_CR_OWNER_LIVE_MATCH_FILTER) and (. as \$b | $_CR_OWNER_IMMUTABLE_EQ_FILTER)) then [.lifecycle, (.pid|tostring), .proc_start_time] | join(\"\\n\") else empty end else empty end"
# 레코드 가드 두 개 — _cr_owner_immutable_equal(레코드의 owner 대 지금 owner)과
# _cr_record_owner_ready — 는 같은 두 owner 로 jq 를 하나씩 띄운다. 이 쌍이 메모에 처음이면 —
# claim, owner 를 쓴 직후의 전이 — 두 답을 jq 한 번으로 구해 넣는다 (이슈 #168). 가드는 그대로
# 돌아 메모에서 찾는다. 판정은 바꾸지 않는다: 지금 owner 가 문서 하나일 때만, 같은 프로그램을
# 돌려 immutable 은 참일 때만("+", jq -e 가 rc 0 으로 찍는 true), ready 는 출력이 없으면 빈 값
# ("0"), 하나이고 대문자\n숫자\n숫자면 "+lifecycle:pid:start" 로 넣는다. 그 밖과 jq 실패는 넣지
# 않는다(stderr 는 버린다 — 오류는 가드의 jq 가 예전처럼 낸다). 두 답은 함께 남도록 자리를 먼저
# 확보한다.
# ready 답($r: 프로그램 출력의 배열)을 한 줄로: 출력이 없으면 "0", 하나이고 대문자\n숫자\n숫자면
# "+lifecycle:pid:start", 그 밖은 "-". 넣는 것은 _cr_record_ready_put 이 한다. submit 도 쓴다.
_CR_RECORD_READY_ANSWER='(if ($r | type) == "array" and ($r | length) == 0 then "0"
       elif ($r | type) == "array" and ($r | length) == 1 and ($r[0] | type == "string" and test("\\A[A-Z_]+\\n[0-9]+\\n[0-9]+\\z")) then "+" + ($r[0] | split("\n") | join(":"))
       else "-" end)'
_CR_RECORD_GUARD_FOLD_FILTER='if length != 1 then "-", "-" else
    ([ .[0] as $b | try ('"$_CR_OWNER_IMMUTABLE_PROGRAM"') catch null ] | .[0]) as $i
    | ([ try [ '"$_CR_RECORD_READY_PROGRAM"' ] catch null ] | .[0]) as $r
    | (if $i == true then "+" else "-" end),
      '"$_CR_RECORD_READY_ANSWER"'
  end'
_cr_record_guard_fold() {
    local saved=$1 current=$2 boot out need plan=() ready
    [ -n "$current" ] || return 0
    ! _cr_jq_memo_has "" -e -n --argjson a "$saved" --argjson b "$current" "$_CR_OWNER_IMMUTABLE_PROGRAM" || return 0
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || return 0
    out=$(jq -rs --argjson a "$saved" --arg boot "$boot" --arg ei "" --arg et "" "$_CR_RECORD_GUARD_FOLD_FILTER" <<<"$current" 2>/dev/null) || return 0
    mapfile -t plan <<<"$out"
    [ "${#plan[@]}" -eq 2 ] || return 0
    _cr_byte_length need "$saved$saved$current$current$_CR_OWNER_IMMUTABLE_PROGRAM$_CR_RECORD_READY_PROGRAM$boot"
    _cr_jq_memo_room 2 $(( need + 256 )) || return 0
    [ "${plan[0]}" != + ] || _cr_jq_memo_put true "" -e -n --argjson a "$saved" --argjson b "$current" "$_CR_OWNER_IMMUTABLE_PROGRAM"
    _cr_record_ready_put "$current" "$saved" "$boot" "${plan[1]}"
}
# _CR_RECORD_READY_ANSWER 의 한 줄을 _cr_record_owner_ready 의 메모 키(지금 owner 텍스트, 레코드의
# owner, boot)로 넣는다. "-" 면 넣지 않는다.
_cr_record_ready_put() {
    local current=$1 saved=$2 boot=$3 answer=$4 ready
    case "$answer" in
        0) _cr_jq_memo_put "" "$current" -r -s --argjson a "$saved" --arg boot "$boot" --arg ei "" --arg et "" "$_CR_RECORD_READY_PROGRAM" ;;
        +*:*:*) ready=${answer#+}
                _cr_jq_memo_put "${ready//:/$'\n'}" "$current" -r -s --argjson a "$saved" --arg boot "$boot" --arg ei "" --arg et "" "$_CR_RECORD_READY_PROGRAM" ;;
    esac
}
# start_cam 처럼 메모가 빈 새 프로세스의 실행자 가드(cam_executor_assert_context)는 active 의 .id,
# 레코드 가드의 .owner, 그 owner 로 본 지금 owner 의 ready 를 jq 세 번으로 구한다. 데몬은 같은
# 요청에서 이미 넣었지만 프로세스가 달라 나누지 못한다. 셋을 jq 한 번으로 구해 넣는다 (이슈
# #168). 판정은 가드가 그대로 메모에서 한다. active 가 문서 하나일 때만 넣고, .id 는 UUID 문자열일
# 때만(전이와 같은 조건), ready 는 지금 owner 가 문서 하나일 때만 _cr_record_guard_fold 와 같은 답으로
# 넣는다. $a 는 가드처럼 -c .owner 텍스트를 다시 파싱한 값이다 — 메모리의 값을 바로 쓰면 1e1000
# 같은 수에서 판정이 갈린다(jq 1.6). ready 는 그 텍스트가 argv 한 칸(128KiB)에 들어갈 때만 넣는다
# — 가드의 --argjson 이 실패하면 69 다.
_CR_ACTIVE_GUARD_FOLD_FILTER='([ $araw | try (fromjson | [.id, (.owner | tojson)]) catch null ] | .[0]) as $x
  | if $x == null then "-", "-", "-" else
      ($x[0] | if type == "string" and test("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z") then . else "-" end),
      $x[1],
      (if length != 1 then "-" else
         ($x[1] | fromjson) as $a
         | ([ try [ '"$_CR_RECORD_READY_PROGRAM"' ] catch null ] | .[0]) as $r
         | '"$_CR_RECORD_READY_ANSWER"'
       end)
    end'
_cr_active_guard_fold() {
    local active=$1 current boot out need size plan=()
    _cr_byte_length size "$active"
    [ "$size" -lt 131072 ] || return 0
    current=$(_cr_owner_json) || return 0
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || return 0
    out=$(jq -rs --rawfile araw <(printf '%s' "$active") --arg boot "$boot" --arg ei "" --arg et "" "$_CR_ACTIVE_GUARD_FOLD_FILTER" <<<"$current" 2>/dev/null) || return 0
    mapfile -t plan <<<"$out"
    [ "${#plan[@]}" -eq 3 ] || return 0
    _cr_byte_length need "$active$active$current${plan[1]}${plan[1]}$_CR_RECORD_READY_PROGRAM$boot"
    _cr_jq_memo_room 3 $(( need + 512 )) || return 0
    [ "${plan[0]}" = - ] || _cr_jq_memo_put "${plan[0]}" "$active" -r .id
    [ "${plan[1]}" != - ] || return 0
    _cr_jq_memo_put "${plan[1]}" "$active" -c .owner
    _cr_byte_length size "${plan[1]}"
    [ "$size" -lt 131072 ] || return 0
    _cr_record_ready_put "$current" "${plan[1]}" "$boot" "${plan[2]}"
}
_cr_record_owner_matches() { local saved current; _cr_jq_memo saved "$1" -c .owner || return 1; current=$(_cr_owner_json) || return 1; _cr_record_guard_fold "$saved" "$current"; _cr_owner_immutable_equal "$saved" "$current" && _cr_owner_snapshot_live "$current"; }
# 이 가드는 호출부 31곳을 지난다 (camera_hard_reset 은 25회 부른다). 예전에는
# .owner 추출 + immutable_equal + snapshot_live + lifecycle_in 으로 jq 를 네 번
# 띄웠다. 보드에서 jq 한 번이 307ms 이므로 호출마다 1.2초다. 조건은 그대로 두고
# 프로세스 스폰만 줄인다 — 네 단계가 전부 69 를 돌려주므로 합쳐도 호출자가 보는
# rc 는 달라지지 않는다. /proc 확인만 jq 가 못 하므로 shell 에 남는다.
# ei/et 를 빈 문자열로 넘기는 것은 예전 snapshot_live 호출이 인자를 주지 않아
# 그 두 절이 무조건 참이던 것을 그대로 유지하기 위해서다.
# 문자열의 바이트 수. locale 을 바꾸는 범위를 이 함수 안으로 한정한다.
_cr_byte_length() { local LC_ALL=C; printf -v "$1" '%s' "${#2}"; }
_cr_record_owner_ready() {
    local record=$1 rec_owner rec_bytes current boot fields lifecycle pid start actual allowed
    shift
    # 예전에는 --argjson rec 가 레코드 전체를 argv 한 칸으로 넘겨 128KiB
    # (MAX_ARG_STRLEN) 부터 exec 가 실패했고 그래서 69 였다. 같은 상한을 명시해
    # 그 rc 를 보존한다 — 없으면 claim 이 레코드를 argv 로 넘기다 실패해, 써지기는
    # 하지만 claim 할 수 없는 pending 이 큐를 75 로 막는다. 상한 바로 아래에서도
    # 레코드보다 큰 문서(history·종결 요청)를 argv 로 넘기는 곳은 실패할 수 있다
    # — 이 변경 전부터 같고, 문서를 argv 로 넘기지 않게 바꿀 때 함께 없앤다.
    _cr_byte_length rec_bytes "$record"
    [ "$rec_bytes" -lt 131072 ] || return 69
    current=$(_cr_owner_json) || return 69
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || return 69
    # 메모 키에는 판정이 실제로 읽는 것만 넣는다 (이슈 #150). 필터가 레코드에서
    # 보는 것은 .owner 뿐인데 예전에는 레코드 전체와 허용 lifecycle 목록이 키에
    # 들어가, 전이로 status·updated_at 만 바뀌어도, 허용 목록이 다른 호출자가
    # 불러도 같은 판정을 jq 로 다시 했다. .owner 추출은 _cr_record_owner_matches
    # 와 같은 메모 호출이라 두 가드가 결과를 함께 쓴다. 여러 문서가 이어진
    # 레코드는 추출이 여러 줄이 되어 --argjson 이 거부하므로 예전처럼 69 다.
    _cr_jq_memo rec_owner "$record" -c .owner || return 69
    # -s is what keeps this a single-document check.  Master bound the owner
    # with --argjson, which rejects a JSON stream outright; reading it as input
    # instead would run the filter once per document and accept the record if
    # any one of them matched, so an owner file holding a stale ACTIVE copy
    # beside the current STOPPING one would certify a lifecycle the file no
    # longer holds.  _cr_owner_monitor_snapshot guards the same way.
    # jq's stderr is not discarded: a jq that cannot run this filter must not
    # be indistinguishable from an ownership rejection.
    # lifecycle 은 첫 줄로 내보내고 허용 여부는 아래 shell 에서 비교한다. 두
    # 문서 모두 lifecycle 이 문자열임은 스키마 필터가 보장한다.
    _cr_jq_memo fields "$current" -r -s --argjson a "$rec_owner" --arg boot "$boot" --arg ei "" --arg et "" \
        "$_CR_RECORD_READY_PROGRAM" || return 69
    [ -n "$fields" ] || return 69
    { IFS= read -r lifecycle; IFS= read -r pid; IFS= read -r start; } <<<"$fields"
    actual=$(_cr_proc_start "$pid")
    [ -n "$actual" ] && [ "$actual" = "$start" ] || return 69
    for allowed in "$@"; do [ "$lifecycle" = "$allowed" ] && return 0; done
    return 69
}
_cr_test_owner_rollover() {
    local stage=$1 owner changed field=${PIM_CAMERA_TEST_OWNER_ROLLOVER_FIELD:-created_at}
    [ "${PIM_CAMERA_TEST_OWNER_ROLLOVER:-}" = "$stage" ] || return 0
    owner=$(_cr_owner_json) || return 1
    changed=$(jq -c --arg field "$field" '
      if $field=="boot_id" then .boot_id += "-rolled"
      elif $field=="invocation_id" then .invocation_id += "-rolled"
      elif $field=="pid" then .pid += 1
      elif $field=="proc_start_time" then .proc_start_time = ((.proc_start_time|tonumber)+1|tostring)
      elif $field=="token" then .token += "-rolled"
      elif $field=="created_at" then .created_at += 1
      else error("unsupported owner rollover field") end
    ' <<<"$owner") || return 1
    _cr_atomic_write "$(_cr_owner_file)" "$changed"
}
_cr_mutation_guard() {
    local record=$1 stage=$2
    shift 2
    _cr_test_owner_rollover "$stage" || return 69
    _cr_record_owner_ready "$record" "$@"
}

_CR_REQUEST_SCHEMA_FILTER='type=="object" and (.id|type=="string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and (.type|type=="string") and (.source|type=="string" and length>0) and (.reason|type=="string" and length>0) and (.status|type=="string") and (.created_at|type=="number" and floor==. and .>0) and (.owner|type=="object") and ((has("source_path")|not) or (.source_path|type=="string" and length>0)) and ((has("source_mtime")|not) or (.source_mtime|type=="number" and floor==. and .>=0))'
# _cr_request_schema 의 jq 프로그램. claim 도 같은 문자열로 답을 미리 넣으므로 변수로 둔다 —
# 메모 키는 이 문자열 그대로다.
_CR_REQUEST_SCHEMA_PROGRAM="if (length == 1) then .[0] | if (($_CR_REQUEST_SCHEMA_FILTER)) and (.owner | ($_CR_OWNER_SCHEMA_FILTER)) then .type else empty end else empty end"
_cr_request_schema() {
    local request=$1 type
    # One jq instead of four.  The request schema, the owner schema applied to
    # .owner, and the type extraction all read the same document, and each used
    # to be its own process; a jq spawn measures ~307ms on the board.  The
    # conditions are unchanged - this reduces spawns, not validation - and every
    # failure inside this function already returned 1, so folding them cannot
    # change the code a caller sees.
    # jq's stderr is not discarded here either: at the merge base three of this
    # function's four jq calls let diagnostics through, and a jq that cannot run
    # the filter must not read as "this request is invalid".
    # -s for the same reason as in _cr_record_owner_ready: master used jq -e,
    # whose status follows the last value, so a stream whose final document was
    # invalid was rejected.  Reading a stream as input would accept the request
    # whenever any document in it validated.
    # 메모로 부른다 (이슈 #150): 같은 프로세스가 같은 요청을 여러 번 검증한다(poll·실행·
    # finish). 출력이 있으면 문서는 하나이고 그 .type 을 jq -r 로 찍은 것이므로, 같은
    # 텍스트의 jq -r .type 출력과 바이트까지 같다 — 그 메모도 미리 넣는다.
    _cr_jq_memo type "$request" -r -s "$_CR_REQUEST_SCHEMA_PROGRAM" || return 1
    [ -n "$type" ] || return 1
    _cr_jq_memo_put "$type" "$request" -r .type
    _cr_request_type "$type"
}
_CR_REQUEST_IDENTITY_FILTER='
      def identity: {
        id,type,source,reason,created_at,owner,
        source_path:(.source_path // null),source_mtime:(.source_mtime // null)
      };
      ($left|identity)==($right|identity)
    '
_cr_request_identity_equal() {
    jq -ne --argjson left "$1" --argjson right "$2" "$_CR_REQUEST_IDENTITY_FILTER" >/dev/null
}
_CR_TERMINAL_RESULT_FILTER='
      type=="object" and
      (has("interrupted")|not) and
      (has("interrupted_reason")|not) and
      (.id|type=="string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
      (.type|type=="string") and (.source|type=="string" and length>0) and
      (.reason|type=="string" and length>0) and
      (.created_at|type=="number" and floor==. and .>0) and
      (.finished_at|type=="number" and floor==. and .>0) and
      ((.status=="SUCCEEDED" and .rc==0) or
       (.status=="FAILED" and (.rc|type=="number" and floor==. and .>0))) and
      ((has("source_path")|not) or (.source_path|type=="string" and length>0)) and
      ((has("source_mtime")|not) or (.source_mtime|type=="number" and floor==. and .>=0))
    '
_CR_RESULT_IDENTITY_FILTER='
      def identity: {
        id,type,source,reason,created_at,
        source_path:(.source_path // null),source_mtime:(.source_mtime // null)
      };
      ($request|identity)==($result|identity)
    '
_cr_terminal_result_valid() {
    local result=$1 request=$2
    jq -e "$_CR_TERMINAL_RESULT_FILTER" >/dev/null <<<"$result" || return 1
    _cr_request_type "$(jq -r .type <<<"$result")" || return 1
    jq -ne --argjson request "$request" --argjson result "$result" "$_CR_RESULT_IDENTITY_FILTER" >/dev/null
}
_CR_TERMINAL_REQUEST_FILTER='
      (.finished_at|type=="number" and floor==. and .>0) and
      ((.status=="SUCCEEDED" and .rc==0) or
       (.status=="FAILED" and (.rc|type=="number" and floor==. and .>0)))
    '
_cr_terminal_request_valid() {
    _cr_request_schema "$1" || return 1
    jq -e "$_CR_TERMINAL_REQUEST_FILTER" >/dev/null <<<"$1"
}
_CR_TERMINAL_REQUEST_RESULT_FILTER='
      $request.status==$result.status and $request.rc==$result.rc and
      $request.finished_at==$result.finished_at
    '
_cr_terminal_request_result_equal() {
    jq -ne --argjson request "$1" --argjson result "$2" "$_CR_TERMINAL_REQUEST_RESULT_FILTER" >/dev/null
}
_cr_request_json_equal() {
    jq -ne --argjson left "$1" --argjson right "$2" '$left==$right' >/dev/null
}
_cr_interrupted_terminal_valid() {
    _cr_terminal_request_valid "$1" || return 1
    jq -e '.status=="FAILED" and .rc==70 and .interrupted==true and .interrupted_reason=="owner_stale"' >/dev/null <<<"$1"
}
_cr_request_interruption_absent() {
    jq -e '(has("interrupted")|not) and (has("interrupted_reason")|not)' >/dev/null <<<"$1"
}
_cr_terminal_interruption_valid() {
    if jq -e 'has("interrupted") or has("interrupted_reason")' >/dev/null <<<"$1"; then
        _cr_interrupted_terminal_valid "$1"
    else
        return 0
    fi
}
_CR_TERMINAL_HISTORY_ACTIONS_FILTER='
      def public_action:
        .=="gstapp_restart" or .=="module_reload" or
        .=="camera_hard_reset" or .=="reboot_fallback";
      def uncountered_action:
        .=="ord_restart" or .=="vcm_restart" or .=="policy_reload" or
        .=="gstapp_stop";
      def positive_integer: type=="number" and floor==. and .>0;
      def terminal_status:
        (.status=="SUCCEEDED" and .rc==0) or
        (.status=="FAILED" and (.rc|type=="number" and floor==. and .>0));
      def public_terminal:
        (keys|sort)==["action","finished_at","rc","request_id","started_at","status"] and
        terminal_status and (.started_at|positive_integer) and
        (.finished_at|positive_integer) and .finished_at>=.started_at;
      def public_running:
        (keys|sort)==["action","request_id","started_at","status"] and
        .status=="RUNNING" and (.started_at|positive_integer);
      def uncountered_terminal:
        (keys|sort)==["action","countered","finished_at","rc","request_id","started_at","status"] and
        .countered==false and terminal_status and (.started_at|positive_integer) and
        (.finished_at|positive_integer) and .finished_at>=.started_at;
      ($terminal.status=="FAILED" and $terminal.rc==70 and
       $terminal.interrupted==true and $terminal.interrupted_reason=="owner_stale") as $interrupted |
      ($history|type=="object" and (.actions|type=="array")) and
      (all($history.actions[];
        (.action|type=="string") and .request_id==$terminal.id and
        (if (.action|public_action) then
           (public_terminal or ($interrupted and public_running))
         elif (.action|uncountered_action) then uncountered_terminal
         else false end))) and
      (($history.actions|map(.action)|length)==($history.actions|map(.action)|unique|length))
    '
_cr_terminal_history_actions_valid() {
    local history=$1 terminal=$2
    jq -ne --argjson history "$history" --argjson terminal "$terminal" "$_CR_TERMINAL_HISTORY_ACTIONS_FILTER" >/dev/null
}
_CR_PUBLIC_COUNT_FILTER='[.actions[] | select(
      .action=="gstapp_restart" or .action=="module_reload" or
      .action=="camera_hard_reset" or .action=="reboot_fallback")]|length'
_CR_PUBLIC_COUNTERS_FILTER='
      def public_action:
        .=="gstapp_restart" or .=="module_reload" or
        .=="camera_hard_reset" or .=="reboot_fallback";
      all($history.actions[] | select(.action|public_action); . as $action |
        $state.actions[$action.action].last_request_id==$action.request_id and
        $state.actions[$action.action].last_status==$action.status and
        $state.actions[$action.action].last_started_at==$action.started_at and
        (if $action.status=="RUNNING" then
           $state.actions[$action.action].last_rc==null and
           $state.actions[$action.action].last_finished_at==null
         else
           $state.actions[$action.action].last_rc==$action.rc and
           $state.actions[$action.action].last_finished_at==$action.finished_at
         end))
    '
_cr_terminal_public_counters_valid() {
    local history=$1 state count
    count=$(jq "$_CR_PUBLIC_COUNT_FILTER" <<<"$history") || return 1
    [ "$count" -eq 0 ] && return 0
    if [ $# -ge 2 ]; then
        state=$2
    else
        [ -f "$(_cr_state_file)" ] || return 1
        state=$(cat "$(_cr_state_file)" 2>/dev/null) || return 1
    fi
    _cr_state_valid <<<"$state" 2>/dev/null || return 1
    jq -ne --argjson history "$history" --argjson state "$state" "$_CR_PUBLIC_COUNTERS_FILTER" >/dev/null
}
_cr_terminal_attribution_valid() {
    local history=$1 terminal=$2
    _cr_terminal_interruption_valid "$terminal" || return 1
    _cr_terminal_history_actions_valid "$history" "$terminal" || return 1
    if [ $# -ge 3 ]; then
        _cr_terminal_public_counters_valid "$history" "$3" || return 1
    else
        _cr_terminal_public_counters_valid "$history" || return 1
    fi
    [ ! -e "$(_cr_service_file)" ] || jq -e 'type=="object"' "$(_cr_service_file)" >/dev/null 2>&1
}
_CR_RESULT_FROM_TERMINAL_FILTER='{id,type,status,rc,source,reason,created_at,finished_at} + (if has("source_path") then {source_path} else {} end) + (if has("source_mtime") then {source_mtime} else {} end)'
_cr_result_from_terminal() {
    jq -c "$_CR_RESULT_FROM_TERMINAL_FILTER" <<<"$1"
}
_CR_ARITHMETIC_ACTIONS_FILTER='
      def public_action:
        .=="gstapp_restart" or .=="module_reload" or
        .=="camera_hard_reset" or .=="reboot_fallback";
      .actions[] | select(.request_id==$id and (.action|public_action)) | .action
    '
_cr_history_public_state_arithmetic_valid() {
    local history=$1 state=$2 id=$3 actions action
    actions=$(jq -r --arg id "$id" "$_CR_ARITHMETIC_ACTIONS_FILTER" <<<"$history") || return 1
    for action in $actions; do
        _cr_counter_finish_state_action_valid "$state" "$action" "$id" || return 1
    done
}
_cr_stale_begin_repair_plan() {
    local kind=$1 status=$2 request=$3 history=$4 terminal_history=$5 terminal=$6
    local id public_count state history_request candidate action started prior_id state_next
    id=$(jq -r .id <<<"$request") || return 1
    public_count=$(jq -er --arg id "$id" '
      def public_action:
        .=="gstapp_restart" or .=="module_reload" or
        .=="camera_hard_reset" or .=="reboot_fallback";
      [.actions[] | select(.request_id==$id and (.action|public_action))] | length
    ' <<<"$history") || return 1
    if [ "$public_count" -eq 0 ]; then
        _cr_terminal_attribution_valid "$terminal_history" "$terminal" || return 1
        jq -cn '{mode:"none"}'
        return 0
    fi
    [ -f "$(_cr_state_file)" ] || return 1
    state=$(cat "$(_cr_state_file)" 2>/dev/null) || return 1
    _cr_state_valid <<<"$state" || return 1
    if _cr_terminal_attribution_valid "$terminal_history" "$terminal" "$state" &&
       _cr_history_public_state_arithmetic_valid "$terminal_history" "$state" "$id"; then
        jq -cn '{mode:"none"}'
        return 0
    fi
    [ "$kind" = active ] && [ "$status" = RUNNING ] || return 1
    _cr_request_schema "$request" || return 1
    _cr_request_interruption_absent "$request" || return 1
    [ ! -e "$(_cr_result_file "$id")" ] || return 1
    history_request=$(jq -ce '.request | select(type=="object")' <<<"$history") || return 1
    _cr_request_json_equal "$request" "$history_request" || return 1
    _cr_request_interruption_absent "$history_request" || return 1
    [ "$(jq -r .status <<<"$history_request")" = RUNNING ] || return 1
    candidate=$(jq -ce --arg id "$id" '
      def public_action:
        .=="gstapp_restart" or .=="module_reload" or
        .=="camera_hard_reset" or .=="reboot_fallback";
      [.actions[] | select(
        .request_id==$id and .status=="RUNNING" and (.action|public_action)
      )] as $matches |
      if ($matches|length)==1 then $matches[0] else empty end
    ' <<<"$history") || return 1
    action=$(jq -r .action <<<"$candidate") || return 1
    _cr_counter_finish_history_action_valid "$candidate" "$action" "$id" || return 1
    started=$(jq -r .started_at <<<"$candidate") || return 1
    prior_id=$(jq -r --arg action "$action" '.actions[$action].last_request_id // ""' <<<"$state") || return 1
    [ -n "$prior_id" ] && [ "$prior_id" != "$id" ] || return 1
    _cr_counter_begin_prior_interruption_valid "$state" "$action" "$prior_id" 2>/dev/null || return 1
    state_next=$(jq -c --arg action "$action" --arg id "$id" --argjson started "$started" '
      .actions[$action].failed+=1 |
      .actions[$action].consecutive_failures+=1 |
      .actions[$action].attempted+=1 |
      .actions[$action].last_request_id=$id |
      .actions[$action].last_started_at=$started |
      .actions[$action].last_finished_at=null |
      .actions[$action].last_status="RUNNING" |
      .actions[$action].last_rc=null
    ' <<<"$state") || return 1
    _cr_counter_begin_pair_valid "$history" "$state_next" "$request" "$action" "$id" || return 1
    _cr_history_public_state_arithmetic_valid "$history" "$state_next" "$id" || return 1
    _cr_terminal_attribution_valid "$terminal_history" "$terminal" "$state_next" || return 1
    jq -cn --argjson state "$state_next" '{mode:"repair",state:$state}'
}
_cr_reconcile_abandoned_lease_locked() {
    local old_owner=$1 pending_path active_path lease_path kind request status id history_path result_path
    local history='' history_request result='' terminal history_next result_next finished mode
    local repair_plan='' repair_mode=none repaired_state=''
    pending_path=$(_cr_pending_file); active_path=$(_cr_active_file)
    [ ! -e "$pending_path" ] || [ ! -e "$active_path" ] || return 70
    if [ -e "$pending_path" ]; then lease_path=$pending_path; kind=pending
    elif [ -e "$active_path" ]; then lease_path=$active_path; kind=active
    else return 0
    fi
    request=$(cat "$lease_path" 2>/dev/null) || return 70
    _cr_request_schema "$request" || return 70
    _cr_request_interruption_absent "$request" || return 70
    _cr_owner_immutable_equal "$(jq -c .owner <<<"$request")" "$old_owner" || return 70
    status=$(jq -r .status <<<"$request") || return 70
    case "$kind:$status" in
        pending:PENDING|active:PENDING|active:QUIESCING|active:RUNNING|active:VERIFYING|active:FAILED|active:SUCCEEDED) ;;
        *) return 70 ;;
    esac
    id=$(jq -r .id <<<"$request") || return 70
    history_path=$(_cr_history_file "$id"); result_path=$(_cr_result_file "$id")
    if [ -e "$history_path" ]; then
        history=$(cat "$history_path" 2>/dev/null) || return 70
        jq -e 'type=="object" and (.request|type=="object") and (.actions|type=="array") and all(.actions[];type=="object")' >/dev/null <<<"$history" || return 70
        history_request=$(jq -c .request <<<"$history") || return 70
        _cr_request_schema "$history_request" || return 70
        _cr_terminal_interruption_valid "$history_request" || return 70
        _cr_request_identity_equal "$request" "$history_request" || return 70
    elif [ "$kind" = active ]; then
        return 70
    else
        history=$(jq -cn --argjson request "$request" '{request:$request,actions:[]}') || return 70
        history_request=$request
    fi
    if [ -e "$result_path" ]; then
        result=$(cat "$result_path" 2>/dev/null) || return 70
        _cr_terminal_result_valid "$result" "$request" || return 70
        if _cr_terminal_request_valid "$history_request"; then
            _cr_terminal_request_result_equal "$history_request" "$result" || return 70
            if [ "$kind" = pending ]; then _cr_interrupted_terminal_valid "$history_request" || return 70; fi
            terminal=$history_request
            history_next=$history
            result_next=$result
            mode=terminal_both
        else
            [ "$kind" = active ] || return 70
            case "$(jq -r .status <<<"$history_request")" in SUCCEEDED|FAILED) return 70;; esac
            _cr_request_json_equal "$request" "$history_request" || return 70
            terminal=$(jq -c --argjson result "$result" '.status=$result.status | .rc=$result.rc | .finished_at=$result.finished_at' <<<"$request") || return 70
            history_next=$(jq -c --argjson terminal "$terminal" '.request=$terminal' <<<"$history") || return 70
            result_next=$result
            mode=terminal_result_only
        fi
    elif _cr_terminal_request_valid "$history_request"; then
        if [ "$kind" = pending ]; then _cr_interrupted_terminal_valid "$history_request" || return 70; fi
        terminal=$history_request
        history_next=$history
        result_next=$(_cr_result_from_terminal "$terminal") || return 70
        mode=terminal_history_only
    else
        case "$(jq -r .status <<<"$history_request")" in SUCCEEDED|FAILED) return 70;; esac
        _cr_request_json_equal "$request" "$history_request" || return 70
        finished=$(_cr_now) || return 70
        terminal=$(jq -c --argjson now "$finished" '.status="FAILED" | .rc=70 | .interrupted=true | .finished_at=$now | .interrupted_reason="owner_stale"' <<<"$request") || return 70
        history_next=$(jq -c --argjson terminal "$terminal" '.request=$terminal' <<<"$history") || return 70
        result_next=$(_cr_result_from_terminal "$terminal") || return 70
        mode=interrupted
    fi
    if _cr_interrupted_terminal_valid "$terminal"; then
        case "$kind:$status" in
            pending:PENDING|active:PENDING|active:QUIESCING|active:RUNNING|active:VERIFYING) ;;
            *) return 70 ;;
        esac
    else
        _cr_request_interruption_absent "$terminal" || return 70
    fi
    if [ "$status" = SUCCEEDED ] || [ "$status" = FAILED ]; then
        _cr_terminal_request_valid "$request" || return 70
        _cr_terminal_request_result_equal "$request" "$result_next" || return 70
    fi
    if [ "$mode" = interrupted ]; then
        repair_plan=$(_cr_stale_begin_repair_plan "$kind" "$status" "$request" "$history" "$history_next" "$terminal") || return 70
        repair_mode=$(jq -r '.mode | select(.=="none" or .=="repair")' <<<"$repair_plan") || return 70
        if [ "$repair_mode" = repair ]; then
            repaired_state=$(jq -c '.state | select(type=="object")' <<<"$repair_plan") || return 70
            _cr_terminal_attribution_valid "$history_next" "$terminal" "$repaired_state" || return 70
        else
            _cr_terminal_attribution_valid "$history_next" "$terminal" || return 70
        fi
    else
        _cr_terminal_attribution_valid "$history_next" "$terminal" || return 70
    fi
    if [ "$repair_mode" = repair ]; then
        _cr_atomic_write "$(_cr_state_file)" "$repaired_state" || return 70
        _cr_test_failpoint owner_reconcile_after_state_repair || return 70
    fi
    if [ "$mode" = interrupted ]; then
        _cr_mark_dirty || return 70
    fi
    case "$mode" in
        interrupted|terminal_result_only)
            _cr_atomic_write "$history_path" "$history_next" || return 70
            _cr_test_failpoint owner_reconcile_after_history || return 70
            ;;
    esac
    case "$mode" in
        interrupted|terminal_history_only)
            _cr_atomic_write "$result_path" "$result_next" || return 70
            _cr_test_failpoint owner_reconcile_after_result || return 70
            ;;
    esac
    _cr_remove "$lease_path" || return 70
}
_cr_owner_create_locked() {
    local pid=${1:-$$} boot start invocation token now record current actual owner_boot owner_start
    [[ $pid =~ ^[0-9]+$ ]] || return 64
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || return 70
    start=$(_cr_proc_start "$pid"); [ -n "$start" ] || return 69
    if [ -e "$(_cr_owner_file)" ]; then
        current=$(_cr_owner_json) || return 70
        _cr_owner_schema <<<"$current" || return 69
        owner_boot=$(jq -r .boot_id <<<"$current") || return 70
        owner_start=$(jq -r .proc_start_time <<<"$current") || return 70
        actual=$(_cr_proc_start "$(jq -r .pid <<<"$current")" 2>/dev/null || true)
        if [ "$owner_boot" = "$boot" ] && [ -n "$actual" ] && [ "$actual" = "$owner_start" ]; then return 75; fi
        _cr_reconcile_abandoned_lease_locked "$current" || return $?
    elif [ -e "$(_cr_pending_file)" ] || [ -e "$(_cr_active_file)" ]; then
        return 70
    fi
    invocation=$(_cr_uuid) || return 70; token=$(_cr_uuid) || return 70; now=$(_cr_now)
    record=$(jq -cn --arg boot "$boot" --arg invocation "$invocation" --arg start "$start" --arg token "$token" --argjson pid "$pid" --argjson now "$now" '{boot_id:$boot,invocation_id:$invocation,pid:$pid,proc_start_time:$start,token:$token,created_at:$now,lifecycle:"STARTING"}') || return 70
    _cr_atomic_write "$(_cr_owner_file)" "$record" || return 70
}
# 스키마 검증과 6필드 추출을 한 번의 jq 로 합친다 (기존 jq 7회).
_cr_owner_export_fields() {
    local owner=$1 fields
    # 메모로 부른다 (이슈 #168): 실행 컨텍스트를 세우기 직전에 이 owner 를 쓴 lifecycle 쓰기가 답을 넣어 둔다.
    _cr_jq_memo fields "$owner" -r "$_CR_OWNER_EXPORT_PROGRAM" || return 70
    [ -n "$fields" ] || return 70
    { IFS= read -r PIM_CAMERA_OWNER_BOOT_ID; IFS= read -r PIM_CAMERA_OWNER_INVOCATION
      IFS= read -r PIM_CAMERA_OWNER_PID; IFS= read -r PIM_CAMERA_OWNER_PROC_START_TIME
      IFS= read -r PIM_CAMERA_OWNER_TOKEN; IFS= read -r PIM_CAMERA_OWNER_CREATED_AT; } <<<"$fields"
    export PIM_CAMERA_OWNER_BOOT_ID PIM_CAMERA_OWNER_INVOCATION PIM_CAMERA_OWNER_PID
    export PIM_CAMERA_OWNER_PROC_START_TIME PIM_CAMERA_OWNER_TOKEN PIM_CAMERA_OWNER_CREATED_AT
}
cam_owner_create() {
    local owner
    _cr_lock_call _cr_owner_create_locked "$@" || return $?
    owner=$(_cr_owner_json) || return 70
    _cr_owner_export_fields "$owner"
}
_cr_lifecycle_allowed() {
    case "$1:$2" in STARTING:ACTIVE|STARTING:DEGRADED|STARTING:STOPPING|ACTIVE:APPLYING_CONFIG|ACTIVE:RECOVERING|ACTIVE:DEGRADED|ACTIVE:STOPPING|APPLYING_CONFIG:ACTIVE|APPLYING_CONFIG:DEGRADED|APPLYING_CONFIG:STOPPING|RECOVERING:ACTIVE|RECOVERING:DEGRADED|RECOVERING:STOPPING|DEGRADED:APPLYING_CONFIG|DEGRADED:RECOVERING|DEGRADED:STOPPING) return 0;; esac; return 1
}
_cr_owner_set_lifecycle_locked() {
    local next=$1 owner current updated pair boot stamp need fields skip=0 lines=()
    owner=$(_cr_owner_json); _cr_owner_snapshot_live "$owner" || return 69
    # 현재 lifecycle 조회와 갱신본 생성을 한 번의 jq 로. 갱신본은 검사 통과 후에만 쓴다.
    # 같은 jq 가 갱신본의 두 가드 답(_CR_OWNER_GUARD_ANSWERS)도 낸다 (이슈 #150): 쓴 직후의 가드가
    # jq 를 띄우지 않는다. 문서마다 네 줄 — lifecycle 을 먼저 내므로 예전과 같은 자리에서 실패한다
    # — 이고, 출력이 정확히 네 줄일 때(문서 하나, 한 줄짜리 lifecycle)만 쓴 뒤에 넣는다. 다시
    # 파싱은 try 로 배열 안에 가둬 이 jq 가 새로 실패하지 않는다. boot 를 못 읽으면 넣지 않는다.
    # 다섯째 줄은 갱신본의 export 답(_CR_OWNER_EXPORT_ANSWER)이다 (이슈 #168): 실행 컨텍스트를 세우는
    # _cr_owner_export_fields 가 이 owner 로 jq 를 띄우지 않는다. 이것은 boot 와 무관하다.
    # 여섯째 줄은 executor 스냅샷의 답(_CR_OWNER_EXECUTOR_ANSWER)이다 (이슈 #168): 인자는 가드와 같은
    # 헬퍼로 만든다 — ei·et 는 가드 답이 쓰는 빈 값이고, executor 답은 그 안에서 env 값으로 다시 묶는다.
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || boot=
    [ "${PIM_CAMERA_STOP_EXECUTOR:-}" != 1 ] || skip=1
    _cr_executor_snapshot_args "$boot" "" "" "$skip"
    pair=$(jq "${_CR_EXECUTOR_ARGS[@]}" --arg next "$next" '.lifecycle, (((.lifecycle=$next | .updated_at=(now|floor)) | tojson) as $u
      | $u, ([ $u | try fromjson catch empty ] as $os | if ($os | length) == 1 then ($os[0] as $o | '"$_CR_OWNER_GUARD_ANSWERS"', '"$_CR_OWNER_EXPORT_ANSWER"', '"$_CR_OWNER_EXECUTOR_ANSWER"') else "-", "-", "-", "-" end))' <<<"$owner") || return 70
    { IFS= read -r current; IFS= read -r updated; } <<<"$pair"
    _cr_lifecycle_allowed "$current" "$next" || return 64
    _cr_owner_snapshot_live "$owner" || return 69; _cr_atomic_write "$(_cr_owner_file)" "$updated" || return 70
    # 방금 쓴 owner 의 lifecycle 을 _cr_load_owner_lifecycle 의 캐시에 둔다 (이슈 #168). 그 함수가
    # 이 파일에 띄울 jq(.lifecycle // empty)의 답은 $next 다 — 쓴 텍스트는 문서 하나이고 lifecycle 은
    # 전이표가 허용한 토큰이다. 쓰기는 잠금 안이므로 지금의 파일 정체(stat)가 이 쓰기의 것이고,
    # 다른 쓰기는 새 파일(새 inode)이라 키가 달라 다시 읽는다. stat 이 실패하면 두지 않는다.
    if stamp=$(stat -c '%d:%i:%s:%y' "$(_cr_owner_file)" 2>/dev/null); then
        _CR_LIFECYCLE_KEY=$stamp; _CR_LIFECYCLE_VAL=$next
    fi
    mapfile -t lines <<<"$pair"
    [ "${#lines[@]}" -eq 6 ] || return 0
    # 가드 두 답, export 답, executor 답이 함께 남게 자리를 먼저 잡는다. 못 잡으면 뒤의 둘만 넣지
    # 않는다 — 가드 두 답은 _cr_owner_guard_put 이 예전처럼 자기 자리를 잡는다.
    _cr_byte_length need "$updated$updated$updated$updated$_CR_OWNER_LIVE_PROGRAM$_CR_OWNER_EXPORT_PROGRAM$_CR_OWNER_EXECUTOR_PROGRAM$boot"
    _cr_jq_memo_room 4 $(( need + 1024 )) || { lines[4]=-; lines[5]=-; }
    [ -z "$boot" ] || _cr_owner_guard_put "$updated" "$boot" "${lines[2]}" "${lines[3]}"
    case "${lines[4]}" in
        +*) fields=${lines[4]#+}; _cr_jq_memo_put "${fields//$'\t'/$'\n'}" "$updated" -r "$_CR_OWNER_EXPORT_PROGRAM" ;;
    esac
    # executor 답의 키는 가드가 부를 인자 그대로다: boot 는 파일에서 읽은 값, ei·et 는 env 의
    # invocation·token. boot 를 못 읽었으면 가드도 69 이므로 넣지 않는다.
    case "${lines[5]}" in
        +*:*:*) [ -n "$boot" ] || return 0
                _cr_executor_snapshot_args "$boot" "${PIM_CAMERA_OWNER_INVOCATION:-}" "${PIM_CAMERA_OWNER_TOKEN:-}" "$skip"
                fields=${lines[5]#+}
                _cr_jq_memo_put "${fields//:/$'\n'}" "$updated" "${_CR_EXECUTOR_ARGS[@]}" "$_CR_OWNER_EXECUTOR_PROGRAM" ;;
    esac
    return 0
}
cam_owner_set_lifecycle() { _cr_lock_call _cr_owner_set_lifecycle_locked "$@"; }

_cr_startup_owner_set_recovering_locked() {
    local request=$1 owner active history id updated
    owner=$(_cr_owner_json) || return 69
    _cr_owner_snapshot_live "$owner" || return 69
    _cr_owner_snapshot_lifecycle_in "$owner" STARTING || return 69
    [ ! -e "$(_cr_pending_file)" ] || return 75
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    _cr_request_schema "$active" || return 70
    _cr_request_json_equal "$request" "$active" || return 70
    _cr_record_owner_ready "$active" STARTING || return 69
    jq -e '.status=="PENDING"' >/dev/null <<<"$active" || return 70
    _cr_public_action "$(jq -r .type <<<"$active")" || return 70
    id=$(jq -r .id <<<"$active") || return 70
    history=$(cat "$(_cr_history_file "$id")" 2>/dev/null) || return 70
    jq -e 'type=="object" and (.request|type=="object") and (.actions|type=="array")' >/dev/null <<<"$history" || return 70
    _cr_request_json_equal "$active" "$(jq -c .request <<<"$history")" || return 70
    updated=$(jq -c '.lifecycle="RECOVERING" | .updated_at=(now|floor)' <<<"$owner") || return 70
    _cr_record_owner_ready "$active" STARTING || return 69
    [ ! -e "$(_cr_pending_file)" ] || return 75
    _cr_request_json_equal "$active" "$(cat "$(_cr_active_file)" 2>/dev/null)" || return 70
    _cr_atomic_write "$(_cr_owner_file)" "$updated" || return 70
}

_cr_startup_request_reserve_locked() {
    local type=$1 source=$2 reason=$3 source_path=${4:-} source_mtime=${5:-} owner id now request history
    _cr_public_action "$type" || return 64
    [ -n "$source" ] && [ -n "$reason" ] || return 64
    [ -z "$source_mtime" ] || [[ $source_mtime =~ ^[0-9]+$ ]] || return 64
    owner=$(_cr_owner_json) || return 69
    _cr_owner_snapshot_live "$owner" || return 69
    _cr_owner_snapshot_lifecycle_in "$owner" STARTING || return 69
    [ ! -e "$(_cr_pending_file)" ] && [ ! -e "$(_cr_active_file)" ] || return 75
    id=$(_cr_uuid) || return 70
    now=$(_cr_now) || return 70
    request=$(jq -cn --arg id "$id" --arg type "$type" --arg source "$source" --arg reason "$reason" --arg source_path "$source_path" --arg source_mtime "$source_mtime" --argjson now "$now" --argjson owner "$owner" '{id:$id,type:$type,source:$source,reason:$reason,status:"PENDING",created_at:$now,owner:$owner} + (if $source_path=="" then {} else {source_path:$source_path} end) + (if $source_mtime=="" then {} else {source_mtime:($source_mtime|tonumber)} end)') || return 70
    history=$(jq -cn --argjson request "$request" '{request:$request,actions:[]}') || return 70
    _cr_record_owner_ready "$request" STARTING || return 69
    _cr_atomic_write "$(_cr_history_file "$id")" "$history" || return 70
    _cr_test_failpoint startup_reserve_after_history || return 70
    _cr_record_owner_ready "$request" STARTING || return 69
    _cr_atomic_write "$(_cr_active_file)" "$request" || return 70
    _cr_test_failpoint startup_reserve_after_active || return 70
    _cr_startup_owner_set_recovering_locked "$request" || return $?
    _cr_test_failpoint startup_reserve_after_lifecycle || return 70
    if declare -F _cr_test_startup_reservation_probe >/dev/null 2>&1; then
        _cr_test_startup_reservation_probe || return $?
    fi
    printf '%s\n' "$id"
}
cam_startup_request_reserve() {
    [ "$#" -ge 3 ] && [ "$#" -le 5 ] || return 64
    _cr_lock_call _cr_startup_request_reserve_locked "$@"
}

# submit 의 owner 스키마 판정과 요청 생성을 jq 한 번으로 (이슈 #150 재설계 PR2). owner 원문은
# stdin 으로 받아 -s 로 문서 배열로 읽고, 예전 두 단계를 jq 1.6 의미 그대로 재현한다:
#   _cr_owner_schema(jq -e FILTER, 문서 스트림) — rc 는 마지막 문서만 반영한다: 마지막
#   문서가 평가 오류거나 거짓이면 69, 앞 문서의 오류는 무시, 문서가 없으면 통과(jq 1.7 은
#   빈 입력에 4 를 내 69 였다)
#   요청 생성(--argjson owner) — owner 가 문서 하나가 아니면 70, 시각을 해석할 수 없으면 70
# 출력은 줄마다: 판정(ok|69|70), 요청, 그 요청의 owner(쓴 텍스트를 다시 파싱해 jq -c 와 같은
# 직렬화 — 쓰기 가드가 꺼낼 .owner 를 메모에 미리 넣는다), 쓰기 가드(_cr_record_owner_ready)가
# 같은 owner 텍스트·같은 프로그램으로 낼 답(_CR_RECORD_READY_ANSWER 한 줄, 이슈 #168 — boot 를
# 읽었을 때만 넣는다). 시각과 그 답의 try 는 배열 안에 가둔다 —
# jq 1.6 은 뒤에서 난 오류를 이미 지나간 try 로 되돌아가 잡아 줄을 더 낸다.
_CR_SUBMIT_FILTER='[ .[] | try ('"$_CR_OWNER_SCHEMA_FILTER"') catch "error" ] as $schema
  | ([ $now | try [fromjson] catch null ] | .[0]) as $t
  | if ($schema | length) > 0 and ($schema[-1] == "error" or ($schema[-1] | not)) then "69"
    elif length != 1 or $t == null then "70"
    else ({id:$id,type:$type,source:$source,reason:$reason,status:"PENDING",created_at:$t[0],owner:.[0]}
          + (if $source_path=="" then {} else {source_path:$source_path} end)
          + (if $source_mtime=="" then {} else {source_mtime:($source_mtime|tonumber)} end) | tojson) as $rs
      | "ok", $rs, ($rs | fromjson | .owner | tojson),
        (([ try [ ($rs | fromjson | .owner | tojson | fromjson) as $a | '"$_CR_RECORD_READY_PROGRAM"' ] catch null ] | .[0]) as $r
         | '"$_CR_RECORD_READY_ANSWER"')
    end'
_cr_request_new() {
    local type=$1 source=$2 reason=$3 source_path=${4:-} source_mtime=${5:-} id now owner out rc owner_bytes boot plan=()
    _cr_request_type "$type" || return 64; [ -n "$source" ] && [ -n "$reason" ] || return 64
    [ -z "$source_mtime" ] || [[ $source_mtime =~ ^[0-9]+$ ]] || return 64
    _cr_owner_lifecycle_in ACTIVE DEGRADED || return 69
    [ ! -e "$(_cr_pending_file)" ] && [ ! -e "$(_cr_active_file)" ] || return 75
    id=$(_cr_uuid) || return 70; now=$(_cr_now); owner=$(_cr_owner_json)
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || boot=
    # jq 를 실행하지 못하면(126·127 — 인자가 128KiB 를 넘는 E2BIG 포함) 70, 그 밖의 jq
    # 실패(owner 파싱 실패 등)는 예전 스키마 판정처럼 69 다.
    out=$(jq -rs --arg id "$id" --arg type "$type" --arg source "$source" --arg reason "$reason" --arg source_path "$source_path" --arg source_mtime "$source_mtime" --arg now "$now" --arg boot "$boot" --arg ei "" --arg et "" "$_CR_SUBMIT_FILTER" <<<"$owner") || { rc=$?; [ "$rc" -lt 126 ] || return 70; return 69; }
    mapfile -t plan <<<"$out"
    case "${plan[0]}:${#plan[@]}" in 69:1|70:1|ok:4) ;; *) return 70;; esac
    [ "${plan[0]}" != 69 ] || return 69
    if [ -n "${PIM_CAMERA_OWNER_INVOCATION:-}" ]; then _cr_owner_matches_exported_context "$owner" || return 69; fi
    [ "${plan[0]}" = ok ] || return 70
    # 예전에는 owner 를 --argjson 으로 넘겨 128KiB 부터 exec 가 실패했고 그래서 70 이었다.
    _cr_byte_length owner_bytes "$owner"; [ "$owner_bytes" -lt 131072 ] || return 70
    _cr_jq_memo_put "${plan[2]}" "${plan[1]}" -c .owner
    [ -z "$boot" ] || _cr_record_ready_put "$owner" "${plan[2]}" "$boot" "${plan[3]}"
    _cr_mutation_guard "${plan[1]}" pending ACTIVE DEGRADED || return 69; _cr_atomic_write "$(_cr_pending_file)" "${plan[1]}" || return 70; printf '%s\n' "$id"
}
cam_request_submit() {
    if [ -e "$(_cr_pending_file)" ] || [ -e "$(_cr_active_file)" ]; then
        _cr_owner_lifecycle_in ACTIVE DEGRADED RECOVERING || return $?
        return 75
    fi
    _cr_owner_lifecycle_in ACTIVE DEGRADED || return $?
    _cr_lock_call _cr_request_new "$@" || return $?
    _cr_wake_monitor_wait
}
# 데몬 루프 끝 대기(cam_monitor_wait)의 sleep 을 끝내 새 pending 을 바로 보게 한다 (이슈 #168).
# 대기는 "sleep pid 데몬 pid" 를 _cr_monitor_wait_file 에 내놓고 정상으로 돌아올 때 비운다(TERM trap 으로
# 끝나면 남지만 정지 때 RuntimeDirectory 가 지워지고 아래 대조가 막는다). 그 pid 가 지금도 sleep 이고
# 부모가 적힌 데몬일 때만(기대 부모 $1 이 주어지면 그것과도 같을 때만) TERM 을 보낸다 — 그 밖의
# 프로세스에는 보내지 않는다. 가짜 proc root(테스트)에서는 보내지 않는다. jq 없이 내장 read 로 읽는다.
# 보내지 못해도 데몬은 2초 안에 pending 을 본다. 언제나 0.
_cr_wake_monitor_wait() {
    local expect=${1:-} pid parent stat
    [ "$PIM_CAMERA_PROC_ROOT" = /proc ] || return 0
    { read -r pid parent < "$(_cr_monitor_wait_file)"; } 2>/dev/null || return 0
    [[ $pid =~ ^[0-9]+$ && $parent =~ ^[0-9]+$ ]] || return 0
    [ -z "$expect" ] || [ "$parent" = "$expect" ] || return 0
    { read -r stat < "/proc/$pid/stat"; } 2>/dev/null || return 0
    [[ $stat == "$pid (sleep) "[A-Za-z]" $parent "* ]] || return 0
    kill -TERM "$pid" 2>/dev/null || :
    return 0
}
_cr_history_request() {
    local id=$1 request=$2 history updated
    history=$(cat "$(_cr_history_file "$id")" 2>/dev/null) || return 1
    updated=$(jq -c --argjson request "$request" '.request=$request' <<<"$history") || return 1
    _cr_atomic_write "$(_cr_history_file "$id")" "$updated"
}
# claim 의 모양 판정, id·owner 추출, history 생성을 jq 한 번으로 (이슈 #150 재설계 PR2).
# pending 원문을 -s 로 문서 배열로 읽고 예전 세 단계를 jq 1.6 의미 그대로 재현한다 — jq 는
# 문서 스트림에서 마지막 문서의 결과만 rc 에 반영하고, 오류 난 문서는 출력하지 않는다:
#   모양 검사(jq -e '.id and …') — 마지막 문서가 평가 오류거나 거짓이면 70, 문서가 없으면
#   통과(jq 1.7 은 빈 입력에 4 를 내 70 이었다)
#   owner 대조(jq -c .owner) — .owner 가 오류 없이 나오는 문서가 하나가 아니면 69
#   history 생성(--argjson request) — 문서가 하나가 아니면 대조를 통과해도 70("multi")
# 출력은 줄마다: 판정(ok|multi|69|70), id(UUID 가 아니면 "-"), owner(jq -c .owner 와 같은
# 직렬화), history. id 와 owner 는 메모에 미리 넣어 owner 대조와 claim 직후의 첫 전이가 jq 를
# 다시 띄우지 않는다(active 는 pending 을 옮긴 같은 바이트다). 문서는 argv 로 넘기지 않는다.
# ok 이면 두 줄을 더 낸다 — poll 이 같은 텍스트로 띄우던 jq 의 답이다: 5 _cr_request_schema 의
# 프로그램(같은 문자열)이 -r 로 찍는 값, 6 jq -r .reason 의 값. 값이 줄 하나로 바이트까지 같게
# 옮겨질 때만 "+값"이고(type 은 소문자·밑줄, reason 은 개행·NUL 없는 문자열) 아니면 "-" 다 —
# "-" 면 메모에 넣지 않으므로 poll 이 예전처럼 jq 를 띄운다. 이 두 줄은 오류를 내지 않는다:
# 오류가 나면 claim 이 옮기기 전에 70 이 되어, 옮긴 뒤 poll 이 70 을 내던 예전과 디스크가
# 달라진다. 스키마 프로그램은 try 로 감싸 배열 안에 가둔다(jq 1.6 은 뒤에서 난 오류를 이미
# 지나간 try 로 되돌아가 잡는다).
_CR_CLAIM_FILTER='[ .[] | try (.id and .type and .source and .reason and .owner) catch "error" ] as $shape
  | [ .[] | try (.owner | tojson) catch empty ] as $owners
  | if ($shape | length) > 0 and ($shape[-1] == "error" or ($shape[-1] | not)) then "70"
    elif ($owners | length) != 1 then "69"
    elif length != 1 then "multi", "-", $owners[0], "-"
    else "ok",
      (.[0].id | if type == "string" and test("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z") then . else "-" end),
      (.[0].owner | tojson),
      ({request: .[0], actions: []} | tojson),
      (([ try [ '"$_CR_REQUEST_SCHEMA_PROGRAM"' ] catch null ] | .[0]) as $s
       | if ($s | type) == "array" and ($s | length) == 1 and ($s[0] | type == "string" and test("\\A[a-z_]+\\z")) then "+" + $s[0] else "-" end),
      (.[0].reason | if type == "string" and (explode | all(. != 0 and . != 10)) then "+" + . else "-" end)
    end'
_cr_claim_locked() {
    local pending out pending_bytes plan=()
    _cr_owner_lifecycle_in ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
    [ -f "$(_cr_pending_file)" ] || return 69; [ ! -e "$(_cr_active_file)" ] || return 75
    pending=$(cat "$(_cr_pending_file)") || return 70
    out=$(jq -rs "$_CR_CLAIM_FILTER" <<<"$pending") || return 70
    mapfile -t plan <<<"$out"
    case "${plan[0]}:${#plan[@]}" in 69:1|70:1|ok:6|multi:4) ;; *) return 70;; esac
    [ "${plan[0]}" != 70 ] || return 70
    [ "${plan[0]}" != 69 ] || return 69
    _cr_jq_memo_put "${plan[2]}" "$pending" -c .owner
    [ "${plan[0]}" = ok ] || { _cr_record_owner_matches "$pending" || return 69; return 70; }
    [ "${plan[1]}" = - ] || _cr_jq_memo_put "${plan[1]}" "$pending" -r .id
    [ "${plan[4]}" = - ] || _cr_jq_memo_put "${plan[4]#+}" "$pending" -r -s "$_CR_REQUEST_SCHEMA_PROGRAM"
    [ "${plan[5]}" = - ] || _cr_jq_memo_put "${plan[5]#+}" "$pending" -r .reason
    _cr_record_owner_matches "$pending" || return 69
    # history 경로는 UUID 인 id 로만 만든다 — 아니면 아무것도 쓰지 않고 70 이다(전이와 같은
    # 규칙: 저장 디렉터리 밖을 가리키는 경로를 열지 않는다).
    [ "${plan[1]}" != - ] || return 70
    # 예전에는 history 를 만들 때 pending 을 --argjson 으로 넘겨 128KiB 부터 exec 가
    # 실패했고 그래서 가드(69)보다 먼저 70 이었다.
    _cr_byte_length pending_bytes "$pending"; [ "$pending_bytes" -lt 131072 ] || return 70
    _cr_mutation_guard "$pending" claim_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_history_file "${plan[1]}")" "${plan[3]}" || return 70
    _cr_mutation_guard "$pending" claim_active ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_move "$(_cr_pending_file)" "$(_cr_active_file)" || return 70
}
cam_request_claim() { _cr_lock_call _cr_claim_locked; }
_cr_transition_allowed() { case "$1:$2" in PENDING:QUIESCING|QUIESCING:RUNNING|RUNNING:VERIFYING|VERIFYING:SUCCEEDED|VERIFYING:FAILED|RUNNING:FAILED|QUIESCING:FAILED) return 0;; esac; return 1; }
# 전이 한 번의 판정 재료와 쓸 문서를 jq 한 번으로 만든다 (이슈 #150 재설계).
# active 와 history 원문은 --rawfile 로 넘긴다 — 문서를 argv 로 넘기지 않으므로 크기
# 상한 근처에서도 E2BIG 로 실패하지 않는다. -R stdin 은 쓰지 않는다: jq 는 원시 입력을
# 4095 바이트 조각마다 따로 UTF-8 로 검사해, 조각 경계에 걸친 멀티바이트 문자(한글
# reason 등)를 U+FFFD 로 바꾼다(jq 1.6·1.7.1 실측). history 가 없으면 hhave 가 0 이고
# $p 는 active 하나다. 출력은 줄마다 하나:
#   1 현재 status (대문자·밑줄이 아니면 "-")   2 갱신한 active
#   3 갱신한 active 의 id (UUID 가 아니면 "-")  4 그 owner (jq -c 와 같은 직렬화)
#   5 갱신한 history (history 가 없거나 .request 를 바꿀 수 없는 문서면 "-")
# history 는 jq 에 넘기려고 판정 전에 읽지만(읽기만 한다) 판정 순서(owner 69 →
# 전이표 64 → history 70)와 쓰기 순서, 각 쓰기 앞의 가드는 예전과 같다 — history 를
# 쓸 수 없으면 active 를 쓴 뒤 70 이다. history 는 문서 하나여야 한다: 예전에는 jq 가
# 문서마다 .request 를 바꿔 여러 문서를, 문서가 없는 빈 파일은 빈 줄로 덮어 rc 0 으로
# 받아들였다(승인된 의미 변경 ①, 0개·여러 개 모두). jq 를 실행하지 못하면 70 이다 —
# 예전에는 status 추출이 실패해 허용된 전이도 64 로 보고했다(승인).
# 시각은 문자열로 받아 안에서 해석한다: 해석할 수 없으면 2~5번 줄이 "-" 이고, 전이표
# 판정 뒤에 70 이다 — 예전 --argjson 이 jq 를 실패시키던 자리와 같은 rc 다.
# 메모에 넣는 .id·.owner 와 history 의 request 는 쓰는 텍스트를 다시 파싱한 값에서
# 뽑는다 — 다음 연산의 jq -c .owner 는 디스크의 텍스트를 읽으므로, 메모리의 값을 바로
# 직렬화하면 jq 1.7 에서 Infinity 같은 수의 표기가 달라질 수 있다(e+308 대 E+308).
# 예전 history 갱신도 쓴 텍스트를 --argjson 으로 다시 읽어 넣었다.
# 줄 경계: 정규식의 $ 는 끝 개행 앞에서도 맞으므로 \A…\z 로 묶는다. status 는 예전
# $(jq -r .status) 처럼 NUL 과 끝 개행을 지운 값으로 판정한다. 시각의 try 는 배열 안에
# 가둔다 — jq 1.6 은 뒤에서 난 오류를 이미 지나간 try 로 되돌아가 잡아 줄을 더 낸다.
# 줄이 다섯이 아니면 쓰지 않고 70 이다.
_CR_TRANSITION_FILTER='([$araw] + (if $hhave == "1" then [$hraw] else [] end)) as $p
  | ($p[0] | fromjson) as $a
  | ([ $now | try [fromjson] catch null ] | .[0]) as $t
  | ($a.status
     | if type == "string" then (explode | map(select(. != 0)) | implode | sub("\n+\\z"; "")) else . end
     | if type == "string" and test("\\A[A-Z_]+\\z") then . else "-" end),
    (if $t == null then "-", "-", "-", "-" else
       ($a | .status = $next | .updated_at = $t[0] | tojson) as $us
       | ($us | fromjson) as $u
       | $us,
         ($u.id | if type == "string" and test("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z") then . else "-" end),
         ($u.owner | tojson),
         (if ($p | length) == 2 then (try ($p[1] | fromjson | .request = $u | tojson) catch "-") else "-" end)
     end)'
_cr_transition_locked() {
    local next=$1 active id history="" hhave=0 plan now current updated updated_id updated_owner history_next lines=()
    _cr_owner_lifecycle_in ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69; _cr_record_owner_matches "$active" || return 69
    _cr_jq_memo id "$active" -r .id || id=""
    now=$(_cr_now)
    # history 경로는 UUID 인 id 로만 만든다 — 아니면 history 를 쓸 수 없는 것으로
    # 보고(active 를 쓴 뒤 70) 저장 디렉터리 밖을 가리키는 경로를 열지 않는다.
    if [[ $id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        && history=$(cat "$(_cr_history_file "$id")" 2>/dev/null); then
        hhave=1
    else
        history=""
    fi
    plan=$(jq -nr --rawfile araw <(printf '%s' "$active") --rawfile hraw <(printf '%s' "$history") --arg hhave "$hhave" \
        --arg next "$next" --arg now "$now" "$_CR_TRANSITION_FILTER") || return 70
    mapfile -t lines <<<"$plan"
    [ "${#lines[@]}" -eq 5 ] || return 70
    current=${lines[0]} updated=${lines[1]} updated_id=${lines[2]} updated_owner=${lines[3]} history_next=${lines[4]}
    _cr_transition_allowed "$current" "$next" || return 64
    [ "$updated" != - ] || return 70
    [ "$updated_id" = - ] || _cr_jq_memo_put "$updated_id" "$updated" -r .id
    # 갱신한 active 의 status 는 전이표가 허용한 $next 그대로다(대문자·밑줄). counter 연산이
    # 이 텍스트의 jq -r .status 를 찾는다.
    _cr_jq_memo_put "$next" "$updated" -r .status
    _cr_jq_memo_put "$updated_owner" "$updated" -c .owner
    _cr_mutation_guard "$updated" active ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_active_file)" "$updated" || return 70
    _cr_mutation_guard "$updated" transition_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
    [ "$history_next" != - ] || return 70
    _cr_atomic_write "$(_cr_history_file "$id")" "$history_next" || return 70
}
cam_request_transition() { [ $# -eq 1 ] || return 64; _cr_lock_call _cr_transition_locked "$1"; }

_cr_state_template() { jq -cn '{actions:{gstapp_restart:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null},module_reload:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null},camera_hard_reset:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null},reboot_fallback:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null}}}'; }
# 아래 필터 문자열들은 예전 검증 함수와 counter_begin 의 빠른 경로가 함께 쓴다 —
# 두 쪽의 판정이 어긋날 수 없게 문자열 하나만 둔다 (이슈 #150).
_CR_STATE_FILTER='def action: type=="object" and (keys|sort)==["attempted","consecutive_failures","failed","last_finished_at","last_rc","last_request_id","last_started_at","last_status","succeeded"] and (.attempted|type=="number" and floor==. and .>=0) and (.succeeded|type=="number" and floor==. and .>=0) and (.failed|type=="number" and floor==. and .>=0) and (.consecutive_failures|type=="number" and floor==. and .>=0) and (.last_request_id==null or (.last_request_id|type=="string")) and (.last_started_at==null or (.last_started_at|type=="number")) and (.last_finished_at==null or (.last_finished_at|type=="number")) and (.last_status==null or .last_status=="RUNNING" or .last_status=="SUCCEEDED" or .last_status=="FAILED") and (.last_rc==null or (.last_rc|type=="number" and floor==. and .>=0)); type=="object" and keys==["actions"] and (.actions|type=="object") and (.actions|keys|sort)==["camera_hard_reset","gstapp_restart","module_reload","reboot_fallback"] and all(.actions[];action)'
_cr_state_valid() {
    jq -e "$_CR_STATE_FILTER" >/dev/null
}
_cr_state_init() { [ -f "$(_cr_state_file)" ] && { _cr_state_valid < "$(_cr_state_file)" || return 1; return 0; }; _cr_atomic_write "$(_cr_state_file)" "$(_cr_state_template)"; }
_cr_terminal_valid() { [[ $2 =~ ^[0-9]+$ ]] && { [ "$1" = SUCCEEDED ] && [ "$2" -eq 0 ]; } || { [ "$1" = FAILED ] && [ "$2" -gt 0 ]; }; }
_cr_test_failpoint() { [ "${PIM_CAMERA_TEST_FAILPOINT:-}" != "$1" ]; }
_cr_history_action() {
    jq -c --arg action "$2" --arg id "$3" '.actions[] | select(.action==$action and .request_id==$id)' <<<"$1"
}
_cr_state_action_phase() {
    jq -r --arg action "$2" --arg id "$3" '
      .actions[$action] as $a |
      if $a.last_request_id != $id then "ABSENT"
      elif $a.last_status == "RUNNING" then "RUNNING"
      elif $a.last_status == "SUCCEEDED" or $a.last_status == "FAILED" then "TERMINAL"
      else "CONFLICT" end' <<<"$1"
}
_CR_HISTORY_SHAPE_FILTER='type=="object" and (.request|type=="object") and
         (.actions|type=="array") and all(.actions[];type=="object")'
_CR_OWN_ACTIONS_FILTER='[.actions[] | select(.action==$action and .request_id==$id)]'
_cr_counter_finish_history_action() {
    jq -ce --arg action "$2" --arg id "$3" '
      if '"$_CR_HISTORY_SHAPE_FILTER"'
      then
        '"$_CR_OWN_ACTIONS_FILTER"' as $matches |
        if ($matches|length)==1 then $matches[0] else empty end
      else empty end
    ' <<<"$1"
}
_CR_HISTORY_ACTION_FILTER='
      def positive_integer: type=="number" and floor==. and .>0;
      def terminal_status:
        (.status=="SUCCEEDED" and .rc==0) or
        (.status=="FAILED" and (.rc|type=="number" and floor==. and .>0));
      .action==$action and .request_id==$id and
      if .status=="RUNNING" then
        (keys|sort)==["action","request_id","started_at","status"] and
        (.started_at|positive_integer)
      else
        (keys|sort)==["action","finished_at","rc","request_id","started_at","status"] and
        terminal_status and (.started_at|positive_integer) and
        (.finished_at|positive_integer) and .finished_at>=.started_at
      end
    '
_cr_counter_finish_history_action_valid() {
    jq -e --arg action "$2" --arg id "$3" "$_CR_HISTORY_ACTION_FILTER" >/dev/null <<<"$1"
}
_CR_STATE_ACTION_FILTER='
      def nonnegative_integer: type=="number" and floor==. and .>=0;
      def positive_integer: type=="number" and floor==. and .>0;
      .actions[$action] as $a |
      $a.last_request_id==$id and ($a.attempted|positive_integer) and
      ($a.succeeded|nonnegative_integer) and ($a.failed|nonnegative_integer) and
      ($a.consecutive_failures|nonnegative_integer) and
      $a.consecutive_failures <= $a.failed and
      ($a.last_started_at|positive_integer) and
      if $a.last_status=="RUNNING" then
        $a.attempted == ($a.succeeded + $a.failed + 1) and
        ($a.last_finished_at==null or ($a.last_finished_at|positive_integer)) and
        $a.last_rc==null
      elif $a.last_status=="SUCCEEDED" then
        $a.attempted == ($a.succeeded + $a.failed) and
        $a.last_rc==0 and ($a.last_finished_at|positive_integer) and
        $a.last_finished_at >= $a.last_started_at and
        ($a.succeeded|positive_integer) and $a.consecutive_failures==0
      elif $a.last_status=="FAILED" then
        $a.attempted == ($a.succeeded + $a.failed) and
        ($a.last_rc|positive_integer) and ($a.last_finished_at|positive_integer) and
        $a.last_finished_at >= $a.last_started_at and
        ($a.failed|positive_integer) and ($a.consecutive_failures|positive_integer)
      else false end
    '
_cr_counter_finish_state_action_valid() {
    jq -e --arg action "$2" --arg id "$3" "$_CR_STATE_ACTION_FILTER" >/dev/null <<<"$1"
}
_CR_COUNTER_FINISH_PAIR_FILTER='
      $state.actions[$action] as $a |
      ($history_action.status=="SUCCEEDED" or $history_action.status=="FAILED") and
      $a.last_status==$history_action.status and $a.last_rc==$history_action.rc and
      $a.last_started_at==$history_action.started_at and
      $a.last_finished_at==$history_action.finished_at
    '
_cr_counter_finish_pair_valid() {
    local history=$1 state=$2 action=$3 id=$4 history_action
    _cr_state_valid <<<"$state" || return 1
    history_action=$(_cr_counter_finish_history_action "$history" "$action" "$id" 2>/dev/null) || return 1
    _cr_counter_finish_history_action_valid "$history_action" "$action" "$id" || return 1
    _cr_counter_finish_state_action_valid "$state" "$action" "$id" || return 1
    jq -ne --argjson history_action "$history_action" --argjson state "$state" --arg action "$action" "$_CR_COUNTER_FINISH_PAIR_FILTER" >/dev/null
}
_cr_reconciled_owner_inactive() {
    local request=$1 owner boot owner_boot pid start actual
    owner=$(jq -ce '.owner | select(type=="object")' <<<"$request") || return 1
    _cr_owner_schema <<<"$owner" || return 1
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || return 1
    owner_boot=$(jq -r .boot_id <<<"$owner") || return 1
    [ "$boot" != "$owner_boot" ] && return 0
    pid=$(jq -r .pid <<<"$owner") || return 1
    start=$(jq -r .proc_start_time <<<"$owner") || return 1
    actual=$(_cr_proc_start "$pid" 2>/dev/null || true)
    [ -z "$actual" ] || [ "$actual" != "$start" ]
}
_cr_legacy_reconciled_interruption_valid() {
    local request=$1
    _cr_terminal_request_valid "$request" || return 1
    jq -e '.status=="FAILED" and .rc==70 and .interrupted==true and .interrupted_reason=="interrupted"' >/dev/null <<<"$request" || return 1
    _cr_reconciled_owner_inactive "$request"
}
_cr_counter_begin_prior_interruption_valid() {
    local state=$1 action=$2 prior_id=$3 allow_missing_result=${4:-false}
    local history request history_action result normalized
    _cr_counter_finish_state_action_valid "$state" "$action" "$prior_id" || return 1
    # Pre-fix builds could carry the predecessor's older finish into a new RUNNING record.
    jq -e --arg action "$action" '
      .actions[$action] as $a |
      $a.last_status=="RUNNING" and
      ($a.last_finished_at==null or $a.last_finished_at<$a.last_started_at)
    ' >/dev/null <<<"$state" || return 1
    history=$(cat "$(_cr_history_file "$prior_id")" 2>/dev/null) || return 1
    request=$(jq -ce '.request | select(type=="object")' <<<"$history") || return 1
    [ "$(jq -r .id <<<"$request")" = "$prior_id" ] || return 1
    if _cr_interrupted_terminal_valid "$request"; then
        _cr_terminal_history_actions_valid "$history" "$request" || return 1
        if [ -e "$(_cr_result_file "$prior_id")" ]; then
            result=$(cat "$(_cr_result_file "$prior_id")" 2>/dev/null) || return 1
            _cr_terminal_result_valid "$result" "$request" || return 1
            _cr_terminal_request_result_equal "$request" "$result" || return 1
        else
            # RuntimeDirectory removal discards results, so persistent evidence
            # is sufficient only after the recorded owner is no longer active.
            [ "$allow_missing_result" = true ] || return 1
            _cr_reconciled_owner_inactive "$request" || return 1
        fi
    elif _cr_legacy_reconciled_interruption_valid "$request"; then
        # The legacy boot-history sweep persisted this terminal form without a volatile result.
        [ ! -e "$(_cr_result_file "$prior_id")" ] || return 1
        normalized=$(jq -c '.interrupted_reason="owner_stale"' <<<"$request") || return 1
        _cr_terminal_history_actions_valid "$history" "$normalized" || return 1
    else
        return 1
    fi
    history_action=$(_cr_counter_finish_history_action "$history" "$action" "$prior_id" 2>/dev/null) || return 1
    _cr_counter_finish_history_action_valid "$history_action" "$action" "$prior_id" || return 1
    jq -ne --argjson history_action "$history_action" --argjson state "$state" --arg action "$action" '
      $history_action.status=="RUNNING" and
      $history_action.started_at==$state.actions[$action].last_started_at
    ' >/dev/null || return 1
}
_CR_STATE_ACTION_TEMPLATE='{
            attempted:0,succeeded:0,failed:0,consecutive_failures:0,
            last_request_id:null,last_started_at:null,last_finished_at:null,
            last_status:null,last_rc:null
          }'
_cr_counter_begin_state_mode() {
    local state=$1 action=$2 id=$3 prior_id prior_status
    prior_id=$(jq -r --arg action "$action" '.actions[$action].last_request_id // ""' <<<"$state") || return 1
    if [ -z "$prior_id" ]; then
        jq -e --arg action "$action" ".actions[\$action] == $_CR_STATE_ACTION_TEMPLATE" >/dev/null <<<"$state" || return 1
        printf 'NONE\n'
        return 0
    fi
    _cr_counter_finish_state_action_valid "$state" "$action" "$prior_id" || return 1
    prior_status=$(jq -r --arg action "$action" '.actions[$action].last_status' <<<"$state") || return 1
    if [ "$prior_id" = "$id" ]; then
        [ "$prior_status" = RUNNING ] || return 1
        printf 'CURRENT\n'
    elif [ "$prior_status" = RUNNING ]; then
        _cr_counter_begin_prior_interruption_valid "$state" "$action" "$prior_id" true 2>/dev/null || return 1
        printf 'SETTLE\n'
    else
        printf 'NONE\n'
    fi
}
_cr_counter_begin_pair_valid() {
    local history=$1 state=$2 active=$3 action=$4 id=$5 history_request history_action
    _cr_state_valid <<<"$state" || return 1
    history_request=$(jq -ce '.request | select(type=="object")' <<<"$history") || return 1
    _cr_request_json_equal "$history_request" "$active" || return 1
    history_action=$(_cr_counter_finish_history_action "$history" "$action" "$id" 2>/dev/null) || return 1
    _cr_counter_finish_history_action_valid "$history_action" "$action" "$id" || return 1
    [ "$(jq -r .status <<<"$history_action")" = RUNNING ] || return 1
    _cr_counter_finish_state_action_valid "$state" "$action" "$id" || return 1
    jq -ne --argjson history_action "$history_action" --argjson state "$state" --arg action "$action" '
      $history_action.started_at==$state.actions[$action].last_started_at
    ' >/dev/null
}
_CR_COUNTER_BEGIN_HISTORY_UPDATE='.actions += [{action:$action,request_id:$id,status:"RUNNING",started_at:$now}]'
_CR_COUNTER_BEGIN_STATE_UPDATE='if $settle then .actions[$action].failed+=1 | .actions[$action].consecutive_failures+=1 else . end | .actions[$action].attempted+=1 | .actions[$action].last_request_id=$id | .actions[$action].last_started_at=$now | .actions[$action].last_finished_at=null | .actions[$action].last_status="RUNNING" | .actions[$action].last_rc=null'
# counter_begin 의 빠른 경로 (이슈 #150). 일반 경로 — history 에 이 요청의 action 기록이
# 없고 state 의 직전 요청이 없거나 종결된 경우(ABSENT:ABSENT, 모드 NONE, settle 없음) —
# 에서 예전 코드가 rc 0 으로 끝날 때 거치는 판정을 전부 jq 한 번으로 하고, 쓸 두 문서를
# 낸다. 예전 판정 중 하나라도 확인하지 못하면(다중 문서, 재개·SETTLE 분기, 검사 실패,
# 예전이 argv 로 넘겨 128KiB 부터 실패하던 문서, 해석할 수 없는 시계) "fallback" 만
# 내고, 호출부가 예전 코드를 그대로 실행한다 — 그래서 실패·드문 분기의 rc 는 예전
# 코드가 낸다. 검증 필터는 예전 함수와 같은 문자열이고, 다음 문서의 검증은 예전처럼
# 쓸 텍스트를 다시 파싱한 값으로 한다. 직전 요청 id 는 UUID 일 때만 받는다(예전은
# jq -r 출력을 $(...) 로 받아 개행·NUL 이 든 id 에서 갈렸다). 기준은 jq 1.6 의미다.
# 세 문서는 --rawfile 로 받는다 — -R stdin 은 4095 바이트 조각 경계의 멀티바이트
# 문자를 U+FFFD 로 바꿔, 예전이 파싱한 것과 다른 텍스트를 놓고 판정하게 된다.
# 두 빠른 경로가 함께 쓰는 정의. 판정은 예전 함수와 같은 필터 문자열로 한다. history 의
# request 는 예전처럼 jq 가 다시 출력한 텍스트를 다시 파싱한 값으로 active 와 비교한다
# (tojson|fromjson) — 1e1000 은 출력하면 최댓값이 되므로, 파싱한 값끼리 비교하면 예전이
# 거부하던 입력을 통과시킨다(jq 1.6 실측).
_CR_FAST_PRELUDE='
  def state_valid: '"$_CR_STATE_FILTER"';
  def state_action_valid($action; $id): '"$_CR_STATE_ACTION_FILTER"';
  def history_action_valid($action; $id): '"$_CR_HISTORY_ACTION_FILTER"';
  def argv_ok: utf8bytelength < 131072;
  def own_actions($action; $id): '"$_CR_OWN_ACTIONS_FILTER"';
  def history_shape: '"$_CR_HISTORY_SHAPE_FILTER"';
'
_CR_COUNTER_BEGIN_FAST_FILTER=$_CR_FAST_PRELUDE'
  try (
    (if ($sraw | index("\u0000")) != null then error("nul") else $sraw | fromjson end) as $s
    | ($hraw | fromjson) as $h
    | ($araw | fromjson) as $a
    | ([ $now | try [fromjson] catch null ] | .[0]) as $t
    | if $t == null then error("clock") else . end
    | $s.actions[$action] as $sa
    | $sa.last_request_id as $lri
    | if ($s | state_valid)
         and ($h | history_shape)
         and ($h | own_actions($action; $id) | length) == 0
         and ($h.request | tojson | argv_ok)
         and ($h.request | tojson | fromjson) == $a
         and $lri != $id
         and (($lri == null and $sa == '"$_CR_STATE_ACTION_TEMPLATE"')
              or (($lri | type) == "string"
                  and ($lri | test("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z"))
                  and ($s | state_action_valid($action; $lri))
                  and ($sa.last_status == "SUCCEEDED" or $sa.last_status == "FAILED")))
      then . else error("slow") end
    | false as $settle | $t[0] as $now
    | ($h | '"$_CR_COUNTER_BEGIN_HISTORY_UPDATE"' | tojson) as $hns
    | ($s | '"$_CR_COUNTER_BEGIN_STATE_UPDATE"' | tojson) as $sns
    | ($hns | fromjson) as $hn
    | ($sns | fromjson) as $sn
    | if ($sn | state_valid)
         and ($hn | history_shape)
         and ($hn.request | tojson | argv_ok)
         and ($hn.request | tojson | fromjson) == $a
         and ($hn | own_actions($action; $id) | length) == 1
      then . else error("slow") end
    | ($hn | own_actions($action; $id) | .[0] | tojson) as $has
    | ($has | fromjson) as $ha
    | if ($has | argv_ok) and ($sns | argv_ok)
         and ($ha | history_action_valid($action; $id))
         and $ha.status == "RUNNING"
         and ($sn | state_action_valid($action; $id))
         and $ha.started_at == $sn.actions[$action].last_started_at
      then ["ok", $hns, $sns] else error("slow") end
  ) catch ["fallback"]
  | .[]'
_cr_counter_begin_locked() {
    local action=$1 id=$2 active state history history_request history_action history_next state_next
    local history_count history_phase state_phase state_mode settle=false now active_status active_id
    local history_read=true now_read=true fast_out fast_plan=() state_file
    _cr_public_action "$action" || return 64; _cr_owner_lifecycle_in ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69; _cr_record_owner_matches "$active" || return 69
    _cr_jq_memo active_status "$active" -r .status || active_status=""; [ "$active_status" = RUNNING ] || return 64
    _cr_jq_memo active_id "$active" -r .id || active_id=""; [ "$active_id" = "$id" ] || return 64
    _cr_mutation_guard "$active" counter_init ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
    # state 파일이 있으면 그 검증(_cr_state_init 의 jq)은 빠른 경로가 같은 필터로 파일 바이트를
    # 직접 읽어 한다(이슈 #168, _cr_finish_locked 와 같은 방식). 파일 바이트에 NUL 이 있으면 예전이
    # $(cat) 으로 읽은 값과 다를 수 있어(jq 1.6 은 문자열 안 NUL 을 받는다) 빠른 경로가 거절한다.
    # 빠른 경로가 ok 가 아니면(시도하지 않은 경우 포함) 아래에서 예전 순서로 검증하고 읽는다.
    state_file=$(_cr_state_file); [ -f "$state_file" ] || { _cr_state_init || return 70; }
    # 빠른 경로는 판정 전에 아무것도 쓰지 않는다. 시계는 history 를 읽은 뒤 한 번만
    # 읽고, 예전 코드로 가면 ABSENT:ABSENT 가 같은 값을 쓴다(예전이 시계를 읽던 곳).
    history=$(cat "$(_cr_history_file "$id")" 2>/dev/null) || history_read=false
    if [ "$history_read" = true ]; then
        now=$(_cr_now) || now_read=false
        if [ "$now_read" = true ] && fast_out=$(jq -nr --rawfile sraw "$state_file" --rawfile hraw <(printf '%s' "$history") \
            --rawfile araw <(printf '%s' "$active") --arg action "$action" --arg id "$id" --arg now "$now" "$_CR_COUNTER_BEGIN_FAST_FILTER" 2>/dev/null); then
            mapfile -t fast_plan <<<"$fast_out"
        fi
    fi
    if [ "${#fast_plan[@]}" -eq 3 ] && [ "${fast_plan[0]}" = ok ]; then
        _cr_mutation_guard "$active" counter_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_history_file "$id")" "${fast_plan[1]}" || return 70
        _cr_test_failpoint counter_begin_after_history || return 70
        _cr_mutation_guard "$active" counter_state ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_state_file)" "${fast_plan[2]}" || return 70
        return 0
    fi
    _cr_state_init || return 70; state=$(cat "$state_file") || return 70
    _cr_state_valid <<<"$state" || return 70
    [ "$history_read" = true ] || return 70
    history_request=$(jq -ce '.request | select(type=="object")' <<<"$history") || return 70
    _cr_request_json_equal "$history_request" "$active" || return 70
    history_count=$(jq -er --arg action "$action" --arg id "$id" '[.actions[] | select(.action==$action and .request_id==$id)] | length' <<<"$history") || return 70
    [ "$history_count" -le 1 ] || return 70
    history_phase=ABSENT
    if [ "$history_count" -eq 1 ]; then
        history_action=$(_cr_counter_finish_history_action "$history" "$action" "$id" 2>/dev/null) || return 70
        _cr_counter_finish_history_action_valid "$history_action" "$action" "$id" || return 70
        history_phase=$(jq -r .status <<<"$history_action") || return 70
    fi
    state_phase=$(_cr_state_action_phase "$state" "$action" "$id")
    state_mode=$(_cr_counter_begin_state_mode "$state" "$action" "$id") || return 70
    [ "$state_mode" != SETTLE ] || settle=true
    case "$history_phase:$state_phase" in
        ABSENT:ABSENT)
            [ "$now_read" = true ] || return 70
            history_next=$(jq -c --arg action "$action" --arg id "$id" --argjson now "$now" "$_CR_COUNTER_BEGIN_HISTORY_UPDATE" <<<"$history") || return 70
            state_next=$(jq -c --arg action "$action" --arg id "$id" --argjson now "$now" --argjson settle "$settle" "$_CR_COUNTER_BEGIN_STATE_UPDATE" <<<"$state") || return 70
            _cr_counter_begin_pair_valid "$history_next" "$state_next" "$active" "$action" "$id" || return 70
            _cr_mutation_guard "$active" counter_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_history_file "$id")" "$history_next" || return 70
            _cr_test_failpoint counter_begin_after_history || return 70
            _cr_mutation_guard "$active" counter_state ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_state_file)" "$state_next" || return 70;;
        RUNNING:ABSENT)
            now=$(jq -r '.started_at | select(type=="number" and floor==. and .>0)' <<<"$history_action") || return 70
            [[ $now =~ ^[0-9]+$ ]] || return 70
            state_next=$(jq -c --arg action "$action" --arg id "$id" --argjson now "$now" --argjson settle "$settle" "$_CR_COUNTER_BEGIN_STATE_UPDATE" <<<"$state") || return 70
            _cr_counter_begin_pair_valid "$history" "$state_next" "$active" "$action" "$id" || return 70
            _cr_mutation_guard "$active" counter_state ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_state_file)" "$state_next" || return 70;;
        ABSENT:RUNNING)
            [ "$state_mode" = CURRENT ] || return 70
            now=$(jq -r --arg action "$action" '.actions[$action].last_started_at | select(type=="number" and floor==. and .>0)' <<<"$state") || return 70
            [[ $now =~ ^[0-9]+$ ]] || return 70
            history_next=$(jq -c --arg action "$action" --arg id "$id" --argjson now "$now" "$_CR_COUNTER_BEGIN_HISTORY_UPDATE" <<<"$history") || return 70
            _cr_counter_begin_pair_valid "$history_next" "$state" "$active" "$action" "$id" || return 70
            _cr_mutation_guard "$active" counter_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_history_file "$id")" "$history_next" || return 70;;
        *) return 64;;
    esac
}
cam_action_counter_begin() { [ $# -eq 2 ] || return 64; _cr_lock_call _cr_counter_begin_locked "$@"; }
_CR_COUNTER_FINISH_HISTORY_UPDATE='.actions |= map(if .action==$action and .request_id==$id and .status=="RUNNING" then .status=$status | .rc=$rc | .finished_at=$now else . end)'
_CR_COUNTER_FINISH_STATE_UPDATE='.actions[$action].last_request_id=$id | .actions[$action].last_finished_at=$now | .actions[$action].last_status=$status | .actions[$action].last_rc=$rc | if $status=="SUCCEEDED" then .actions[$action].succeeded+=1 | .actions[$action].consecutive_failures=0 else .actions[$action].failed+=1 | .actions[$action].consecutive_failures+=1 end'
# counter_finish 의 빠른 경로 (이슈 #150, counter_begin 과 같은 틀). 일반 경로 — history 의
# 이 요청 action 과 state 의 counter 가 둘 다 RUNNING — 에서 예전 코드가 rc 0 으로 끝날 때
# 거치는 판정을 jq 한 번으로 하고 쓸 두 문서를 낸다. 하나라도 확인하지 못하면 "fallback"
# 이고 예전 코드를 그대로 실행한다(재개 분기 RUNNING:TERMINAL·종결:RUNNING 포함). 예전의
# bash 단계도 그대로 따른다: started_at 은 jq -r 이 출력한 텍스트로 비교했으므로 같은
# jq 의 tostring 으로 비교한다(jq 1.7 은 수 리터럴을 보존해 1700000001.0 처럼 출력한다).
# 시각과 started_at 의 [ -ge ] 비교, rc 의 --argjson 은 정규 10진수(15자리 이하, rc 는
# 9자리 이하)일 때만 빠른 경로가 맡는다 — 그 밖의 표기는 예전 코드가 판정한다. 세
# 문서는 --rawfile 로 받는다(-R 은 4095 바이트 조각 경계의 멀티바이트 문자를 깨뜨린다).
# 필터 안의 $state 는 갱신한 뒤의 state 다(원본은 $s) — 짝 검증 필터가 이 이름을 쓴다.
_CR_COUNTER_FINISH_FAST_FILTER=$_CR_FAST_PRELUDE'
  try (
    (if ($sraw | index("\u0000")) != null then error("nul") else $sraw | fromjson end) as $s
    | ($hraw | fromjson) as $h
    | ($araw | fromjson) as $a
    | if ($now | test("\\A[1-9][0-9]{0,14}\\z")) and ($rcraw | test("\\A(0|[1-9][0-9]{0,8})\\z"))
      then . else error("args") end
    | ($now | fromjson) as $now
    | ($rcraw | fromjson) as $rc
    | if ($s | state_valid)
         and ($h | history_shape)
         and ($h.request | tojson | argv_ok)
         and ($h.request | tojson | fromjson) == $a
         and ($h | own_actions($action; $id) | length) == 1
      then . else error("slow") end
    | ($h | own_actions($action; $id) | .[0] | tojson | fromjson) as $ha
    | $s.actions[$action] as $sa
    | ($ha.started_at | tostring) as $started
    | if ($ha | history_action_valid($action; $id)) and $ha.status == "RUNNING"
         and ($s | state_action_valid($action; $id)) and $sa.last_status == "RUNNING"
         and $started == ($sa.last_started_at | tostring)
         and ($started | test("\\A[1-9][0-9]{0,14}\\z")) and $now >= ($started | tonumber)
      then . else error("slow") end
    | ($h | '"$_CR_COUNTER_FINISH_HISTORY_UPDATE"' | tojson) as $hns
    | ($s | '"$_CR_COUNTER_FINISH_STATE_UPDATE"' | tojson) as $sns
    | ($hns | fromjson) as $hn
    | ($sns | fromjson) as $state
    | if ($state | state_valid) and ($hn | history_shape)
         and ($hn | own_actions($action; $id) | length) == 1
      then . else error("slow") end
    | ($hn | own_actions($action; $id) | .[0] | tojson) as $has
    | ($has | fromjson) as $history_action
    | if ($has | argv_ok) and ($sns | argv_ok)
         and ($history_action | history_action_valid($action; $id))
         and ($state | state_action_valid($action; $id))
         and ('"$_CR_COUNTER_FINISH_PAIR_FILTER"')
      then ["ok", $hns, $sns] else error("slow") end
  ) catch ["fallback"]
  | .[]'
_cr_counter_finish_locked() {
    local action=$1 id=$2 status=$3 rc=$4 active state history history_request history_action history_next state_next
    local history_phase state_phase history_started state_started now phase active_id active_status
    local history_read=true now_read=true fast_out fast_plan=() state_file
    _cr_public_action "$action" || return 64; _cr_terminal_valid "$status" "$rc" || return 64
    _cr_owner_lifecycle_in ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69; _cr_record_owner_matches "$active" || return 69
    _cr_jq_memo active_id "$active" -r .id || active_id=""; [ "$active_id" = "$id" ] || return 64
    _cr_jq_memo active_status "$active" -r .status || active_status=""
    case "$active_status" in RUNNING|VERIFYING) ;; *) return 64;; esac
    _cr_mutation_guard "$active" counter_init ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
    # state 파일이 있으면 그 검증(_cr_state_init 의 jq)은 빠른 경로가 같은 필터로 파일 바이트를
    # 직접 읽어 한다(이슈 #168, _cr_finish_locked 와 같은 방식). 파일 바이트에 NUL 이 있으면 예전이
    # $(cat) 으로 읽은 값과 다를 수 있어(jq 1.6 은 문자열 안 NUL 을 받는다) 빠른 경로가 거절한다.
    # 빠른 경로가 ok 가 아니면(시도하지 않은 경우 포함) 아래에서 예전 순서로 검증하고 읽는다.
    state_file=$(_cr_state_file); [ -f "$state_file" ] || { _cr_state_init || return 70; }
    # 빠른 경로는 판정 전에 아무것도 쓰지 않는다. 시계는 history 를 읽은 뒤 한 번만
    # 읽고, 예전 코드로 가면 RUNNING:RUNNING 이 같은 값을 쓴다(예전이 시계를 읽던 곳).
    history=$(cat "$(_cr_history_file "$id")" 2>/dev/null) || history_read=false
    if [ "$history_read" = true ]; then
        now=$(_cr_now) || now_read=false
        if [ "$now_read" = true ] && fast_out=$(jq -nr --rawfile sraw "$state_file" --rawfile hraw <(printf '%s' "$history") \
            --rawfile araw <(printf '%s' "$active") --arg action "$action" --arg id "$id" --arg status "$status" --arg rcraw "$rc" \
            --arg now "$now" "$_CR_COUNTER_FINISH_FAST_FILTER" 2>/dev/null); then
            mapfile -t fast_plan <<<"$fast_out"
        fi
    fi
    if [ "${#fast_plan[@]}" -eq 3 ] && [ "${fast_plan[0]}" = ok ]; then
        _cr_mutation_guard "$active" counter_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_history_file "$id")" "${fast_plan[1]}" || return 70
        _cr_test_failpoint counter_finish_after_history || return 70
        _cr_mutation_guard "$active" counter_state ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_state_file)" "${fast_plan[2]}" || return 70
        return 0
    fi
    _cr_state_init || return 70; state=$(cat "$state_file") || return 70
    _cr_state_valid <<<"$state" || return 70
    [ "$history_read" = true ] || return 70
    history_request=$(jq -ce '.request | select(type=="object")' <<<"$history") || return 70
    _cr_request_json_equal "$history_request" "$active" || return 70
    history_action=$(_cr_counter_finish_history_action "$history" "$action" "$id" 2>/dev/null) || return 70
    _cr_counter_finish_history_action_valid "$history_action" "$action" "$id" || return 70
    _cr_counter_finish_state_action_valid "$state" "$action" "$id" || return 70
    history_phase=$(jq -r .status <<<"$history_action"); state_phase=$(_cr_state_action_phase "$state" "$action" "$id")
    history_started=$(jq -r .started_at <<<"$history_action") || return 70
    state_started=$(jq -r --arg action "$action" '.actions[$action].last_started_at' <<<"$state") || return 70
    [ "$history_started" = "$state_started" ] || return 70
    phase="$history_phase:$state_phase"
    case "$phase" in
        RUNNING:RUNNING) [ "$now_read" = true ] || return 70 ;;
        RUNNING:TERMINAL)
            jq -e --arg action "$action" --arg status "$status" --argjson rc "$rc" '.actions[$action].last_status==$status and .actions[$action].last_rc==$rc' >/dev/null <<<"$state" || return 70
            now=$(jq -r --arg action "$action" '.actions[$action].last_finished_at | select(type=="number" and floor==. and .>0)' <<<"$state") || return 70
            ;;
        SUCCEEDED:RUNNING|FAILED:RUNNING)
            [ "$history_phase" = "$status" ] && [ "$(jq -r .rc <<<"$history_action")" = "$rc" ] || return 70
            now=$(jq -r '.finished_at | select(type=="number" and floor==. and .>0)' <<<"$history_action") || return 70
            ;;
        SUCCEEDED:TERMINAL|FAILED:TERMINAL) return 64;;
        *) return 64;;
    esac
    [[ $now =~ ^[0-9]+$ ]] || return 70
    [ "$now" -ge "$history_started" ] || return 70
    case "$phase" in
        RUNNING:RUNNING)
            history_next=$(jq -c --arg action "$action" --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson now "$now" "$_CR_COUNTER_FINISH_HISTORY_UPDATE" <<<"$history") || return 70
            state_next=$(jq -c --arg action "$action" --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson now "$now" "$_CR_COUNTER_FINISH_STATE_UPDATE" <<<"$state") || return 70
            ;;
        RUNNING:TERMINAL)
            history_next=$(jq -c --arg action "$action" --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson now "$now" "$_CR_COUNTER_FINISH_HISTORY_UPDATE" <<<"$history") || return 70
            state_next=$state
            ;;
        SUCCEEDED:RUNNING|FAILED:RUNNING)
            history_next=$history
            state_next=$(jq -c --arg action "$action" --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson now "$now" "$_CR_COUNTER_FINISH_STATE_UPDATE" <<<"$state") || return 70
            ;;
    esac
    _cr_counter_finish_pair_valid "$history_next" "$state_next" "$action" "$id" || return 70
    case "$phase" in
        RUNNING:RUNNING)
            _cr_mutation_guard "$active" counter_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_history_file "$id")" "$history_next" || return 70
            _cr_test_failpoint counter_finish_after_history || return 70
            _cr_mutation_guard "$active" counter_state ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_state_file)" "$state_next" || return 70;;
        RUNNING:TERMINAL)
            _cr_mutation_guard "$active" counter_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_history_file "$id")" "$history_next" || return 70;;
        SUCCEEDED:RUNNING|FAILED:RUNNING)
            _cr_mutation_guard "$active" counter_state ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_state_file)" "$state_next" || return 70;;
    esac
}
cam_action_counter_finish() { [ $# -eq 4 ] || return 64; _cr_lock_call _cr_counter_finish_locked "$@"; }
_CR_TERMINAL_UPDATE_FILTER='.status=$status | .rc=$rc | .finished_at=$now'
_CR_HISTORY_TERMINAL_FILTER='.request=$terminal'
# finish 의 빠른 경로 (이슈 #150, counter 두 연산과 같은 틀). 일반 경로 — 결과 파일이
# 없고 history 의 request 가 아직 종결되지 않은 경우 — 에서 예전 코드가 rc 0 으로 끝날
# 때 거치는 판정을 jq 한 번으로 하고 쓸 두 문서(결과, history)를 낸다. 하나라도 확인하지
# 못하면 "fallback" 이고 예전 코드를 그대로 실행한다(재개 분기, 중단 표시가 있는 요청,
# UUID 가 아닌 id, 검사 실패 포함). 예전의 bash 단계도 따른다: type 은 예전이 $(...) 로
# 받은 텍스트를 목록과 비교했으므로 정확히 일치할 때만 받고, 시각과 rc 는 정규 10진수일
# 때만 받는다. 예전이 argv 로 넘겨 128KiB 부터 실패하던 문서(jq 가 다시 출력한
# history.request, 종결 요청, 결과, history_next, state)는 크기 조건이다. active 원문은
# 예전이 그대로 argv 로 넘겼고 앞에 크기 가드가 없으므로, 호출부가 131072 바이트 미만일
# 때만 빠른 경로를 시도한다. active·history 는 bash 가 읽은 텍스트를, state·service-state
# 는 파일을 --rawfile 로 받는다(없으면 빈 파일과 존재 플래그). 그래서 예전이 state 를
# $(cat) 으로 읽을 때 찍던 NUL 경고는 빠른 경로에서 찍히지 않고, 예전이 state 를 읽지
# 않던 경우에 새 경고가 생기지도 않는다. 기준은 jq 1.6 의미다.
_CR_FINISH_FAST_FILTER=$_CR_FAST_PRELUDE'
  def request_type: . as $t | ["gstapp_restart","gstapp_stop","module_reload","camera_hard_reset","reboot_fallback","apply_config"] | index([$t]) != null;
  def request_valid: ('"$_CR_REQUEST_SCHEMA_FILTER"') and (.owner | ('"$_CR_OWNER_SCHEMA_FILTER"')) and (.type | type == "string" and request_type);
  def terminal_request: '"$_CR_TERMINAL_REQUEST_FILTER"';
  def terminal_result: '"$_CR_TERMINAL_RESULT_FILTER"';
  def public_action: . == "gstapp_restart" or . == "module_reload" or . == "camera_hard_reset" or . == "reboot_fallback";
  try (
    ($araw | fromjson) as $a
    | ($hraw | fromjson) as $h
    | if ($now | test("\\A[1-9][0-9]{0,14}\\z")) and ($rcraw | test("\\A(0|[1-9][0-9]{0,8})\\z"))
         and ($id | test("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z")) and $a.id == $id
      then . else error("args") end
    | ($now | fromjson) as $now
    | ($rcraw | fromjson) as $rc
    | if ($h | history_shape) then . else error("slow") end
    | ($h.request | tojson) as $hrs
    | ($hrs | fromjson) as $hr
    | if ($hr | request_valid) and ($hrs | argv_ok)
         and ($a as $left | $hr as $right | '"$_CR_REQUEST_IDENTITY_FILTER"')
         and (($hr | terminal_request) | not)
         and $a == $hr
      then . else error("slow") end
    | ($a | '"$_CR_TERMINAL_UPDATE_FILTER"' | tojson) as $ts
    | ($ts | fromjson) as $t
    | ($t | '"$_CR_RESULT_FROM_TERMINAL_FILTER"' | tojson) as $rs
    | ($rs | fromjson) as $r
    | ($t as $terminal | $h | '"$_CR_HISTORY_TERMINAL_FILTER"' | tojson) as $hns
    | ($hns | fromjson) as $hn
    | if ($ts | argv_ok) and ($rs | argv_ok) and ($hns | argv_ok)
         and ($t | request_valid) and ($t | terminal_request)
         and ($r | terminal_result) and ($r.type | type == "string" and request_type)
         and ($a as $request | $r as $result | '"$_CR_RESULT_IDENTITY_FILTER"')
         and ($t as $request | $r as $result | '"$_CR_TERMINAL_REQUEST_RESULT_FILTER"')
         and (($t | has("interrupted") or has("interrupted_reason")) | not)
         and ($hn as $history | $t as $terminal | '"$_CR_TERMINAL_HISTORY_ACTIONS_FILTER"')
         and ($svc_exists == "0" or ($svcraw | fromjson | type) == "object")
      then . else error("slow") end
    | ($hn | '"$_CR_PUBLIC_COUNT_FILTER"') as $pc
    | if $pc == 0 then .
      elif $state_exists == "1" then
        ($sraw | fromjson) as $s
        | if ($s | state_valid) and ($sraw | argv_ok)
             and ($hn as $history | $s as $state | '"$_CR_PUBLIC_COUNTERS_FILTER"')
             and all($hn.actions[] | select(.request_id == $id and (.action | public_action)) | .action;
                     . as $act | $s | state_action_valid($act; $id))
          then . else error("slow") end
      else error("slow") end
    | ["ok", $rs, $hns]
  ) catch ["fallback"]
  | .[]'
_cr_finish_locked() {
    local status=$1 rc=$2 active id result terminal history history_request history_next state
    local result_path history_path write_result=1 write_history=1 now public_count terminal_req_valid
    local now_read=true fast_out fast_plan=() state_exists=0 state_src=/dev/null svc_exists=0 svc_src=/dev/null active_bytes
    _cr_terminal_valid "$status" "$rc" || return 64; _cr_owner_lifecycle_in ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69; _cr_record_owner_matches "$active" || return 69; _cr_jq_memo id "$active" -r .id || id=""
    result_path=$(_cr_result_file "$id"); history_path=$(_cr_history_file "$id")
    history=$(cat "$history_path" 2>/dev/null) || return 70
    # 빠른 경로는 결과 파일이 없을 때만 시도하고, 판정 전에는 아무것도 쓰지 않는다. 시계는
    # 그 경우에만 한 번 읽고, 예전 코드로 가면 종결 요청을 만드는 분기(결과 파일이 없을
    # 때만 닿는다)가 같은 값을 쓴다.
    if [ ! -e "$result_path" ]; then
        now=$(_cr_now) || now_read=false
        if [ -e "$(_cr_state_file)" ]; then state_exists=1; state_src=$(_cr_state_file); fi
        if [ -e "$(_cr_service_file)" ]; then svc_exists=1; svc_src=$(_cr_service_file); fi
        _cr_byte_length active_bytes "$active"
        if [ "$now_read" = true ] && [ "$active_bytes" -lt 131072 ] && fast_out=$(jq -nr --rawfile araw <(printf '%s' "$active") --rawfile hraw <(printf '%s' "$history") \
            --rawfile sraw "$state_src" --rawfile svcraw "$svc_src" --arg state_exists "$state_exists" --arg svc_exists "$svc_exists" \
            --arg id "$id" --arg status "$status" --arg rcraw "$rc" --arg now "$now" "$_CR_FINISH_FAST_FILTER" 2>/dev/null); then
            mapfile -t fast_plan <<<"$fast_out"
        fi
    fi
    if [ "${#fast_plan[@]}" -eq 3 ] && [ "${fast_plan[0]}" = ok ]; then
        _cr_mutation_guard "$active" result ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
        _cr_atomic_write "$result_path" "${fast_plan[1]}" || return 70
        _cr_test_failpoint request_finish_after_result || return 70
        _cr_mutation_guard "$active" finish_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
        _cr_atomic_write "$history_path" "${fast_plan[2]}" || return 70
        _cr_test_failpoint request_finish_after_history || return 70
        _cr_mutation_guard "$active" active_remove ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_remove "$(_cr_active_file)" || return 70
        return 0
    fi
    jq -e "$_CR_HISTORY_SHAPE_FILTER" >/dev/null <<<"$history" || return 70
    history_request=$(jq -c .request <<<"$history") || return 70
    _cr_request_schema "$history_request" || return 70
    _cr_request_identity_equal "$active" "$history_request" || return 70
    # history_request is fixed from here to the end of this function and nothing
    # between the two branch chains below writes anything, so these predicates
    # are evaluated once instead of twice.  Each is several jq spawns, and a jq
    # spawn measures ~307ms on the board.  Neither hoist adds a call on any
    # path: when a result file exists the first chain skipped the predicate
    # anyway and the second still ran it, so that branch stays at one.
    terminal_req_valid=0
    _cr_terminal_request_valid "$history_request" && terminal_req_valid=1
    if [ "$terminal_req_valid" -eq 0 ]; then
        _cr_request_json_equal "$active" "$history_request" || return 70
    fi
    if [ -e "$result_path" ]; then
        result=$(cat "$result_path" 2>/dev/null) || return 70
        _cr_terminal_result_valid "$result" "$active" || return 70
        [ "$(jq -r .status <<<"$result")" = "$status" ] && [ "$(jq -r .rc <<<"$result")" = "$rc" ] || return 70
        terminal=$(jq -c --argjson result "$result" '.status=$result.status | .rc=$result.rc | .finished_at=$result.finished_at' <<<"$active") || return 70
        write_result=0
    elif [ "$terminal_req_valid" -eq 1 ]; then
        [ "$(jq -r .status <<<"$history_request")" = "$status" ] && [ "$(jq -r .rc <<<"$history_request")" = "$rc" ] || return 70
        terminal=$history_request
        result=$(_cr_result_from_terminal "$terminal") || return 70
    else
        [ "$now_read" = true ] || return 70
        terminal=$(jq -c --arg status "$status" --argjson rc "$rc" --argjson now "$now" "$_CR_TERMINAL_UPDATE_FILTER" <<<"$active") || return 70
        result=$(_cr_result_from_terminal "$terminal") || return 70
    fi
    if [ "$terminal_req_valid" -eq 1 ]; then
        _cr_terminal_request_result_equal "$history_request" "$result" || return 70
        history_next=$history
        write_history=0
    else
        history_next=$(jq -c --argjson terminal "$terminal" "$_CR_HISTORY_TERMINAL_FILTER" <<<"$history") || return 70
    fi
    _cr_terminal_request_valid "$terminal" || return 70
    _cr_terminal_result_valid "$result" "$active" || return 70
    _cr_terminal_request_result_equal "$terminal" "$result" || return 70
    public_count=$(jq "$_CR_PUBLIC_COUNT_FILTER" <<<"$history_next") || return 70
    if [ "$public_count" -gt 0 ]; then
        state=$(cat "$(_cr_state_file)" 2>/dev/null) || return 70
        _cr_state_valid <<<"$state" || return 70
        _cr_terminal_attribution_valid "$history_next" "$terminal" "$state" || return 70
        _cr_history_public_state_arithmetic_valid "$history_next" "$state" "$id" || return 70
    else
        _cr_terminal_attribution_valid "$history_next" "$terminal" || return 70
    fi
    if [ "$write_result" -eq 1 ]; then
        _cr_mutation_guard "$active" result ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
        _cr_atomic_write "$result_path" "$result" || return 70
        _cr_test_failpoint request_finish_after_result || return 70
    fi
    if [ "$write_history" -eq 1 ]; then
        _cr_mutation_guard "$active" finish_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
        _cr_atomic_write "$history_path" "$history_next" || return 70
        _cr_test_failpoint request_finish_after_history || return 70
    fi
    _cr_mutation_guard "$active" active_remove ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_remove "$(_cr_active_file)" || return 70
}
cam_request_finish() { [ $# -eq 2 ] || return 64; _cr_lock_call _cr_finish_locked "$@"; }

_cr_mark_dirty() {
    local current updated
    current=$(cat "$(_cr_service_file)" 2>/dev/null || printf '{}'); jq -e 'type=="object"' >/dev/null <<<"$current" || return 1
    updated=$(jq -c --argjson now "$(_cr_now)" '.dirty=true | .dirty_at=$now' <<<"$current") || return 1; _cr_atomic_write "$(_cr_service_file)" "$updated"
}
_cr_embedded_owner_valid() {
    local file=$1 owner current
    owner=$(jq -c .request.owner "$file" 2>/dev/null) || return 1; current=$(_cr_owner_json) || return 1
    _cr_owner_immutable_equal "$owner" "$current" && _cr_owner_snapshot_live "$current"
}
# history 는 복구가 일어날 때마다 쌓이고 /var/lib 라 재부팅에도 남는다. 파일마다 jq 를
# 띄우면 부팅 시간이 파일 개수에 비례해 늘어난다 (보드 실측: 69개 = jq 69회 = 28초).
# 대부분은 이미 SUCCEEDED/FAILED 로 건너뛸 대상이므로, 한 번의 jq 로 처리 대상만 추린다.
# jq 가 실패하면(파싱 불가 파일 등) 전체를 대상으로 삼아 기존 순회로 폴백한다.
# 뽑는 대상이 '처리할 파일' 이 아니라 '종료 상태로 확인된 파일' 인 점이 중요하다.
# jq 는 값이 하나도 없는 입력(0바이트·공백만)에는 필터를 적용하지 않아 아무것도
# 내보내지 않는데, 그런 파일은 여기서 빠져 결국 처리 대상으로 남는다.
_cr_reconcile_terminal_files() {
    local dir=$1
    jq -r 'select(((.request.status // "") | . == "SUCCEEDED" or . == "FAILED")) | input_filename' "$dir"/*.json 2>/dev/null
}
_cr_reconcile_interrupted_locked() {
    local file history updated changed=0 dir="$PIM_CAMERA_STATE_DIR/recovery/history" files=() pending=() listed
    local -A terminal=()
    mkdir -p "$dir" || return 70
    shopt -s nullglob; files=("$dir"/*.json); shopt -u nullglob
    [ "${#files[@]}" -gt 0 ] || return 0
    if listed=$(_cr_reconcile_terminal_files "$dir"); then
        while IFS= read -r file; do [ -n "$file" ] && terminal["$file"]=1; done <<<"$listed"
        for file in "${files[@]}"; do [ -n "${terminal["$file"]:-}" ] || pending+=("$file"); done
    else
        pending=("${files[@]}")
    fi
    for file in "${pending[@]}"; do
        history=$(cat "$file") || return 70
        case "$(jq -r '.request.status // empty' <<<"$history")" in SUCCEEDED|FAILED) continue;; esac
        _cr_embedded_owner_valid "$file" && continue
        updated=$(jq -c --argjson now "$(_cr_now)" '.request.status="FAILED" | .request.rc=70 | .request.interrupted=true | .request.finished_at=$now | .request.interrupted_reason="interrupted"' <<<"$history") || return 70
        _cr_atomic_write "$file" "$updated" || return 70; changed=1
    done
    [ "$changed" -eq 0 ] || _cr_mark_dirty || return 70
}
cam_reconcile_interrupted() { _cr_lock_call _cr_reconcile_interrupted_locked; }
cam_recovery_status_json() {
    local request_id=${1:-} owner pending active state result
    if [ -n "$request_id" ]; then
        result=$(cat "$(_cr_result_file "$request_id")" 2>/dev/null) || return 69
        jq -e '(.status=="SUCCEEDED" and .rc==0) or (.status=="FAILED" and (.rc|type=="number") and .rc>0)' >/dev/null <<<"$result" || return 70
        printf '%s\n' "$result"; return 0
    fi
    owner=$(cat "$(_cr_owner_file)" 2>/dev/null || printf null); pending=$(cat "$(_cr_pending_file)" 2>/dev/null || printf null); active=$(cat "$(_cr_active_file)" 2>/dev/null || printf null); state=$(cat "$(_cr_state_file)" 2>/dev/null || printf null)
    # 이슈 #61 요구 4 의 "소요 시간". 저장하지 않고 여기서 파생한다 —
    # _cr_state_valid 가 액션별 키를 정확히 9개로 단정하므로 last_duration_s 를
    # state 에 넣으면 이미 배포된 보드의 state.json 이 무효가 되고
    # _cr_state_init(:756) 은 복구 없이 1 을 돌려준다. state 는 파일 그대로
    # 통과시키고 derived 로만 노출해 저장값과 파생값이 어긋날 여지를 없앤다.
    # 단위는 초다 — _cr_now 가 `date +%s` 다. jq 를 더 띄우지 않으려고 같은
    # 호출 안에서 계산한다(보드 실측 jq spawn ~307ms).
    jq -cn --argjson owner "$owner" --argjson pending "$pending" --argjson active "$active" --argjson state "$state" '
      def last_duration_s:
        if (.last_started_at|type=="number") and (.last_finished_at|type=="number")
           and .last_finished_at>=.last_started_at
        then .last_finished_at - .last_started_at else null end;
      {owner:$owner,pending:$pending,active:$active,state:$state,
       derived:(if ($state|type=="object") and ($state.actions|type=="object")
                then {actions:($state.actions|map_values({last_duration_s:last_duration_s}))}
                else null end)}'
}
