#!/bin/bash
# cam_fps_stack must remain a directly runnable, hardware-free CLI on --help.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$ROOT/dist/pim/opt/pim/bin/cam_fps_stack.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "=== cam_fps_stack package CLI ==="

[ -x "$SCRIPT" ] || fail "missing or non-executable package script: $SCRIPT"

help_output=$(
    cd /tmp
    "$SCRIPT" --help
) || fail "--help must exit successfully without target hardware"

case "$help_output" in
    *"--channel ch01|ch23|both"*"--deep"*) ;;
    *) fail "--help does not describe channel selection and deep verification" ;;
esac

if invalid_output=$(
    cd /tmp
    "$SCRIPT" --channel invalid 2>&1
); then
    fail "invalid channel was accepted"
fi

case "$invalid_output" in
    *"ch01 | ch23 | both | auto"*) ;;
    *) fail "invalid channel error does not list the supported values" ;;
esac

echo "PASS: cam_fps_stack package CLI"
