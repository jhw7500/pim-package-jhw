#!/bin/bash
set -euo pipefail

MODULE_ROOT=${IIM_MODULE_ROOT:-/lib/modules}
KERNEL_RELEASE=${IIM_KERNEL_RELEASE:-5.10.35-lts-5.10.y+g2fce14defc04}
MODINFO=${IIM_MODINFO:-modinfo}
DEPMOD=${IIM_DEPMOD:-depmod}

MODULE_DIR="$MODULE_ROOT/$KERNEL_RELEASE/updates/pim-iim42652"

verify_module() {
    local module=$1
    local path="$MODULE_DIR/$module"
    local vermagic

    [ -f "$path" ] || {
        echo "IIM-42652 module is missing: $path" >&2
        return 1
    }

    vermagic=$("$MODINFO" -F vermagic "$path")
    case "$vermagic" in
        "$KERNEL_RELEASE "*) ;;
        *)
            echo "IIM-42652 vermagic mismatch: $module: $vermagic (target: $KERNEL_RELEASE)" >&2
            return 1
            ;;
    esac
}

verify_module inv-icm42600.ko
verify_module inv-icm42600-i2c.ko
verify_module inv_sensors_timestamp.ko

"$DEPMOD" -a "$KERNEL_RELEASE"
echo "IIM-42652 package modules prepared for $KERNEL_RELEASE (manual load only)"
