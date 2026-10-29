#!/usr/bin/env bash
# Build the deployed no-clobber publisher with the same target libc as PIM.
# Production full builds run in docker/build.sh Ubuntu 20.04 ARM64 image.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="${root}/tools/finalizer_noreplace.c"
output="${1:-${root}/dist/pim/opt/pim/bin/finalizer_noreplace}"

case "$output" in
    /*) ;;
    *) echo "finalizer helper: output path must be absolute" >&2; exit 2 ;;
esac
[ -f "$source_file" ] || { echo "finalizer helper: source missing" >&2; exit 2; }
[ ! -L "$output" ] || { echo "finalizer helper: destination is symlink" >&2; exit 2; }

mkdir -p "$(dirname "$output")"
scratch="$(mktemp "$(dirname "$output")/.finalizer-noreplace-build.XXXXXXXX")"
trap 'rm -f -- "$scratch"' EXIT

# CC may contain toolchain options such as sysroot.
read -r -a compiler <<< "${CC:-cc}"
[ "${#compiler[@]}" -gt 0 ] || exit 2
"${compiler[@]}" -std=c11 -O2 -Wall -Wextra -Werror \
    -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
    -o "$scratch" "$source_file"
chmod 0755 "$scratch"

# Reuse product target GLIBC 2.31 compatibility gate.
PIM_GLIBC_GATE=strict PIM_VERIFY_BINARIES=on PIM_MAX_GLIBC=2.31 \
    bash "${root}/tools/check_glibc.sh" "$scratch"

command -v readelf >/dev/null 2>&1 || {
    echo "finalizer helper: readelf unavailable, cannot verify target ELF" >&2
    exit 2
}
machine="$(readelf -h "$scratch" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
echo "finalizer publisher ELF machine: $machine"
[ "$machine" = "AArch64" ] || {
    echo "finalizer helper: refusing non-AArch64 binary in arm64 PIM package" >&2
    exit 2
}

# Only build artifact is replaced, never a recording.
mv -f -- "$scratch" "$output"
trap - EXIT
