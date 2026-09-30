#!/usr/bin/env bash
# Deprecated compatibility boundary. Recovery side effects belong to cam_recovery_actions.sh.
set -u

# This forwards gstapp_stop, which stops gstApp and BG_Check and confirms they are
# gone: SIGTERM, poll for up to PIM_CAMERA_QUIESCE_TIMEOUT_SEC, then SIGKILL, then
# poll again and verify absence (cam_stop_process in cam_recovery_actions.sh).  It
# does not restart the app.  cam-operate does that: cam_monitor_control_iteration
# finishes this request, sets the owner back to its entry lifecycle, then re-reads
# that lifecycle and calls cam_liveness_tick in the same iteration, which sees gstApp
# absent and submits gstapp_restart itself, fire-and-forget.
#
# So rc 0 means "gstApp and BG_Check were absent at the moment of the check", not
# "running again", and there is no window in which the app is reliably down - the
# relaunch is submitted in the very iteration that reported this stop SUCCEEDED.  To
# keep gstApp down, use cam_operate_stop.sh, which takes the owner to STOPPING.  The
# restart is also not unconditional: cam_liveness_gstapp_gate requires an enabled
# channel, no disconnect flag, a video node and a responding subdev, and with the gate
# closed nothing is submitted until one of chk_cam_operate.sh's own ladders fires.
# That is the accepted consequence of keeping this wrapper out of the restart (#113).
#
# The wait stays 120s.  An earlier draft lowered it to 30s on the strength of the
# action's own quiesce windows alone, which is wrong: the same budget also has to
# cover the request bookkeeping inside the wait window - one gstapp_stop claim plus
# execute spends about a hundred jq spawns, and this tree records a jq spawn at ~307ms
# on the board three times over (cam_recovery.sh:186, :253, :1056).  Lowering the
# default needs a board measurement of the whole submit-to-terminal-result latency,
# and issue #109 records the measurement that rules out lowering it today.  A wait
# timeout returns 124 without cancelling the running action, so too small a value
# turns succeeding stops into indistinguishable failures.
#
# --no-wait skips the wait: cam-recoveryctl prints the request UUID instead of the
# CAM_RECOVERY_RESULT line and exits 0 as soon as the request is submitted.  There
# is no queue - the pending slot holds one request - so calling it again while that
# request is pending or active submits nothing: 75 BUSY when the owner lifecycle is
# ACTIVE, DEGRADED or RECOVERING, and 69 on any other lifecycle, such as
# APPLYING_CONFIG during an apply-config transaction.
#
# Two production callers, both blocking with no argument.  cam_disable.sh touches
# /tmp/init_cam_flag first, which makes _cl_handle_operation_flags skip the liveness
# tick, so its rmmod is not racing a relaunch and rc 0 there does mean the device is
# free.  ord's CMD_TIMESETTING_BLACKBOX handler (ord/tcpServer.cpp, CAM_RESET_FILE)
# has no such flag and breaks out of the handler on a nonzero status: on that path rc 0
# now means the stop completed, not that the camera came back, and the RTC-set response
# is sent on that basis.  docs/camera-health/cam-recovery-operations.md records both
# callers; the rtc_reset row in the ord config document is a follow-up, because this
# repository's tribunal restricts a fix to the paths the reviewed round already covered.
no_wait=0
while [ $# -gt 0 ]; do
    case "$1" in -q|--quiet) shift;; --no-wait) no_wait=1; shift;; -h|--help) echo 'usage: kill_test.sh [-q] [--no-wait]'; exit 0;; *) echo "unknown option: $1" >&2; exit 64;; esac
done
echo 'DEPRECATED: kill_test.sh stops gstApp; cam-operate restarts it' >&2
if [ "$no_wait" -eq 1 ]; then
    exec "${PIM_CAMERA_RECOVERYCTL:-/opt/pim/bin/cam-recoveryctl}" request gstapp_stop --source legacy-kill-test --reason legacy-wrapper
fi
exec "${PIM_CAMERA_RECOVERYCTL:-/opt/pim/bin/cam-recoveryctl}" request gstapp_stop --source legacy-kill-test --reason legacy-wrapper --wait 120
