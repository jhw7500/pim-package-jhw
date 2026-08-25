#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODE=${PIM_VERIFY_BINARIES:-warn}
VERIFIER="$ROOT/tools/verify_binaries.py"

case "$MODE" in
    off)
        echo "Binary verification disabled (PIM_VERIFY_BINARIES=off)"
        exit 0
        ;;
    warn)
        python3 "$VERIFIER"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            exit 0
        fi
        echo "WARNING: binary verification failed (rc=$rc); build remains successful in warn mode" >&2
        exit 0
        ;;
    strict)
        python3 "$VERIFIER" --strict
        exit $?
        ;;
    *)
        echo "ERROR: PIM_VERIFY_BINARIES must be off, warn, or strict (got: $MODE)" >&2
        exit 2
        ;;
esac
