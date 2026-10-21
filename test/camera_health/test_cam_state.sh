#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pim-cam-state.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export STATE_DIR="$WORK/state"
source "$ROOT/dist/pim/opt/pim/lib/cam_state.sh"

# ch{N}_last_ok is gone.  Its only writes were the 0 in cam_state_init and a
# `date +%s` inside cam_channel_error, so the field advanced while a channel was
# failing and stayed 0 while it was healthy - the exact inverse of the freshness
# signal its name promised.  Nothing read it.
#
# Two guards.  no_last_ok_source greps the shipped shell under
# dist/pim/opt/pim/lib and dist/pim/opt/pim/bin for a write of the key, so it
# reaches a write in a sibling library, in a function nothing calls, or in a
# consumer script.  The pattern keys on the channels/ prefix because the two
# deleted writes spell the channel as ch${ch} inside a loop, not as a literal
# digit; requiring the prefix also keeps an unrelated identifier such as
# eth1_last_ok, or prose naming the key, from failing this suite - it is the
# first bash suite in run_all.sh, which runs under set -eu, so a false positive
# here would take the thirteen suites after it down with no separate signal.
# It fails closed: a missing search root, or a grep exit above 1, is an error
# rather than a silent pass, and -I skips the prebuilt binaries under bin/ipc
# whose match grep reports where nothing would read it.
#
# no_last_ok_files then checks the state directory after cam_state_init,
# cam_channel_error, cam_channel_clear and cam_reset_state, which reaches a
# write whose key is assembled at runtime and so never appears in the source.
#
# What neither reaches is a key assembled so that channels/ and _last_ok never
# appear together in the source, inside a function this script never calls.
# Closing that would mean invoking every exported function, several with side
# effects, and is not worth it for a field with no reader.
no_last_ok_source() {
    local root hits rc=0
    for root in "$ROOT/dist/pim/opt/pim/lib" "$ROOT/dist/pim/opt/pim/bin"; do
        [ -d "$root" ] || {
            echo "no_last_ok_source: search root is missing: $root" >&2
            return 1
        }
    done
    hits=$(grep -rnIE 'channels/ch.*_last_ok' \
        "$ROOT/dist/pim/opt/pim/lib" \
        "$ROOT/dist/pim/opt/pim/bin") || rc=$?
    [ "$rc" -le 1 ] || {
        echo "no_last_ok_source: grep failed with rc=$rc" >&2
        return 1
    }
    [ -z "$hits" ] || {
        printf 'ch{N}_last_ok reintroduced:\n%s\n' "$hits" >&2
        return 1
    }
}

no_last_ok_files() {
    local ch
    for ch in 0 1 2 3; do
        [ ! -e "$STATE_DIR/channels/ch${ch}_last_ok" ] || {
            echo "ch${ch}_last_ok was recreated" >&2
            return 1
        }
    done
}

# The startup grace and init cooldown are gone too (#214).  Their writers
# (init_cam.sh's /tmp/last_init_cam_ts, start_cam.sh's last_start_ts) were lost
# in the b6b70a9 refactor and nothing wrote the timestamps since, so every
# reader was always false.  no_dead_grace_source keeps half of them from coming
# back: a writer without the readers, or a reader without a writer.  It matches
# the key names themselves, so a writer through any helper or a plain redirect
# is caught, and it scans every shipped shell script under dist/.  It scans
# shell only, because pim_guardian.py keeps its own live grace (measured from
# the guardian's start) under similar names.  Same fail-closed rules as above.
no_dead_grace_source() {
    local hits rc=0
    [ -d "$ROOT/dist" ] || {
        echo "no_dead_grace_source: search root is missing: $ROOT/dist" >&2
        return 1
    }
    hits=$(grep -rnIE --include='*.sh' \
        'last_init_cam_ts|last_(init|start)_ts|cam_record_(init|start)|cam_in_(startup_grace|init_cooldown)|\bin_(startup_grace|init_cooldown)\b' \
        "$ROOT/dist") || rc=$?
    [ "$rc" -le 1 ] || {
        echo "no_dead_grace_source: grep failed with rc=$rc" >&2
        return 1
    }
    [ -z "$hits" ] || {
        printf 'startup grace / init cooldown reintroduced:\n%s\n' "$hits" >&2
        return 1
    }
}

no_dead_grace_files() {
    local key
    for key in last_init_ts last_start_ts; do
        [ ! -e "$STATE_DIR/$key" ] || {
            echo "$key was recreated" >&2
            return 1
        }
    done
}

no_last_ok_source
no_dead_grace_source
cam_state_init
no_last_ok_files
no_dead_grace_files
[ "$(cam_get_state)" = healthy ]
[ "$(cam_state_get streak)" = 0 ]
cam_inc_streak; cam_inc_streak
[ "$(cam_get_state)" = degraded ]
cam_reset_streak
[ "$(cam_get_state)" = healthy ]
cam_channel_error 0
cam_has_channel_error
no_last_ok_files
cam_channel_clear 0
no_last_ok_files
! cam_has_channel_error
cam_reset_state
no_last_ok_files
no_dead_grace_files
[ "$(cam_get_state)" = healthy ]
echo "cam_state retained health contract: PASS"
