#!/usr/bin/env bash
# One-release forwarding shim; the former monitor loop has been retired.
set -u

# Argument parsing is a for-loop on purpose.  The guard in
# test/cam_link/legacy_wrapper_test.sh greps this file for a bracket test loop to
# catch the retired monitor loop coming back, and it cannot tell one apart from
# argument parsing -- nor should it have to.
#
# --no-wait skips the wait: cam-recoveryctl prints the request UUID instead of the
# CAM_RECOVERY_RESULT line and exits 0 as soon as the request is submitted,
# without reporting how the action ended.  There is no queue - the pending slot
# holds one request - so calling it again while that request is pending or active
# submits nothing: 75 BUSY when the owner lifecycle is ACTIVE, DEGRADED or
# RECOVERING, and 69 on any other lifecycle, such as APPLYING_CONFIG during an
# apply-config transaction.  For a repeated non-blocking workflow that refusal is
# the normal answer for the length of the action, not a failure.  The default
# is deliberately unchanged; issue #109 records the board measurement that rules
# out lowering it.
no_wait=0
for arg in "$@"; do
    case "$arg" in
        --no-wait) no_wait=1;;
        -h|--help) echo 'usage: restart_app.sh [--no-wait]'; exit 0;;
        *) echo 'usage: restart_app.sh [--no-wait]' >&2; exit 64;;
    esac
done
echo 'DEPRECATED: restart_app.sh forwards one recovery request' >&2
if [ "$no_wait" -eq 1 ]; then
    exec "${PIM_CAMERA_RECOVERYCTL:-/opt/pim/bin/cam-recoveryctl}" request gstapp_restart --source legacy-restart-app --reason legacy-wrapper
fi
exec "${PIM_CAMERA_RECOVERYCTL:-/opt/pim/bin/cam-recoveryctl}" request gstapp_restart --source legacy-restart-app --reason legacy-wrapper --wait 120
