#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-cam-state.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export STATE_DIR="$WORK/state"
source "$ROOT/dist/pim/opt/pim/lib/cam_state.sh"

cam_state_init
[ "$(cam_get_state)" = healthy ]
[ "$(cam_state_get streak)" = 0 ]
cam_inc_streak; cam_inc_streak
[ "$(cam_get_state)" = degraded ]
cam_reset_streak
[ "$(cam_get_state)" = healthy ]
cam_channel_error 0
cam_has_channel_error
cam_channel_clear 0
! cam_has_channel_error
cam_record_init
[ "$(cam_get_state)" = recovering ]
cam_record_start
[ "$(cam_state_get recording/start_video_time_actual '')" = '' ]
cam_reset_state
[ "$(cam_get_state)" = healthy ]
echo "cam_state retained health contract: PASS"
