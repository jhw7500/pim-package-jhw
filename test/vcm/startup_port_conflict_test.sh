#!/usr/bin/env bash
# vcm must report a failed start as a failed start.
#
# Before this test's fix, main() flagged an init() failure and fell into the
# normal shutdown path, whose destroy() ends in exit(0) - so a port already in
# use left the process reporting success.  cam-operate cannot tell that apart
# from a clean stop.
#
# This runs the aarch64 binary under the project's build container (binfmt
# qemu on the host), holds vcm's port, and asserts the exit status and the log.
#
# Local only: CI does not build or run the C++ modules.  Run it after
# ./docker/build.sh vcm.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=pim-builder-ubuntu20.04-arm64
BIN=dist/pim/usr/local/bin/vcm
PORT=10009   # tcpServer.cpp init_json_config() default; no runtime json here

[ -x "$ROOT/$BIN" ] || { echo "missing $BIN - run ./docker/build.sh vcm first" >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "missing image $IMAGE" >&2; exit 1; }

out=$(docker run --rm -v "$ROOT:/w" -w /w "$IMAGE" sh -c '
    set -eu
    port='"$PORT"'
    # Hold the port with a real listener: SO_REUSEADDR does not let a second
    # bind() succeed against a listening socket, so vcm must fail here.
    python3 - "$port" <<PY &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1])))
s.listen(1)
time.sleep(30)
PY
    holder=$!
    trap "kill $holder 2>/dev/null || true" EXIT
    for _ in $(seq 50); do
        python3 -c "import socket,sys;s=socket.socket();sys.exit(0 if s.connect_ex((\"127.0.0.1\",'"$PORT"'))==0 else 1)" && break
        sleep 0.1
    done
    rc=0
    timeout 20 '"$BIN"' 2>&1 || rc=$?
    echo "VCM_EXIT=$rc"
' 2>&1) || true

echo "$out" | sed 's/^/    /'

# Pin the status rather than "any non-zero": the binary runs under timeout,
# whose 124 would otherwise let a startup path that hangs pass this gate.
echo "$out" | grep -q 'VCM_EXIT=1$' || {
    echo "FAIL: expected VCM_EXIT=1; 124 means it hung, 0 means it reported success" >&2
    exit 1
}
echo "$out" | grep -q "Server bind failed on .*:$PORT" || { echo "FAIL: bind failure log lacks the endpoint" >&2; exit 1; }
echo "$out" | grep -q 'startup aborted' || { echo "FAIL: no startup-abort log" >&2; exit 1; }

echo "vcm startup port conflict: PASS"
