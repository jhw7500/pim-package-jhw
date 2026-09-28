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
_cr_public_action() { case "$1" in gstapp_restart|module_reload|camera_hard_reset|reboot_fallback) return 0;; esac; return 1; }
_cr_request_type() { _cr_public_action "$1" || [ "$1" = apply_config ]; }
_cr_owner_json() { cat "$(_cr_owner_file)" 2>/dev/null; }

# jq 한 번이 보드(A53, loadavg 5.7)에서 412ms 다. 같은 문서를 필드마다 새 프로세스로
# 파싱하면 owner 검증 한 번에 3초가 든다. 필터를 변수로 두고 한 번의 jq 로 합친다.
# 조건 자체는 바꾸지 않는다 — 검증을 줄이는 게 아니라 프로세스 스폰만 줄인다.
# 예외 하나: boot_id·invocation_id·token 에 문자셋 제약을 더했다. 세 값은 전부
# /proc/sys/kernel/random 의 UUID 에서 나오는데 스키마는 "비어 있지만 않으면 됨"
# 이었다. 개행이 든 값이 통과하면 한 번의 jq 로 여러 필드를 받아 오는 쪽의
# 프레이밍이 어긋나므로, 실제 생성기가 내는 문자만 받도록 불변식을 명시한다.
_CR_OWNER_SCHEMA_FILTER='type == "object" and (.boot_id|type == "string" and test("^[A-Za-z0-9._:-]+$")) and (.invocation_id|type == "string" and test("^[A-Za-z0-9._:-]+$")) and (.pid|type == "number" and floor == . and . > 0) and (.proc_start_time|type == "string" and test("^[0-9]+$")) and (.token|type == "string" and test("^[A-Za-z0-9._:-]+$")) and (.created_at|type == "number" and floor == . and . > 0) and (.lifecycle as $l | ["STARTING","ACTIVE","APPLYING_CONFIG","RECOVERING","DEGRADED","STOPPING"] | index($l) != null)'
_CR_OWNER_LIVE_MATCH_FILTER='(.boot_id == $boot) and ($ei == "" or .invocation_id == $ei) and ($et == "" or .token == $et)'
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
    fields=$(jq -r --arg boot "$boot" --arg ei "$expected_invocation" --arg et "$expected_token" \
        "if (($_CR_OWNER_SCHEMA_FILTER) and ($_CR_OWNER_LIVE_MATCH_FILTER)) then [(.pid|tostring), .proc_start_time] | join(\"\\n\") else empty end" \
        <<<"$owner") || return 69
    [ -n "$fields" ] || return 69
    { IFS= read -r pid; IFS= read -r start; } <<<"$fields"
    actual=$(_cr_proc_start "$pid")
    [ -n "$actual" ] && [ "$actual" = "$start" ] || return 69
}
_cr_owner_snapshot_lifecycle_in() {
    local owner=$1 lifecycle allowed
    lifecycle=$(jq -r .lifecycle <<<"$owner") || return 69
    shift
    for allowed in "$@"; do [ "$lifecycle" = "$allowed" ] && return 0; done
    return 69
}
# 두 문서의 스키마 검증과 6키 비교를 한 번의 jq 로 끝낸다. 기존에는 schema 2회 +
# 키마다 2회 = 14회였고, 이 함수는 _cr_record_owner_ready 를 통해 recovery 경로의
# 모든 가드가 지난다 (camera_hard_reset 은 가드를 25회 부른다).
_CR_OWNER_IMMUTABLE_EQ_FILTER='($a.boot_id == $b.boot_id) and ($a.invocation_id == $b.invocation_id) and ($a.pid == $b.pid) and ($a.proc_start_time == $b.proc_start_time) and ($a.token == $b.token) and ($a.created_at == $b.created_at)'
_cr_owner_immutable_equal() {
    local saved=$1 current=$2
    jq -e -n --argjson a "$saved" --argjson b "$current" \
      "(\$a | ($_CR_OWNER_SCHEMA_FILTER)) and (\$b | ($_CR_OWNER_SCHEMA_FILTER)) and $_CR_OWNER_IMMUTABLE_EQ_FILTER" \
      >/dev/null 2>&1 || return 1
}
# cam_executor_assert_context 전용. schema + live(boot/invocation/token) + exported 6필드
# 비교를 한 번의 jq 로 끝내고, /proc 확인에 필요한 pid·proc_start_time 과 분기에 쓸
# lifecycle 만 돌려준다. 기존에는 snapshot_live / exported_fields_equal /
# snapshot_lifecycle_in 이 각각 jq 를 띄워 호출당 3회였다.
_cr_owner_executor_snapshot() {
    local owner=$1 boot=$2 ei=$3 et=$4 skip_live=$5
    jq -r --arg boot "$boot" --arg ei "$ei" --arg et "$et" --arg skip "$skip_live" \
          --arg b "${PIM_CAMERA_OWNER_BOOT_ID:-}" --arg iv "${PIM_CAMERA_OWNER_INVOCATION:-}" \
          --arg p "${PIM_CAMERA_OWNER_PID:-}" --arg ps "${PIM_CAMERA_OWNER_PROC_START_TIME:-}" \
          --arg tk "${PIM_CAMERA_OWNER_TOKEN:-}" --arg ca "${PIM_CAMERA_OWNER_CREATED_AT:-}" \
      "if ($_CR_OWNER_SCHEMA_FILTER)
          and ($_CR_OWNER_EXPORTED_EQ_FILTER)
          and (\$skip == \"1\" or ((.boot_id == \$boot)
               and (\$ei == \"\" or .invocation_id == \$ei)
               and (\$et == \"\" or .token == \$et)))
       then [(.pid|tostring), .proc_start_time, .lifecycle] | join(\"\\n\") else empty end" <<<"$owner"
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
    verdict=$(jq -r --arg b "${PIM_CAMERA_OWNER_BOOT_ID:-}" --arg iv "${PIM_CAMERA_OWNER_INVOCATION:-}" \
          --arg p "${PIM_CAMERA_OWNER_PID:-}" --arg ps "${PIM_CAMERA_OWNER_PROC_START_TIME:-}" \
          --arg tk "${PIM_CAMERA_OWNER_TOKEN:-}" --arg ca "${PIM_CAMERA_OWNER_CREATED_AT:-}" \
        "((($_CR_OWNER_SCHEMA_FILTER) and ($_CR_OWNER_EXPORTED_MATCH_FILTER)) | tostring)" <<<"$1") || return 69
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
_cr_owner_lifecycle_in() { local owner; owner=$(_cr_owner_json); _cr_owner_snapshot_live "$owner" || return 69; _cr_owner_snapshot_lifecycle_in "$owner" "$@"; }
_cr_record_owner_matches() { local saved current; saved=$(jq -c .owner <<<"$1") || return 1; current=$(_cr_owner_json) || return 1; _cr_owner_immutable_equal "$saved" "$current" && _cr_owner_snapshot_live "$current"; }
# 이 가드는 호출부 31곳을 지난다 (camera_hard_reset 은 25회 부른다). 예전에는
# .owner 추출 + immutable_equal + snapshot_live + lifecycle_in 으로 jq 를 네 번
# 띄웠다. 보드에서 jq 한 번이 307ms 이므로 호출마다 1.2초다. 조건은 그대로 두고
# 프로세스 스폰만 줄인다 — 네 단계가 전부 69 를 돌려주므로 합쳐도 호출자가 보는
# rc 는 달라지지 않는다. /proc 확인만 jq 가 못 하므로 shell 에 남는다.
# ei/et 를 빈 문자열로 넘기는 것은 예전 snapshot_live 호출이 인자를 주지 않아
# 그 두 절이 무조건 참이던 것을 그대로 유지하기 위해서다.
_cr_record_owner_ready() {
    local record=$1 current boot fields pid start actual allowed=[] sep=
    shift
    current=$(_cr_owner_json) || return 69
    boot=$(cat "$PIM_CAMERA_BOOT_ID_FILE" 2>/dev/null) || return 69
    # The allowed lifecycles go in as one --argjson array rather than through
    # --args.  --args and $ARGS need jq 1.6 and the package declares no jq
    # floor, and jq's own option parser would still claim any argument starting
    # with a hyphen, so a caller's value could turn into a jq option.  Values
    # outside the lifecycle character set are dropped rather than passed on:
    # the owner schema constrains .lifecycle to six enum names, so such a value
    # could never have matched in the shell loop this replaces either.
    allowed='['
    for pid in "$@"; do
        case "$pid" in *[!A-Z_]*|'') continue;; esac
        allowed="$allowed$sep\"$pid\""; sep=,
    done
    allowed="$allowed]"
    pid=
    # -s is what keeps this a single-document check.  Master bound the owner
    # with --argjson, which rejects a JSON stream outright; reading it as input
    # instead would run the filter once per document and accept the record if
    # any one of them matched, so an owner file holding a stale ACTIVE copy
    # beside the current STOPPING one would certify a lifecycle the file no
    # longer holds.  _cr_owner_monitor_snapshot guards the same way.
    # jq's stderr is not discarded: a jq that cannot run this filter must not
    # be indistinguishable from an ownership rejection.
    fields=$(jq -r -s --argjson rec "$record" --arg boot "$boot" --arg ei "" --arg et "" --argjson allowed "$allowed" \
        "if (length == 1) then .[0] | if ((\$rec.owner | ($_CR_OWNER_SCHEMA_FILTER)) and ($_CR_OWNER_SCHEMA_FILTER) and ($_CR_OWNER_LIVE_MATCH_FILTER) and (\$rec.owner as \$a | . as \$b | $_CR_OWNER_IMMUTABLE_EQ_FILTER) and (.lifecycle as \$l | \$allowed | index(\$l) != null)) then [(.pid|tostring), .proc_start_time] | join(\"\\n\") else empty end else empty end" \
        <<<"$current") || return 69
    [ -n "$fields" ] || return 69
    { IFS= read -r pid; IFS= read -r start; } <<<"$fields"
    actual=$(_cr_proc_start "$pid")
    [ -n "$actual" ] && [ "$actual" = "$start" ] || return 69
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
    type=$(jq -r -s "if (length == 1) then .[0] | if (($_CR_REQUEST_SCHEMA_FILTER)) and (.owner | ($_CR_OWNER_SCHEMA_FILTER)) then .type else empty end else empty end" <<<"$request") || return 1
    [ -n "$type" ] || return 1
    _cr_request_type "$type"
}
_cr_request_identity_equal() {
    jq -ne --argjson left "$1" --argjson right "$2" '
      def identity: {
        id,type,source,reason,created_at,owner,
        source_path:(.source_path // null),source_mtime:(.source_mtime // null)
      };
      ($left|identity)==($right|identity)
    ' >/dev/null
}
_cr_terminal_result_valid() {
    local result=$1 request=$2
    jq -e '
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
    ' >/dev/null <<<"$result" || return 1
    _cr_request_type "$(jq -r .type <<<"$result")" || return 1
    jq -ne --argjson request "$request" --argjson result "$result" '
      def identity: {
        id,type,source,reason,created_at,
        source_path:(.source_path // null),source_mtime:(.source_mtime // null)
      };
      ($request|identity)==($result|identity)
    ' >/dev/null
}
_cr_terminal_request_valid() {
    _cr_request_schema "$1" || return 1
    jq -e '
      (.finished_at|type=="number" and floor==. and .>0) and
      ((.status=="SUCCEEDED" and .rc==0) or
       (.status=="FAILED" and (.rc|type=="number" and floor==. and .>0)))
    ' >/dev/null <<<"$1"
}
_cr_terminal_request_result_equal() {
    jq -ne --argjson request "$1" --argjson result "$2" '
      $request.status==$result.status and $request.rc==$result.rc and
      $request.finished_at==$result.finished_at
    ' >/dev/null
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
_cr_terminal_history_actions_valid() {
    local history=$1 terminal=$2
    jq -ne --argjson history "$history" --argjson terminal "$terminal" '
      def public_action:
        .=="gstapp_restart" or .=="module_reload" or
        .=="camera_hard_reset" or .=="reboot_fallback";
      def uncountered_action:
        .=="ord_restart" or .=="vcm_restart" or .=="policy_reload";
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
    ' >/dev/null
}
_cr_terminal_public_counters_valid() {
    local history=$1 state count
    count=$(jq '[.actions[] | select(
      .action=="gstapp_restart" or .action=="module_reload" or
      .action=="camera_hard_reset" or .action=="reboot_fallback")]|length' <<<"$history") || return 1
    [ "$count" -eq 0 ] && return 0
    if [ $# -ge 2 ]; then
        state=$2
    else
        [ -f "$(_cr_state_file)" ] || return 1
        state=$(cat "$(_cr_state_file)" 2>/dev/null) || return 1
    fi
    _cr_state_valid <<<"$state" 2>/dev/null || return 1
    jq -ne --argjson history "$history" --argjson state "$state" '
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
    ' >/dev/null
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
_cr_result_from_terminal() {
    jq -c '{id,type,status,rc,source,reason,created_at,finished_at} + (if has("source_path") then {source_path} else {} end) + (if has("source_mtime") then {source_mtime} else {} end)' <<<"$1"
}
_cr_history_public_state_arithmetic_valid() {
    local history=$1 state=$2 id=$3 actions action
    actions=$(jq -r --arg id "$id" '
      def public_action:
        .=="gstapp_restart" or .=="module_reload" or
        .=="camera_hard_reset" or .=="reboot_fallback";
      .actions[] | select(.request_id==$id and (.action|public_action)) | .action
    ' <<<"$history") || return 1
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
    fields=$(jq -r "if ($_CR_OWNER_SCHEMA_FILTER) then [.boot_id,.invocation_id,(.pid|tostring),.proc_start_time,.token,(.created_at|tostring)] | join(\"\\n\") else empty end" <<<"$owner") || return 70
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
    local next=$1 owner current updated pair
    owner=$(_cr_owner_json); _cr_owner_snapshot_live "$owner" || return 69
    # 현재 lifecycle 조회와 갱신본 생성을 한 번의 jq 로. 갱신본은 검사 통과 후에만 쓴다.
    pair=$(jq -r --arg next "$next" '.lifecycle, ((.lifecycle=$next | .updated_at=(now|floor)) | tojson)' <<<"$owner") || return 70
    { IFS= read -r current; IFS= read -r updated; } <<<"$pair"
    _cr_lifecycle_allowed "$current" "$next" || return 64
    _cr_owner_snapshot_live "$owner" || return 69; _cr_atomic_write "$(_cr_owner_file)" "$updated" || return 70
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

_cr_request_new() {
    local type=$1 source=$2 reason=$3 source_path=${4:-} source_mtime=${5:-} id now owner request
    _cr_request_type "$type" || return 64; [ -n "$source" ] && [ -n "$reason" ] || return 64
    [ -z "$source_mtime" ] || [[ $source_mtime =~ ^[0-9]+$ ]] || return 64
    _cr_owner_lifecycle_in ACTIVE DEGRADED || return 69
    [ ! -e "$(_cr_pending_file)" ] && [ ! -e "$(_cr_active_file)" ] || return 75
    id=$(_cr_uuid) || return 70; now=$(_cr_now); owner=$(_cr_owner_json); _cr_owner_schema <<<"$owner" || return 69
    if [ -n "${PIM_CAMERA_OWNER_INVOCATION:-}" ]; then _cr_owner_matches_exported_context "$owner" || return 69; fi
    request=$(jq -cn --arg id "$id" --arg type "$type" --arg source "$source" --arg reason "$reason" --arg source_path "$source_path" --arg source_mtime "$source_mtime" --argjson now "$now" --argjson owner "$owner" '{id:$id,type:$type,source:$source,reason:$reason,status:"PENDING",created_at:$now,owner:$owner} + (if $source_path=="" then {} else {source_path:$source_path} end) + (if $source_mtime=="" then {} else {source_mtime:($source_mtime|tonumber)} end)') || return 70
    _cr_mutation_guard "$request" pending ACTIVE DEGRADED || return 69; _cr_atomic_write "$(_cr_pending_file)" "$request" || return 70; printf '%s\n' "$id"
}
cam_request_submit() {
    if [ -e "$(_cr_pending_file)" ] || [ -e "$(_cr_active_file)" ]; then
        _cr_owner_lifecycle_in ACTIVE DEGRADED RECOVERING || return $?
        return 75
    fi
    _cr_owner_lifecycle_in ACTIVE DEGRADED || return $?
    _cr_lock_call _cr_request_new "$@"
}
_cr_history_request() {
    local id=$1 request=$2 history updated
    history=$(cat "$(_cr_history_file "$id")" 2>/dev/null) || return 1
    updated=$(jq -c --argjson request "$request" '.request=$request' <<<"$history") || return 1
    _cr_atomic_write "$(_cr_history_file "$id")" "$updated"
}
_cr_claim_locked() {
    local pending id history
    _cr_owner_lifecycle_in ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
    [ -f "$(_cr_pending_file)" ] || return 69; [ ! -e "$(_cr_active_file)" ] || return 75
    pending=$(cat "$(_cr_pending_file)") || return 70; jq -e '.id and .type and .source and .reason and .owner' >/dev/null <<<"$pending" || return 70
    _cr_record_owner_matches "$pending" || return 69; id=$(jq -r .id <<<"$pending")
    history=$(jq -cn --argjson request "$pending" '{request:$request,actions:[]}') || return 70
    _cr_mutation_guard "$pending" claim_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_history_file "$id")" "$history" || return 70
    _cr_mutation_guard "$pending" claim_active ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_move "$(_cr_pending_file)" "$(_cr_active_file)" || return 70
}
cam_request_claim() { _cr_lock_call _cr_claim_locked; }
_cr_transition_allowed() { case "$1:$2" in PENDING:QUIESCING|QUIESCING:RUNNING|RUNNING:VERIFYING|VERIFYING:SUCCEEDED|VERIFYING:FAILED|RUNNING:FAILED|QUIESCING:FAILED) return 0;; esac; return 1; }
_cr_transition_locked() {
    local next=$1 active current updated id
    _cr_owner_lifecycle_in ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69; _cr_record_owner_matches "$active" || return 69
    current=$(jq -r .status <<<"$active"); _cr_transition_allowed "$current" "$next" || return 64
    updated=$(jq -c --arg next "$next" --argjson now "$(_cr_now)" '.status=$next | .updated_at=$now' <<<"$active") || return 70; id=$(jq -r .id <<<"$updated")
    _cr_mutation_guard "$updated" active ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_active_file)" "$updated" || return 70
    _cr_mutation_guard "$updated" transition_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_history_request "$id" "$updated" || return 70
}
cam_request_transition() { [ $# -eq 1 ] || return 64; _cr_lock_call _cr_transition_locked "$1"; }

_cr_state_template() { jq -cn '{actions:{gstapp_restart:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null},module_reload:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null},camera_hard_reset:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null},reboot_fallback:{attempted:0,succeeded:0,failed:0,consecutive_failures:0,last_request_id:null,last_started_at:null,last_finished_at:null,last_status:null,last_rc:null}}}'; }
_cr_state_valid() {
    jq -e 'def action: type=="object" and (keys|sort)==["attempted","consecutive_failures","failed","last_finished_at","last_rc","last_request_id","last_started_at","last_status","succeeded"] and (.attempted|type=="number" and floor==. and .>=0) and (.succeeded|type=="number" and floor==. and .>=0) and (.failed|type=="number" and floor==. and .>=0) and (.consecutive_failures|type=="number" and floor==. and .>=0) and (.last_request_id==null or (.last_request_id|type=="string")) and (.last_started_at==null or (.last_started_at|type=="number")) and (.last_finished_at==null or (.last_finished_at|type=="number")) and (.last_status==null or .last_status=="RUNNING" or .last_status=="SUCCEEDED" or .last_status=="FAILED") and (.last_rc==null or (.last_rc|type=="number" and floor==. and .>=0)); type=="object" and keys==["actions"] and (.actions|type=="object") and (.actions|keys|sort)==["camera_hard_reset","gstapp_restart","module_reload","reboot_fallback"] and all(.actions[];action)' >/dev/null
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
_cr_counter_finish_history_action() {
    jq -ce --arg action "$2" --arg id "$3" '
      if type=="object" and (.request|type=="object") and
         (.actions|type=="array") and all(.actions[];type=="object")
      then
        [.actions[] | select(.action==$action and .request_id==$id)] as $matches |
        if ($matches|length)==1 then $matches[0] else empty end
      else empty end
    ' <<<"$1"
}
_cr_counter_finish_history_action_valid() {
    jq -e --arg action "$2" --arg id "$3" '
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
    ' >/dev/null <<<"$1"
}
_cr_counter_finish_state_action_valid() {
    jq -e --arg action "$2" --arg id "$3" '
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
    ' >/dev/null <<<"$1"
}
_cr_counter_finish_pair_valid() {
    local history=$1 state=$2 action=$3 id=$4 history_action
    _cr_state_valid <<<"$state" || return 1
    history_action=$(_cr_counter_finish_history_action "$history" "$action" "$id" 2>/dev/null) || return 1
    _cr_counter_finish_history_action_valid "$history_action" "$action" "$id" || return 1
    _cr_counter_finish_state_action_valid "$state" "$action" "$id" || return 1
    jq -ne --argjson history_action "$history_action" --argjson state "$state" --arg action "$action" '
      $state.actions[$action] as $a |
      ($history_action.status=="SUCCEEDED" or $history_action.status=="FAILED") and
      $a.last_status==$history_action.status and $a.last_rc==$history_action.rc and
      $a.last_started_at==$history_action.started_at and
      $a.last_finished_at==$history_action.finished_at
    ' >/dev/null
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
_cr_counter_begin_state_mode() {
    local state=$1 action=$2 id=$3 prior_id prior_status
    prior_id=$(jq -r --arg action "$action" '.actions[$action].last_request_id // ""' <<<"$state") || return 1
    if [ -z "$prior_id" ]; then
        jq -e --arg action "$action" '
          .actions[$action] == {
            attempted:0,succeeded:0,failed:0,consecutive_failures:0,
            last_request_id:null,last_started_at:null,last_finished_at:null,
            last_status:null,last_rc:null
          }
        ' >/dev/null <<<"$state" || return 1
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
_cr_counter_begin_locked() {
    local action=$1 id=$2 active state history history_request history_action history_next state_next
    local history_count history_phase state_phase state_mode settle=false now
    _cr_public_action "$action" || return 64; _cr_owner_lifecycle_in ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69; _cr_record_owner_matches "$active" || return 69
    [ "$(jq -r .status <<<"$active")" = RUNNING ] && [ "$(jq -r .id <<<"$active")" = "$id" ] || return 64
    _cr_mutation_guard "$active" counter_init ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_state_init || return 70; state=$(cat "$(_cr_state_file)") || return 70; _cr_state_valid <<<"$state" || return 70
    history=$(cat "$(_cr_history_file "$id")" 2>/dev/null) || return 70
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
            now=$(_cr_now) || return 70
            history_next=$(jq -c --arg action "$action" --arg id "$id" --argjson now "$now" '.actions += [{action:$action,request_id:$id,status:"RUNNING",started_at:$now}]' <<<"$history") || return 70
            state_next=$(jq -c --arg action "$action" --arg id "$id" --argjson now "$now" --argjson settle "$settle" 'if $settle then .actions[$action].failed+=1 | .actions[$action].consecutive_failures+=1 else . end | .actions[$action].attempted+=1 | .actions[$action].last_request_id=$id | .actions[$action].last_started_at=$now | .actions[$action].last_finished_at=null | .actions[$action].last_status="RUNNING" | .actions[$action].last_rc=null' <<<"$state") || return 70
            _cr_counter_begin_pair_valid "$history_next" "$state_next" "$active" "$action" "$id" || return 70
            _cr_mutation_guard "$active" counter_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_history_file "$id")" "$history_next" || return 70
            _cr_test_failpoint counter_begin_after_history || return 70
            _cr_mutation_guard "$active" counter_state ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_state_file)" "$state_next" || return 70;;
        RUNNING:ABSENT)
            now=$(jq -r '.started_at | select(type=="number" and floor==. and .>0)' <<<"$history_action") || return 70
            [[ $now =~ ^[0-9]+$ ]] || return 70
            state_next=$(jq -c --arg action "$action" --arg id "$id" --argjson now "$now" --argjson settle "$settle" 'if $settle then .actions[$action].failed+=1 | .actions[$action].consecutive_failures+=1 else . end | .actions[$action].attempted+=1 | .actions[$action].last_request_id=$id | .actions[$action].last_started_at=$now | .actions[$action].last_finished_at=null | .actions[$action].last_status="RUNNING" | .actions[$action].last_rc=null' <<<"$state") || return 70
            _cr_counter_begin_pair_valid "$history" "$state_next" "$active" "$action" "$id" || return 70
            _cr_mutation_guard "$active" counter_state ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_state_file)" "$state_next" || return 70;;
        ABSENT:RUNNING)
            [ "$state_mode" = CURRENT ] || return 70
            now=$(jq -r --arg action "$action" '.actions[$action].last_started_at | select(type=="number" and floor==. and .>0)' <<<"$state") || return 70
            [[ $now =~ ^[0-9]+$ ]] || return 70
            history_next=$(jq -c --arg action "$action" --arg id "$id" --argjson now "$now" '.actions += [{action:$action,request_id:$id,status:"RUNNING",started_at:$now}]' <<<"$history") || return 70
            _cr_counter_begin_pair_valid "$history_next" "$state" "$active" "$action" "$id" || return 70
            _cr_mutation_guard "$active" counter_history ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_atomic_write "$(_cr_history_file "$id")" "$history_next" || return 70;;
        *) return 64;;
    esac
}
cam_action_counter_begin() { [ $# -eq 2 ] || return 64; _cr_lock_call _cr_counter_begin_locked "$@"; }
_cr_counter_finish_locked() {
    local action=$1 id=$2 status=$3 rc=$4 active state history history_request history_action history_next state_next
    local history_phase state_phase history_started state_started now phase
    _cr_public_action "$action" || return 64; _cr_terminal_valid "$status" "$rc" || return 64
    _cr_owner_lifecycle_in ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69; _cr_record_owner_matches "$active" || return 69
    [ "$(jq -r .id <<<"$active")" = "$id" ] || return 64
    case "$(jq -r .status <<<"$active")" in RUNNING|VERIFYING) ;; *) return 64;; esac
    _cr_mutation_guard "$active" counter_init ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69; _cr_state_init || return 70; state=$(cat "$(_cr_state_file)") || return 70; _cr_state_valid <<<"$state" || return 70; history=$(cat "$(_cr_history_file "$id")" 2>/dev/null) || return 70
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
        RUNNING:RUNNING) now=$(_cr_now) || return 70 ;;
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
            history_next=$(jq -c --arg action "$action" --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson now "$now" '.actions |= map(if .action==$action and .request_id==$id and .status=="RUNNING" then .status=$status | .rc=$rc | .finished_at=$now else . end)' <<<"$history") || return 70
            state_next=$(jq -c --arg action "$action" --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson now "$now" '.actions[$action].last_request_id=$id | .actions[$action].last_finished_at=$now | .actions[$action].last_status=$status | .actions[$action].last_rc=$rc | if $status=="SUCCEEDED" then .actions[$action].succeeded+=1 | .actions[$action].consecutive_failures=0 else .actions[$action].failed+=1 | .actions[$action].consecutive_failures+=1 end' <<<"$state") || return 70
            ;;
        RUNNING:TERMINAL)
            history_next=$(jq -c --arg action "$action" --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson now "$now" '.actions |= map(if .action==$action and .request_id==$id and .status=="RUNNING" then .status=$status | .rc=$rc | .finished_at=$now else . end)' <<<"$history") || return 70
            state_next=$state
            ;;
        SUCCEEDED:RUNNING|FAILED:RUNNING)
            history_next=$history
            state_next=$(jq -c --arg action "$action" --arg id "$id" --arg status "$status" --argjson rc "$rc" --argjson now "$now" '.actions[$action].last_request_id=$id | .actions[$action].last_finished_at=$now | .actions[$action].last_status=$status | .actions[$action].last_rc=$rc | if $status=="SUCCEEDED" then .actions[$action].succeeded+=1 | .actions[$action].consecutive_failures=0 else .actions[$action].failed+=1 | .actions[$action].consecutive_failures+=1 end' <<<"$state") || return 70
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
_cr_finish_locked() {
    local status=$1 rc=$2 active id result terminal history history_request history_next state
    local result_path history_path write_result=1 write_history=1 now public_count terminal_req_valid
    _cr_terminal_valid "$status" "$rc" || return 64; _cr_owner_lifecycle_in ACTIVE DEGRADED APPLYING_CONFIG RECOVERING || return 69
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69; _cr_record_owner_matches "$active" || return 69; id=$(jq -r .id <<<"$active")
    result_path=$(_cr_result_file "$id"); history_path=$(_cr_history_file "$id")
    history=$(cat "$history_path" 2>/dev/null) || return 70
    jq -e 'type=="object" and (.request|type=="object") and (.actions|type=="array") and all(.actions[];type=="object")' >/dev/null <<<"$history" || return 70
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
        now=$(_cr_now) || return 70
        terminal=$(jq -c --arg status "$status" --argjson rc "$rc" --argjson now "$now" '.status=$status | .rc=$rc | .finished_at=$now' <<<"$active") || return 70
        result=$(_cr_result_from_terminal "$terminal") || return 70
    fi
    if [ "$terminal_req_valid" -eq 1 ]; then
        _cr_terminal_request_result_equal "$history_request" "$result" || return 70
        history_next=$history
        write_history=0
    else
        history_next=$(jq -c --argjson terminal "$terminal" '.request=$terminal' <<<"$history") || return 70
    fi
    _cr_terminal_request_valid "$terminal" || return 70
    _cr_terminal_result_valid "$result" "$active" || return 70
    _cr_terminal_request_result_equal "$terminal" "$result" || return 70
    public_count=$(jq '[.actions[] | select(
      .action=="gstapp_restart" or .action=="module_reload" or
      .action=="camera_hard_reset" or .action=="reboot_fallback")]|length' <<<"$history_next") || return 70
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
    jq -cn --argjson owner "$owner" --argjson pending "$pending" --argjson active "$active" --argjson state "$state" '{owner:$owner,pending:$pending,active:$active,state:$state}'
}
