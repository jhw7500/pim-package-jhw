#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-legacy-wrapper.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
CALLS="$WORK/calls"
cat > "$WORK/bin/cam-recoveryctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
exit "${RECOVERY_RC:-0}"
EOF
chmod +x "$WORK/bin/cam-recoveryctl"
export CALLS
run() { local script=$1; shift; : > "$CALLS"; set +e; out=$(PIM_CAMERA_RECOVERYCTL="$WORK/bin/cam-recoveryctl" RECOVERY_RC=17 "$ROOT/dist/pim/opt/pim/bin/$script" "$@" 2>&1); rc=$?; set -e; [ "$rc" = 17 ] || { echo "$out" >&2; exit 1; }; printf '%s' "$out" | grep -qi deprecat || { echo "no deprecation warning: $script" >&2; exit 1; }; }

run kill_test.sh -q
[ "$(cat "$CALLS")" = 'request gstapp_restart --source legacy-kill-test --reason legacy-wrapper --wait 120' ] || exit 1
run init_cam.sh -q
[ "$(cat "$CALLS")" = 'request module_reload --source legacy-init-cam --reason legacy-wrapper --wait 300' ] || exit 1
run cam_hard_reset.sh -s -S -q
[ "$(cat "$CALLS")" = 'request camera_hard_reset --source legacy-cam-hard-reset --reason legacy-wrapper --wait 300' ] || exit 1
run restart_app.sh
[ "$(cat "$CALLS")" = 'request gstapp_restart --source legacy-restart-app --reason legacy-wrapper --wait 120' ] || exit 1
! grep -q 'while[[:space:]]*\[' "$ROOT/dist/pim/opt/pim/bin/restart_app.sh" || { echo "restart loop remains" >&2; exit 1; }
 : > "$CALLS"
set +e
PIM_CAMERA_RECOVERYCTL="$WORK/bin/cam-recoveryctl" RECOVERY_RC=17 "$ROOT/dist/pim/opt/pim/bin/start_cam.sh" 2>/dev/null
rc=$?
set -e
[ "$rc" = 17 ] || { echo "start_cam external rc=$rc" >&2; exit 1; }
[ "$(cat "$CALLS")" = 'request gstapp_restart --source legacy-start-cam --reason legacy-wrapper --wait 120' ] || exit 1
PIM_CAMERA_EXECUTOR=1 "$ROOT/dist/pim/opt/pim/bin/start_cam.sh" >/dev/null 2>&1 && { echo 'start_cam accepted missing owner context' >&2; exit 1; }
! grep -q 'restart_app\.sh\|/root/shared_v\|edgeconf_' "$ROOT/dist/pim/opt/pim/bin/start_cam.sh" || { echo 'start_cam retained legacy launcher/source discovery' >&2; exit 1; }
echo "legacy wrappers: PASS"
