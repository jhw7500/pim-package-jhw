#!/usr/bin/env bash
# Deprecated compatibility boundary. Recovery side effects belong to cam_recovery_actions.sh.
set -u

while [ $# -gt 0 ]; do
    case "$1" in -q|--quiet) shift;; -h|--help) echo 'usage: kill_test.sh [-q]'; exit 0;; *) echo "unknown option: $1" >&2; exit 64;; esac
done
echo 'DEPRECATED: kill_test.sh forwards one recovery request' >&2
exec "${PIM_CAMERA_RECOVERYCTL:-/opt/pim/bin/cam-recoveryctl}" request gstapp_restart --source legacy-kill-test --reason legacy-wrapper --wait 120
