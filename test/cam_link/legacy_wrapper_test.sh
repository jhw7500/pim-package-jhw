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
start_out=$(PIM_CAMERA_RECOVERYCTL="$WORK/bin/cam-recoveryctl" RECOVERY_RC=17 "$ROOT/dist/pim/opt/pim/bin/start_cam.sh" 2>&1)
rc=$?
set -e
[ "$rc" = 17 ] || { echo "start_cam external rc=$rc" >&2; exit 1; }
[ "$(printf '%s' "$start_out" | grep -ci deprecat)" -ge 1 ] || { echo 'external start_cam has no deprecation warning' >&2; exit 1; }
[ "$(cat "$CALLS")" = 'request gstapp_restart --source legacy-start-cam --reason legacy-wrapper --wait 120' ] || exit 1

# --no-wait drops the --wait argument entirely, so cam-recoveryctl returns as soon as
# the request is queued.  These assert the absence of --wait, which is what makes them
# fail against a wrapper that has not been changed: there --no-wait is an unknown
# option and the script exits 64 before reaching the stub at all.
run kill_test.sh --no-wait
[ "$(cat "$CALLS")" = 'request gstapp_restart --source legacy-kill-test --reason legacy-wrapper' ] || exit 1
run kill_test.sh -q --no-wait
[ "$(cat "$CALLS")" = 'request gstapp_restart --source legacy-kill-test --reason legacy-wrapper' ] || exit 1
run init_cam.sh --no-wait
[ "$(cat "$CALLS")" = 'request module_reload --source legacy-init-cam --reason legacy-wrapper' ] || exit 1
run cam_hard_reset.sh -s -S --no-wait
[ "$(cat "$CALLS")" = 'request camera_hard_reset --source legacy-cam-hard-reset --reason legacy-wrapper' ] || exit 1
run restart_app.sh --no-wait
[ "$(cat "$CALLS")" = 'request gstapp_restart --source legacy-restart-app --reason legacy-wrapper' ] || exit 1
: > "$CALLS"
set +e
nw_out=$(PIM_CAMERA_RECOVERYCTL="$WORK/bin/cam-recoveryctl" RECOVERY_RC=17 "$ROOT/dist/pim/opt/pim/bin/start_cam.sh" --no-wait 2>&1)
rc=$?
set -e
[ "$rc" = 17 ] || { echo "start_cam --no-wait rc=$rc" >&2; exit 1; }
printf '%s' "$nw_out" | grep -qi deprecat || { echo 'start_cam --no-wait lost the deprecation warning' >&2; exit 1; }
[ "$(cat "$CALLS")" = 'request gstapp_restart --source legacy-start-cam --reason legacy-wrapper' ] || exit 1
# --no-wait must not be counted as the positional delay this path accepts and discards.
: > "$CALLS"
set +e
PIM_CAMERA_RECOVERYCTL="$WORK/bin/cam-recoveryctl" RECOVERY_RC=17 "$ROOT/dist/pim/opt/pim/bin/start_cam.sh" 5 --no-wait >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 17 ] || { echo "start_cam '5 --no-wait' rc=$rc" >&2; exit 1; }
[ "$(cat "$CALLS")" = 'request gstapp_restart --source legacy-start-cam --reason legacy-wrapper' ] || exit 1
set +e
PIM_CAMERA_RECOVERYCTL="$WORK/bin/cam-recoveryctl" RECOVERY_RC=17 "$ROOT/dist/pim/opt/pim/bin/start_cam.sh" 5 6 --no-wait >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 64 ] || { echo "start_cam should reject two positionals, rc=$rc" >&2; exit 1; }

# A near miss must not be absorbed and silently take the blocking path: that hands
# back the very wait --no-wait exists to skip.  start_cam.sh is the one with a
# positional argument, so it is the one that could swallow a flag as the delay.
for wrapper in kill_test.sh init_cam.sh cam_hard_reset.sh restart_app.sh start_cam.sh; do
    for typo in --nowait -no-wait --no_wait; do
        : > "$CALLS"
        set +e
        PIM_CAMERA_RECOVERYCTL="$WORK/bin/cam-recoveryctl" RECOVERY_RC=17 \
            "$ROOT/dist/pim/opt/pim/bin/$wrapper" "$typo" >/dev/null 2>&1
        rc=$?
        set -e
        [ "$rc" = 64 ] || { echo "$wrapper accepted $typo with rc=$rc instead of 64" >&2; exit 1; }
        [ ! -s "$CALLS" ] || { echo "$wrapper forwarded a request for $typo: $(cat "$CALLS")" >&2; exit 1; }
    done
done
# start_cam.sh still takes a numeric delay, and --help stays an exit-0 path.
: > "$CALLS"
set +e
PIM_CAMERA_RECOVERYCTL="$WORK/bin/cam-recoveryctl" RECOVERY_RC=17 "$ROOT/dist/pim/opt/pim/bin/start_cam.sh" 5 >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 17 ] || { echo "start_cam rejected a numeric delay, rc=$rc" >&2; exit 1; }
[ "$(cat "$CALLS")" = 'request gstapp_restart --source legacy-start-cam --reason legacy-wrapper --wait 120' ] || exit 1
set +e
help_out=$("$ROOT/dist/pim/opt/pim/bin/start_cam.sh" --help 2>&1); rc=$?
set -e
[ "$rc" = 0 ] || { echo "start_cam --help rc=$rc" >&2; exit 1; }
printf '%s' "$help_out" | grep -q -- '--no-wait' || { echo 'start_cam --help does not mention --no-wait' >&2; exit 1; }
PIM_CAMERA_EXECUTOR=1 "$ROOT/dist/pim/opt/pim/bin/start_cam.sh" >/dev/null 2>&1 && { echo 'start_cam accepted missing owner context' >&2; exit 1; }
! grep -q 'restart_app\.sh\|/root/shared_v\|edgeconf_' "$ROOT/dist/pim/opt/pim/bin/start_cam.sh" || { echo 'start_cam retained legacy launcher/source discovery' >&2; exit 1; }
echo "legacy wrappers: PASS"
