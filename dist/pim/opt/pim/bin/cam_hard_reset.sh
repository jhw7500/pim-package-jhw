#!/usr/bin/env bash
# Deprecated compatibility boundary. -s/-S remain accepted but no longer control services.
set -u

while [ $# -gt 0 ]; do
    case "$1" in -q|--quiet|-s|--stop-service|-S|--start-service) shift;; -h|--help) echo 'usage: cam_hard_reset.sh [-q] [-s] [-S]'; exit 0;; *) echo "unknown option: $1" >&2; exit 64;; esac
done
echo 'DEPRECATED: cam_hard_reset.sh forwards one recovery request' >&2
exec "${PIM_CAMERA_RECOVERYCTL:-/opt/pim/bin/cam-recoveryctl}" request camera_hard_reset --source legacy-cam-hard-reset --reason legacy-wrapper --wait 300
