#!/bin/bash
tag=$(basename "$0")
KEY="CPU"

TEST_MODE=0
MAX_ITERATIONS=0
if [[ "${PIM_CAMERA_TEST_MODE:-0}" == "1" ]]; then
    TEST_MODE=1
    PIM_CAMERA_RUNTIME_JSON="${PIM_CAMERA_RUNTIME_JSON:?PIM_CAMERA_RUNTIME_JSON is required in test mode}"
    MAX_ITERATIONS="${PIM_CPU_LIMIT_MAX_ITERATIONS:?PIM_CPU_LIMIT_MAX_ITERATIONS is required in test mode}"
else
    PIM_CAMERA_RUNTIME_JSON="/run/pim-camera/config/pim_runtime.json"
fi

config_invalid() {
    logger -p local0.err "[$KEY][$tag:$LINENO] CONFIG_INVALID: $PIM_CAMERA_RUNTIME_JSON" 2>/dev/null
    exit 64
}

command -v jq >/dev/null 2>&1 || config_invalid
jq -e '
    type == "object" and
    (.VHL_CAM | type == "object") and
    (.ORD | type == "object") and
    (.VCM | type == "object") and
    (.VHL_CAM.app | type == "string" and length > 0)
' "$PIM_CAMERA_RUNTIME_JSON" >/dev/null 2>&1 || config_invalid

app=$(jq -r '.VHL_CAM.app' "$PIM_CAMERA_RUNTIME_JSON")
logger -p local0.notice "[$KEY][$tag:$LINENO] runtime json : $PIM_CAMERA_RUNTIME_JSON"

limit=$1
service=$app

logger -p local0.notice "[$KEY][$tag:$LINENO] service:$app, limit = $limit"
iteration=0
while true; do
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        logger -p local0.notice "[$KEY][$tag:$LINENO] $service($pid) cpu limit $limit%"
        cpulimit -p "$pid" -l "$limit"
    done < <(pgrep -f -- "$service")

    iteration=$((iteration + 1))
    if [[ "$TEST_MODE" == "1" && "$iteration" -ge "$MAX_ITERATIONS" ]]; then
        break
    fi
    sleep 10
done

logger -p local0.notice "[$KEY][$tag:$LINENO] exit"
