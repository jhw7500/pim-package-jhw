#!/usr/bin/env bash
set -u

PIM_LIB="${PIM_LIB:-/opt/pim/lib}"
PIM_BIN="${PIM_BIN:-/opt/pim/bin}"
export PIM_LIB PIM_BIN

# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_recovery_actions.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_operate_control.sh"
# shellcheck source=/dev/null
source "$PIM_LIB/cam_liveness.sh"

cam_liveness_ordered_stop --external
