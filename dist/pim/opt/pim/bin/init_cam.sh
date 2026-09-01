#!/usr/bin/env bash
# Deprecated compatibility boundary. Module work is executor-only.
set -u

while [ $# -gt 0 ]; do
    case "$1" in -q|--quiet) shift;; -h|--help) echo 'usage: init_cam.sh [-q]'; exit 0;; *) echo "unknown option: $1" >&2; exit 64;; esac
done
echo 'DEPRECATED: init_cam.sh forwards one recovery request' >&2
exec "${PIM_CAMERA_RECOVERYCTL:-/opt/pim/bin/cam-recoveryctl}" request module_reload --source legacy-init-cam --reason legacy-wrapper --wait 300
