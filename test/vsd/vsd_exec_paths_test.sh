#!/usr/bin/env bash
# Every absolute /opt/ path that vsd hands to popen()/system() must exist in the
# package payload (dist/pim).  Issue #146: vsd called /opt/pim/bin/fwdriver and
# /opt/pim/bin/init.py, but both files have only ever shipped under /opt/cis/bin
# (pim-package c199b43, 2024-04-22).  A 2024-05-10 vsd commit moved the sibling
# update_network call to /opt/cis/bin and left these two behind, so the TCP
# firmware upgrade and the config reload silently ran nothing.
#
# Scope: source text against the payload tree.  It does not check that the board
# has the file, only that this package would install it.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SRC_DIR=${VSD_SRC_DIR:-$ROOT/vsd}
PAYLOAD=$ROOT/dist/pim

# Quoted literals that start with an absolute /opt/ path, optionally behind an
# interpreter ("python3 /opt/..."). The first word after the interpreter is the
# executable; arguments are ignored.
mapfile -t paths < <(
    grep -hoE '"(python3 )?/opt/[^" ]+' "$SRC_DIR"/*.cc "$SRC_DIR"/*.cpp "$SRC_DIR"/*.h 2>/dev/null \
        | sed -E 's/^"//; s/^python3 //' | sort -u
)

# Positive control on the matcher itself: with no match the loop below would pass
# vacuously.  vsd calls at least update_network.py and fwdriver.
[ "${#paths[@]}" -ge 2 ] || { echo "matcher found ${#paths[@]} /opt/ paths in $SRC_DIR - expected >= 2" >&2; exit 1; }

missing=0
for p in "${paths[@]}"; do
    if [ -e "$PAYLOAD$p" ]; then
        echo "  ok      $p"
    else
        echo "  MISSING $p (not in dist/pim)" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || { echo "vsd exec paths: FAIL" >&2; exit 1; }
echo "vsd exec paths: PASS"
