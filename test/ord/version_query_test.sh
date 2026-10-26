#!/usr/bin/env bash
# The EVT_TEST reply carries the pim-mp package version.  ord runs the shell
# command below through popen() and keeps only the last output line
# (while (fgets(...));).  "dpkg -l | grep pim" also matches every other package
# with pim in its name - GitLab packages ship upgrade_file/dpkg/pimwebserver_*.deb -
# so the last line was the version of whichever package sorted last, not pim-mp.
# GitLab ord 87976ac (2026-07-02) switched the command to "dpkg -s pim-mp".
#
# Scope: the command text in ord/tcpServer.cpp, run against a fake dpkg.  It does
# not build ord or talk to a board.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SRC=${ORD_SRC:-$ROOT/ord/tcpServer.cpp}
WANT=0.6.3.2+jhw.camera19

# The version command is the only sprintf literal in ord that starts with dpkg.
mapfile -t cmds < <(grep -oE 'sprintf\(str, "dpkg[^"]*"' "$SRC" | sed -E 's/^sprintf\(str, "//; s/"$//')
[ "${#cmds[@]}" -eq 1 ] || { echo "matcher found ${#cmds[@]} dpkg commands in $SRC - expected 1" >&2; exit 1; }
cmd=${cmds[0]}
case $cmd in *\\*) echo "command has a C escape this test does not decode: $cmd" >&2; exit 1 ;; esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/dpkg" <<EOF
#!/bin/sh
case "\$1 \${2-}" in
    "-l ")
        cat <<'LIST'
Desired=Unknown/Install/Remove/Purge/Hold
| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst/trig-aWait/Trig-pend
|/ Err?=(none)/Reinst-required (Status,Err: uppercase=bad)
||/ Name           Version              Architecture Description
+++-==============-====================-============-==============================
ii  jq             1.6-1ubuntu0.20.04.1 arm64        lightweight JSON processor
ii  pim-mp         $WANT arm64        PIM camera package
ii  pimwebserver   1.1.0                arm64        PIM web server
LIST
        ;;
    "-s pim-mp")
        printf 'Package: pim-mp\nStatus: install ok installed\nVersion: %s\nArchitecture: arm64\n' "$WANT"
        ;;
    *) echo "dpkg-query: package '\${2-}' is not installed" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/dpkg"

got=$(PATH="$tmp:$PATH" sh -c "$cmd" | tail -n 1)
echo "  command: $cmd"
echo "  last line: $got"
[ "$got" = "$WANT" ] || { echo "ord version query: FAIL - ord would report '$got', want pim-mp '$WANT'" >&2; exit 1; }
echo "ord version query: PASS"
