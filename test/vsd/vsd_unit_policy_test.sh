#!/usr/bin/env bash
# vsd-operate.service must carry the restart policy decided for issue #91.
#
# Scope note, deliberately narrow: this asserts the CONTENT OF A FILE, not the
# behaviour of a live service.  Nothing here starts, stops or queries systemd -
# the container used by the sibling binary test has no systemd, and this host is
# not the target.  Observing `systemctl is-active` / `show -p Result` on the
# board stays a manual step recorded in the PR evidence.
#
# Why the policy is what it is: a start that cannot bind now exits 1, so a bare
# Restart=on-failure would retry forever against an occupied port.  The start
# limit lets systemd latch the unit as `failed`, which is a state an operator can
# see.  No component in this package observes vsd-operate and the tree contains
# no `systemctl reset-failed`, so recovery from a latched failure is manual or a
# reboot.  Visibility is the deliverable, not automated repair.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UNIT=$ROOT/dist/pim/etc/systemd/system/vsd-operate.service

[ -f "$UNIT" ] || { echo "missing $UNIT" >&2; exit 1; }

# Section-aware parse: a directive in the wrong section is a real defect that a
# flat grep would pass.  StartLimit* belong to [Unit]; Restart* to [Service].
python3 - "$UNIT" <<'PY'
import configparser
import sys

want = {
    "Unit": {"StartLimitIntervalSec": "60s", "StartLimitBurst": "5"},
    "Service": {"Type": "simple", "Restart": "on-failure", "RestartSec": "3s"},
}

parser = configparser.ConfigParser(strict=False, allow_no_value=True)
parser.optionxform = str
with open(sys.argv[1], encoding="utf-8") as handle:
    parser.read_file(handle)

bad = []
for section, pairs in want.items():
    if not parser.has_section(section):
        bad.append(f"missing [{section}] section")
        continue
    for key, expected in pairs.items():
        actual = parser.get(section, key, fallback=None)
        if actual != expected:
            bad.append(f"[{section}] {key}: expected {expected!r}, got {actual!r}")

# A directive that landed in the wrong section must not silently pass.
for section, pairs in want.items():
    other = "Service" if section == "Unit" else "Unit"
    for key in pairs:
        if parser.has_section(other) and parser.get(other, key, fallback=None) is not None:
            bad.append(f"[{other}] must not carry {key}")

if bad:
    for line in bad:
        print(f"FAIL: {line}", file=sys.stderr)
    sys.exit(1)
print("unit directives: OK")
PY

# Stricter consumer: systemd's own parser names any directive it does not know.
# Without the positive control below a silent run would prove nothing.
if command -v systemd-analyze >/dev/null 2>&1; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    cp "$UNIT" "$work/vsd-operate.service"

    cp "$UNIT" "$work/control.service"
    printf 'ThisKeyDoesNotExist=1\n' >>"$work/control.service"

    # Capture first and match with `case`.  Piping into `grep -q` under
    # `set -o pipefail` makes grep exit at the first match, systemd-analyze take
    # SIGPIPE, and the pipeline report 141 - which silently turned this oracle
    # off until the control below caught it.
    control_out=$(systemd-analyze verify "$work/control.service" 2>&1 || true)
    unit_out=$(systemd-analyze verify "$work/vsd-operate.service" 2>&1 || true)

    # systemd-analyze also loads unrelated host units and reports their unknown
    # keys (snapd.service's RestartMode, for one).  Count only lines that name
    # the file under test, or the host's own noise fails this gate.
    control_hits=$(printf '%s\n' "$control_out" | grep -c 'control\.service:.*Unknown key name' || true)
    unit_hits=$(printf '%s\n' "$unit_out" | grep -c 'vsd-operate\.service:.*Unknown key name' || true)

    if [ "$control_hits" -gt 0 ]; then
        if [ "$unit_hits" -gt 0 ]; then
            echo "FAIL: systemd-analyze reports an unknown directive in vsd-operate.service" >&2
            printf '%s\n' "$unit_out" | grep 'vsd-operate\.service:.*Unknown key name' >&2 || true
            exit 1
        fi
        echo "systemd-analyze: no unknown directive (oracle confirmed on a known-bad control)"
    else
        echo "systemd-analyze: oracle did not flag a known-bad control; treating as unavailable" >&2
    fi
else
    echo "systemd-analyze: not installed; directive validity not independently checked"
fi

echo "vsd unit restart policy: PASS"
