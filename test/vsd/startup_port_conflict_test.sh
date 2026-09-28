#!/usr/bin/env bash
# vsd must report a failed start as a failed start.
#
# Before this test's fix, App's constructor tested Begin()'s return value with an
# empty if-body and entered WaitCommand() regardless, and main() returned 0
# unconditionally.  rc.local (dist/pim/etc/rc.local:35) creates
# /var/run/vsd.pipe with `touch`, not mkfifo - App::WaitCommand's own mkfifo sits
# inside #if 0 - so read() on that plain file returns 0 at EOF and the wait loop
# spun at 10 Hz forever.  Measured on the pre-fix aarch64 binary: a held port
# produced no exit at all (killed by timeout, 124) while the unit stayed active
# with no listener.  With the pipe path absent instead, the same failure exited
# 0.  Both are the defect; this test pins the deployed shape (plain file).
#
# The port-free control is not decoration.  Pre-fix, a healthy start also never
# exits, so an exit status alone cannot tell a fixed binary from a broken one -
# an implementation that always failed would pass a "non-zero on conflict" gate.
# The control therefore requires that vsd still owns the listener and is still
# running when the port is free.
#
# Local only: CI does not build or run the C++ modules.  Run it after
# ./docker/build.sh vsd.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=pim-builder-ubuntu20.04-arm64
BIN=dist/pim/usr/local/bin/vsd
PORT=10008   # config.cc:7 default; Config::Load() is #if 0 so no runtime yaml

[ -x "$ROOT/$BIN" ] || { echo "missing $BIN - run ./docker/build.sh vsd first" >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "missing image $IMAGE" >&2; exit 1; }

# --network none is a safety requirement, not a preference.  vsd binds
# INADDR_ANY and its command table (vsd/tcpsvr.cc) authenticates nothing, while
# one handler concatenates a request field onto a shell string and hands it to
# popen() as root.  On docker's default bridge that port is reachable from the
# host and from every other container even with no -p publish, so the control
# phase below - which deliberately gets vsd listening - would expose it for as
# long as it serves.  Every client here is in-container and uses loopback, which
# --network none keeps.  The mount is read-only because nothing writes under /w.
out=$(docker run --rm --network none -v "$ROOT:/w:ro" -w /w "$IMAGE" sh -c '
    set -u
    port='"$PORT"'
    bin=/w/'"$BIN"'
    export LD_LIBRARY_PATH=/w/vsd

    probe() {
        python3 -c "import socket,sys;s=socket.socket();s.settimeout(1);sys.exit(0 if s.connect_ex((\"127.0.0.1\","$port"))==0 else 1)"
    }

    # Deployed shape: rc.local touches this path, so it is a plain file.
    rm -f /var/run/vsd.pipe
    touch /var/run/vsd.pipe
    chmod 666 /var/run/vsd.pipe
    echo "PIPE_KIND=$(stat -c %F /var/run/vsd.pipe)"

    # --- control: port free.  A fixed vsd must serve and keep running. ---
    timeout 6 "$bin" >/tmp/ctl.out 2>&1 &
    ctl=$!
    listen=1
    i=0
    while [ $i -lt 40 ]; do
        if probe; then listen=0; break; fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "VSD_CTL_LISTEN=$listen"
    ctlrc=0
    wait "$ctl" || ctlrc=$?
    echo "VSD_CTL_EXIT=$ctlrc"
    sed "s/^/CTL| /" /tmp/ctl.out

    # --- failure: a real listener holds the port, so bind() must fail. ---
    # SO_REUSEADDR does not let a second bind() succeed against a listening
    # socket, so the holder must reach listen(), not just bind().
    python3 - "$port" <<PY &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1])))
s.listen(1)
time.sleep(60)
PY
    holder=$!
    i=0
    while [ $i -lt 50 ]; do
        if probe; then break; fi
        i=$((i + 1))
        sleep 0.1
    done
    failrc=0
    timeout 20 "$bin" >/tmp/fail.out 2>&1 || failrc=$?
    echo "VSD_FAIL_EXIT=$failrc"
    sed "s/^/FAIL| /" /tmp/fail.out
    kill "$holder" 2>/dev/null || true
' 2>&1) || true

echo "$out" | sed 's/^/    /'

fail() { echo "FAIL: $1" >&2; exit 1; }

# grep -c drains its input.  grep -q exits at the first match, which makes the
# writer take SIGPIPE and, under `set -o pipefail`, reports 141 even though the
# pattern matched - a spurious failure as soon as the captured output outgrows the
# pipe buffer.  The sibling unit test hit exactly this and was fixed the same way.
matched() {
    local hits
    hits=$(printf '%s\n' "$out" | grep -c "$1" || true)
    [ "$hits" -gt 0 ]
}

matched '^PIPE_KIND=regular empty file$' \
    || fail "harness did not reproduce the deployed plain-file pipe"

# Control: reject an implementation that fails every start.  124 is the healthy
# outcome here because vsd is a daemon - timeout ends it, it does not exit alone.
matched '^VSD_CTL_LISTEN=0$' || fail "port-free control: vsd did not answer on $PORT"
matched '^VSD_CTL_EXIT=124$' \
    || fail "port-free control: vsd stopped on its own; a healthy start must keep running"

# Pin the status rather than "any non-zero": 124 is the pre-fix infinite spin and
# 0 is the pre-fix silent success, so both must fail this gate.
matched '^VSD_FAIL_EXIT=1$' \
    || fail "expected VSD_FAIL_EXIT=1; 124 means it spun, 0 means it reported success"

matched "bind failed on 0\.0\.0\.0:$PORT" || fail "bind failure log lacks the endpoint"
matched 'Address already in use' || fail "bind failure log lacks the errno text"
matched 'startup aborted' || fail "no startup-abort log"

echo "vsd startup port conflict: PASS"
