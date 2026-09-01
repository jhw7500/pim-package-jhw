#!/usr/bin/env bash
# The only library permitted to perform camera recovery side effects.

PIM_LIB="${PIM_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PIM_BIN="${PIM_BIN:-$(cd "$PIM_LIB/../bin" && pwd)}"
PIM_CAMERA_RUNTIME_VALIDATOR="${PIM_CAMERA_RUNTIME_VALIDATOR:-$PIM_BIN/camera_runtime_config.py}"
PIM_CAMERA_SYSFS_ROOT="${PIM_CAMERA_SYSFS_ROOT:-/sys}"
PIM_CAMERA_DEVICE_ROOT="${PIM_CAMERA_DEVICE_ROOT:-/dev}"
PIM_CAMERA_START_CAM="${PIM_CAMERA_START_CAM:-$PIM_BIN/start_cam.sh}"

if ! declare -F cam_owner_assert >/dev/null 2>&1; then
    source "$PIM_LIB/cam_recovery.sh"
fi

cam_validate_runtime() {
    [ $# -eq 1 ] || return 64
    [ "$1" = "$PIM_CAMERA_RUNTIME_JSON" ] || return 64
    python3 "$PIM_CAMERA_RUNTIME_VALIDATOR" validate --file "$1" >/dev/null 2>&1 || return 64
}

cam_executor_assert_context() {
    local owner active key expected actual
    [ "${PIM_CAMERA_EXECUTOR:-}" = 1 ] || return 69
    [ -n "${PIM_CAMERA_REQUEST_ID:-}" ] || return 69
    owner=$(_cr_owner_json) || return 69
    cam_owner_assert "${PIM_CAMERA_OWNER_INVOCATION:-}" "${PIM_CAMERA_OWNER_TOKEN:-}" || return 69
    for key in boot_id invocation_id pid proc_start_time token created_at; do
        expected=$(jq -r --arg key "$key" '.[$key]' <<<"$owner") || return 69
        case "$key" in
            boot_id) actual=${PIM_CAMERA_OWNER_BOOT_ID:-} ;;
            invocation_id) actual=${PIM_CAMERA_OWNER_INVOCATION:-} ;;
            pid) actual=${PIM_CAMERA_OWNER_PID:-} ;;
            proc_start_time) actual=${PIM_CAMERA_OWNER_PROC_START_TIME:-} ;;
            token) actual=${PIM_CAMERA_OWNER_TOKEN:-} ;;
            created_at) actual=${PIM_CAMERA_OWNER_CREATED_AT:-} ;;
        esac
        [ "$expected" = "$actual" ] || return 69
    done
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    [ "$(jq -r .id <<<"$active")" = "$PIM_CAMERA_REQUEST_ID" ] || return 69
    _cr_record_owner_ready "$active" RECOVERING APPLYING_CONFIG || return 69
}

cam_side_effect_guard() {
    cam_executor_assert_context || return 69
    cam_validate_runtime "$1"
}

cam_effect() {
    local runtime=$1
    shift
    cam_side_effect_guard "$runtime" || return $?
    "$@"
}

cam_runtime_app() {
    local runtime=$1 app capture
    app=$(jq -r '.VHL_CAM.app // "gstApp"' "$runtime") || return 64
    capture=$(jq -r '.VHL_CAM.capture.enable // false' "$runtime") || return 64
    [ "$capture" = true ] && app=gstApp
    [ "$app" = streamApp ] && app=PIMCAM
    case "$app" in gstApp|PIMCAM) printf '%s\n' "$app";; *) return 64;; esac
}

cam_cleanup_recording_orphans() {
    local runtime=$1 dir canonical vehicle started normalized prefix f
    dir=$(jq -r '.VHL_CAM.tmp_path // empty' "$runtime") || return 64
    vehicle=$(jq -r '.VHL_CAM.vhl_name // empty' "$runtime") || return 64
    started=$(cat "${PIM_CAMERA_SESSION_TIME_FILE:-/tmp/start_video_time_chk}" 2>/dev/null | tr -d '\n')
    [[ $dir = /* && $dir != / && $dir != *'..'* && $vehicle =~ ^[A-Za-z0-9_-]+$ ]] || return 64
    [ -L "$dir" ] && return 64
    canonical=$(readlink -f -- "$dir" 2>/dev/null) || return 64
    [ "$canonical" = "$dir" ] && [ "$canonical" != / ] || return 64
    case "$started" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) normalized=$started ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) normalized=$started ;;
        *) return 0 ;;
    esac
    [ -d "$dir" ] || return 0
    prefix="$vehicle"_$(date -d "$normalized" '+%Y%m%d_%H%M' 2>/dev/null) || return 0
    shopt -s nullglob
    for f in "$dir/$prefix"*.mp4 "$dir/$prefix"*.ts "$dir/$prefix"*.srt "$dir/$prefix"*-vib.bin "$dir/$prefix"*.mp4.part "$dir/$prefix"*.ts.part "$dir/$prefix"*.srt.part; do
        [ -f "$f" ] || continue
        cam_effect "$runtime" rm -f -- "$f" || { shopt -u nullglob; return $?; }
    done
    shopt -u nullglob
}

cam_cleanup_shm_overflow() {
    local runtime=$1 shm_dir usage crit_pct f path
    shm_dir=${PIM_CAMERA_SHM_DIR:-/dev/shm}
    crit_pct=${SHM_CRIT_PCT:-70}
    usage=$(df -P "$shm_dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
    [[ $usage =~ ^[0-9]+$ ]] && [ "$usage" -ge "$crit_pct" ] || return 0
    shopt -s nullglob
    for path in "$shm_dir"/*; do
        [ -f "$path" ] || continue
        f=${path##*/}
        case "$f" in sd_mount_flag|sd_write_disabled) continue;; esac
        cam_effect "$runtime" rm -f "$path" || { shopt -u nullglob; return $?; }
        usage=$(df -P "$shm_dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
        [[ $usage =~ ^[0-9]+$ ]] && [ "$usage" -ge "$crit_pct" ] || break
    done
    shopt -u nullglob
}

cam_bg_checker_path() { printf '%s\n' "${PIM_CAMERA_BG_CHECKER:-$PIM_BIN/BG_Check_for_pim.sh}"; }
cam_bg_checker_records() {
    local bg=$1 root=${PIM_CAMERA_PROCESS_ROOT:-/proc} cmdline stat arg pid start args=()
    [ -e "$root/.inspect_error" ] && return 2
    for cmdline in "${PIM_CAMERA_PROCESS_ROOT:-/proc}"/[0-9]*/cmdline; do
        [ -r "$cmdline" ] || continue
        args=()
        while IFS= read -r -d '' arg; do
            args+=("$arg")
        done < "$cmdline"
        [ "${args[0]:-}" = "$bg" ] && [[ ${args[1]:-} =~ ^[0-9]+$ ]] || continue
        pid=${cmdline%/cmdline}; pid=${pid##*/}
        stat=${cmdline%/cmdline}/stat
        [ -r "$stat" ] || return 2
        start=$(awk '{print $22}' "$stat" 2>/dev/null) || return 2
        [[ $start =~ ^[0-9]+$ ]] || return 2
        printf '%s %s\n' "$pid" "$start"
    done
}
cam_bg_checker_present() {
    local records rc
    records=$(cam_bg_checker_records "$1"); rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    [ -n "$records" ]
}
cam_process_present() {
    local runtime=$1 kind=$2 app bg
    case "$kind" in
        app) app=$(cam_runtime_app "$runtime") || return $?; pgrep -x "$app" >/dev/null 2>&1 ;;
        bg) bg=$(cam_bg_checker_path); cam_bg_checker_present "$bg" ;;
        ord|vcm) pgrep -x "$kind" >/dev/null 2>&1 ;;
        *) return 64 ;;
    esac
}
cam_signal_process() {
    local runtime=$1 signal=$2 kind=$3 app bg
    case "$kind" in
        app) app=$(cam_runtime_app "$runtime") || return $?; cam_effect "$runtime" pkill "$signal" -x "$app" ;;
        bg)
            local records pid start current
            bg=$(cam_bg_checker_path)
            records=$(cam_bg_checker_records "$bg") || return $?
            [ -n "$records" ] || return 1
            while read -r pid start; do
                current=$(awk '{print $22}' "${PIM_CAMERA_PROCESS_ROOT:-/proc}/$pid/stat" 2>/dev/null) || return 2
                [ "$current" = "$start" ] || continue
                cam_effect "$runtime" kill "$signal" "$pid" || return $?
            done <<< "$records"
            ;;
        ord|vcm) cam_effect "$runtime" pkill "$signal" -x "$kind" ;;
        *) return 64 ;;
    esac
}
cam_stop_process() {
    local runtime=$1 kind=$2 timeout=${PIM_CAMERA_QUIESCE_TIMEOUT_SEC:-5} i=0 rc
    [[ $timeout =~ ^[0-9]+$ ]] || timeout=5
    cam_process_present "$runtime" "$kind"; rc=$?
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && return 0; return "$rc"; }
    cam_signal_process "$runtime" -TERM "$kind" || return $?
    while cam_process_present "$runtime" "$kind"; do
        [ "$i" -ge "$timeout" ] && break
        sleep 1; i=$((i + 1))
    done
    cam_process_present "$runtime" "$kind"; rc=$?
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && return 0; return "$rc"; }
    cam_signal_process "$runtime" -KILL "$kind" || return $?
    i=0
    while cam_process_present "$runtime" "$kind"; do
        [ "$i" -ge "$timeout" ] && return 1
        sleep 1; i=$((i + 1))
    done
}
cam_quiesce_gstapp() {
    local runtime=$1
    cam_stop_process "$runtime" app || return $?
    cam_stop_process "$runtime" bg
}

cam_quiesce_consumers() {
    local runtime=$1
    cam_quiesce_gstapp "$runtime" || return $?
    cam_stop_process "$runtime" ord || return $?
    cam_stop_process "$runtime" vcm
}

cam_initial_module_load() {
    local runtime=$1
    cam_validate_runtime "$runtime" || return 64
    cam_effect "$runtime" modprobe max9296 || return $?
    cam_effect "$runtime" modprobe imx8-media-dev || return $?
    [ -e "$PIM_CAMERA_DEVICE_ROOT/video3" ] && [ -e "$PIM_CAMERA_DEVICE_ROOT/video4" ] || return 1
}

cam_start_gstapp() {
    local runtime=$1 delay bg
    delay=$(jq -r '.VHL_CAM.app_delay // 4' "$runtime") || return 64
    bg=$(cam_bg_checker_path) || return $?
    cam_side_effect_guard "$runtime" || return $?
    PIM_CAMERA_EXECUTOR=1 \
    PIM_CAMERA_REQUEST_ID="$PIM_CAMERA_REQUEST_ID" \
    PIM_CAMERA_OWNER_BOOT_ID="$PIM_CAMERA_OWNER_BOOT_ID" \
    PIM_CAMERA_OWNER_INVOCATION="$PIM_CAMERA_OWNER_INVOCATION" \
    PIM_CAMERA_OWNER_PID="$PIM_CAMERA_OWNER_PID" \
    PIM_CAMERA_OWNER_PROC_START_TIME="$PIM_CAMERA_OWNER_PROC_START_TIME" \
    PIM_CAMERA_OWNER_TOKEN="$PIM_CAMERA_OWNER_TOKEN" \
    PIM_CAMERA_OWNER_CREATED_AT="$PIM_CAMERA_OWNER_CREATED_AT" \
    PIM_CAMERA_BG_CHECKER="$bg" \
    "$PIM_CAMERA_START_CAM" "$delay"
}

cam_launch_consumer() {
    local runtime=$1 name=$2 path
    path=$(command -v "$name") || return 127
    (
        cam_side_effect_guard "$runtime" || exit $?
        exec "$path"
    ) &
}
cam_restart_ord() { cam_launch_consumer "$1" ord; }
cam_restart_vcm() { cam_launch_consumer "$1" vcm; }

cam_verify_camera_ready() {
    local runtime=$1
    cam_side_effect_guard "$runtime" || return $?
    [ -e "$PIM_CAMERA_DEVICE_ROOT/video3" ] && [ -e "$PIM_CAMERA_DEVICE_ROOT/video4" ]
}

cam_verify_process_ready() {
    local runtime=$1 consumers=${2:-0}
    cam_side_effect_guard "$runtime" || return $?
    cam_process_present "$runtime" app && cam_process_present "$runtime" bg || return 1
    [ "$consumers" = 0 ] || { cam_process_present "$runtime" ord && cam_process_present "$runtime" vcm; }
}

cam_wait_process_ready() {
    local runtime=$1 consumers=${2:-0} timeout=${PIM_CAMERA_READY_TIMEOUT_SEC:-5} i=0
    while ! cam_verify_process_ready "$runtime" "$consumers"; do
        [ "$i" -ge "$timeout" ] && return 1
        sleep 1
        i=$((i + 1))
    done
}

cam_action_gstapp_restart() {
    local runtime=$1
    cam_quiesce_gstapp "$runtime" || return $?
    cam_cleanup_recording_orphans "$runtime" || return $?
    cam_cleanup_shm_overflow "$runtime" || return $?
    cam_start_gstapp "$runtime" || return $?
    cam_wait_process_ready "$runtime" 0
}

cam_module_loaded() {
    local module=${1//-/_} table matches rc
    table=$(lsmod); rc=$?
    [ "$rc" -eq 0 ] || return 2
    matches=$(awk -v module="$module" '$1 == module {print "loaded"}' <<< "$table"); rc=$?
    [ "$rc" -eq 0 ] || return 2
    [ -n "$matches" ] && return 0
    return 1
}
cam_unload_module() {
    local runtime=$1 module=$2 rc
    cam_module_loaded "$module"; rc=$?
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && return 0; return "$rc"; }
    cam_effect "$runtime" rmmod "$module"
}
cam_module_reload() {
    local runtime=$1
    cam_unload_module "$runtime" imx8-media-dev || return $?
    cam_unload_module "$runtime" max9296 || return $?
    cam_effect "$runtime" modprobe max9296 || return $?
    cam_effect "$runtime" modprobe imx8-media-dev
}

cam_action_module_reload() {
    local runtime=$1
    cam_quiesce_consumers "$runtime" || return $?
    cam_module_reload "$runtime" || return $?
    cam_verify_camera_ready "$runtime" || return $?
    cam_restart_ord "$runtime" || return $?
    cam_restart_vcm "$runtime" || return $?
    cam_start_gstapp "$runtime" || return $?
    cam_wait_process_ready "$runtime" 1
}

cam_sysfs_write() {
    local runtime=$1 op=$2 file=$3 value=$4
    [ -w "$file" ] || return 0
    cam_side_effect_guard "$runtime" || return $?
    [ -z "${PIM_CAMERA_CALL_LOG:-}" ] || printf 'sysfs %s %s %s\n' "$op" "$value" "$file" >> "$PIM_CAMERA_CALL_LOG"
    printf '%s' "$value" > "$file"
}

cam_action_camera_hard_reset() {
    local runtime=$1 root=$PIM_CAMERA_SYSFS_ROOT csi isi cap m2m d
    csi="$root/bus/platform/drivers/mxc-mipi-csi2-sam"; isi="$root/bus/platform/drivers/mxc-isi"
    cap="$root/bus/platform/drivers/isi-capture"; m2m="$root/bus/platform/drivers/isi-m2m"
    cam_quiesce_consumers "$runtime" || return $?
    cam_unload_module "$runtime" imx8-media-dev || return $?
    cam_unload_module "$runtime" max9296 || return $?
    for d in 32e00000.isi:cap_device 32e02000.isi:cap_device; do cam_sysfs_write "$runtime" unbind "$cap/unbind" "$d" || return $?; done
    for d in 32e00000.isi:m2m_device; do cam_sysfs_write "$runtime" unbind "$m2m/unbind" "$d" || return $?; done
    for d in 32e00000.isi 32e02000.isi; do cam_sysfs_write "$runtime" unbind "$isi/unbind" "$d" || return $?; done
    for d in 32e40000.csi 32e50000.csi; do cam_sysfs_write "$runtime" unbind "$csi/unbind" "$d" || return $?; done
    for d in 32e40000.csi 32e50000.csi; do cam_sysfs_write "$runtime" bind "$csi/bind" "$d" || return $?; done
    for d in 32e00000.isi 32e02000.isi; do cam_sysfs_write "$runtime" bind "$isi/bind" "$d" || return $?; done
    for d in 32e00000.isi:cap_device 32e02000.isi:cap_device; do [ -e "$cap/$d" ] || cam_sysfs_write "$runtime" bind "$cap/bind" "$d" || return $?; done
    for d in 32e00000.isi:m2m_device; do [ -e "$m2m/$d" ] || cam_sysfs_write "$runtime" bind "$m2m/bind" "$d" || return $?; done
    cam_effect "$runtime" modprobe max9296 || return $?
    cam_effect "$runtime" modprobe imx8-media-dev || return $?
    cam_verify_camera_ready "$runtime" || return $?
    cam_restart_ord "$runtime" || return $?
    cam_restart_vcm "$runtime" || return $?
    cam_start_gstapp "$runtime" || return $?
    cam_wait_process_ready "$runtime" 1
}

cam_action_reboot_fallback() { local runtime=$1; cam_effect "$runtime" reboot; }

cam_execute_action_step() {
    local action=$1 runtime=$2 rc finish_rc
    cam_executor_assert_context || return 69
    cam_validate_runtime "$runtime" || return 64
    cam_action_counter_begin "$action" "$PIM_CAMERA_REQUEST_ID" || return $?
    case "$action" in
        gstapp_restart) cam_action_gstapp_restart "$runtime"; rc=$? ;;
        module_reload) cam_action_module_reload "$runtime"; rc=$? ;;
        camera_hard_reset) cam_action_camera_hard_reset "$runtime"; rc=$? ;;
        reboot_fallback) cam_action_reboot_fallback "$runtime"; rc=$? ;;
        *) return 64 ;;
    esac
    if [ "$rc" -eq 0 ]; then cam_action_counter_finish "$action" "$PIM_CAMERA_REQUEST_ID" SUCCEEDED 0; finish_rc=$?; else cam_action_counter_finish "$action" "$PIM_CAMERA_REQUEST_ID" FAILED "$rc"; finish_rc=$?; fi
    [ "$finish_rc" -eq 0 ] || return "$finish_rc"
    return "$rc"
}

cam_executor_set_context() {
    local active owner
    active=$(cat "$(_cr_active_file)" 2>/dev/null) || return 69
    owner=$(_cr_owner_json) || return 69
    PIM_CAMERA_EXECUTOR=1
    PIM_CAMERA_REQUEST_ID=$(jq -r .id <<<"$active")
    PIM_CAMERA_OWNER_BOOT_ID=$(jq -r .boot_id <<<"$owner")
    PIM_CAMERA_OWNER_INVOCATION=$(jq -r .invocation_id <<<"$owner")
    PIM_CAMERA_OWNER_PID=$(jq -r .pid <<<"$owner")
    PIM_CAMERA_OWNER_PROC_START_TIME=$(jq -r .proc_start_time <<<"$owner")
    PIM_CAMERA_OWNER_TOKEN=$(jq -r .token <<<"$owner")
    PIM_CAMERA_OWNER_CREATED_AT=$(jq -r .created_at <<<"$owner")
    export PIM_CAMERA_EXECUTOR PIM_CAMERA_REQUEST_ID PIM_CAMERA_OWNER_BOOT_ID PIM_CAMERA_OWNER_INVOCATION PIM_CAMERA_OWNER_PID PIM_CAMERA_OWNER_PROC_START_TIME PIM_CAMERA_OWNER_TOKEN PIM_CAMERA_OWNER_CREATED_AT
}

cam_execute_recovery_request() {
    local runtime=$1 type=$2 source=$3 reason=$4 rc=0
    cam_validate_runtime "$runtime" || return 64
    _cr_request_type "$type" || return 64
    cam_owner_assert || return 69
    cam_request_submit "$type" "$source" "$reason" >/dev/null || return $?
    cam_request_claim || return $?
    cam_owner_set_lifecycle RECOVERING || return $?
    cam_request_transition QUIESCING || return $?
    cam_request_transition RUNNING || return $?
    cam_executor_set_context || return $?
    case "$type" in
        gstapp_restart) cam_execute_action_step gstapp_restart "$runtime"; rc=$? ;;
        module_reload)
            cam_execute_action_step module_reload "$runtime"; rc=$?
            if [ "$rc" -ne 0 ]; then cam_execute_action_step camera_hard_reset "$runtime"; rc=$?; fi
            if [ "$rc" -ne 0 ]; then cam_execute_action_step reboot_fallback "$runtime"; rc=$?; fi
            ;;
        camera_hard_reset)
            cam_execute_action_step camera_hard_reset "$runtime"; rc=$?
            if [ "$rc" -ne 0 ]; then cam_execute_action_step reboot_fallback "$runtime"; rc=$?; fi
            ;;
        reboot_fallback) cam_execute_action_step reboot_fallback "$runtime"; rc=$? ;;
        apply_config) rc=0 ;;
    esac
    if [ "$rc" -eq 0 ]; then
        cam_request_transition VERIFYING || return $?
        cam_request_finish SUCCEEDED 0 || return $?
        cam_owner_set_lifecycle ACTIVE || return $?
        return 0
    fi
    cam_request_transition FAILED || return $?
    cam_request_finish FAILED "$rc" || return $?
    cam_owner_set_lifecycle DEGRADED || return $?
    return "$rc"
}
