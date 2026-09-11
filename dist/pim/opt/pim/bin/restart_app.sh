#!/usr/bin/env bash
# One-release forwarding shim; the former monitor loop has been retired.
set -u

[ $# -eq 0 ] || { echo 'usage: restart_app.sh' >&2; exit 64; }
echo 'DEPRECATED: restart_app.sh forwards one recovery request' >&2
exec "${PIM_CAMERA_RECOVERYCTL:-/opt/pim/bin/cam-recoveryctl}" request gstapp_restart --source legacy-restart-app --reason legacy-wrapper --wait 120
