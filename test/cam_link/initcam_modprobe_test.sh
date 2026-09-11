#!/usr/bin/env bash
# Module ordering now belongs to the recovery action library, not init_cam.sh.
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
CALLS="$WORK/calls"
trap 'rm -rf "$WORK"' EXIT
source "$PIM_LIB/cam_recovery_actions.sh"

run() {
    : > "$CALLS"
    (
        cam_effect() {
            local runtime=$1; shift
            printf '%s\n' "$*" >> "$CALLS"
            [ "${1:-}" = modprobe ] && [ "${2:-}" = "${FAILMOD:-}" ] && return 1
            return 0
        }
        cam_module_loaded() { return 0; }
        FAILMOD=$2 cam_module_reload /runtime.json
    )
    rc=$?
    t_eq "$1" "$(paste -sd, "$CALLS")/$rc" "$3/$4"
}

echo '=== module reload ordering ==='
run 'max9296 failure skips dependent media load' max9296 'rmmod imx8-media-dev,rmmod max9296,modprobe max9296' 1
run 'media failure follows deserializer load' imx8-media-dev 'rmmod imx8-media-dev,rmmod max9296,modprobe max9296,modprobe imx8-media-dev' 1
run 'successful reload orders unload/load dependencies' none 'rmmod imx8-media-dev,rmmod max9296,modprobe max9296,modprobe imx8-media-dev' 0
t_summary 'recovery action module guard'
