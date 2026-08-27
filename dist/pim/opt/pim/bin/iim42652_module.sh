#!/bin/bash
set -euo pipefail

EXPECTED_KERNEL_RELEASE=5.10.35-lts-5.10.y+g2fce14defc04

case "${1:-}" in
load)
    running_kernel=$(uname -r)
    if [ "$running_kernel" != "$EXPECTED_KERNEL_RELEASE" ]; then
        echo "IIM-42652 kernel mismatch: running $running_kernel, expected $EXPECTED_KERNEL_RELEASE" >&2
        exit 1
    fi
    modprobe inv-icm42600-i2c
    ;;
unload)
    modprobe -r inv-icm42600-i2c inv-icm42600 inv_sensors_timestamp
    ;;
status)
    if ! lsmod | grep -E '^inv_(icm42600|sensors_timestamp)'; then
        echo "IIM-42652 modules are not loaded"
    fi
    ;;
*)
    echo "Usage: $(basename "$0") {load|unload|status}" >&2
    exit 2
    ;;
esac
