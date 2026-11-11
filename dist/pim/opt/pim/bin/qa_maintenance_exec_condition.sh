#!/bin/sh
# Systemd-only start admission. A persistent QA marker blocks all new
# cam-operate/ORD invocations, even when a legacy launcher bypasses the Owner.
# No creation, cleanup, or authorization of the marker occurs here.
set -eu

state_dir=${PIM_CAMERA_STATE_DIR:-/var/lib/pim-camera}
[ -d "$state_dir" ] && [ ! -L "$state_dir" ] || exit 1
marker="$state_dir/qa-maintenance.json"
# A malformed document or dangling symlink is NOT absence.
[ ! -e "$marker" ] && [ ! -L "$marker" ] || exit 1
exit 0
