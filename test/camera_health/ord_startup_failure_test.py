#!/usr/bin/env python3
"""Hermetic native regression tests for ORD startup failures."""

import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ORD_DIR = ROOT / "ord"
ORD_MAIN = ROOT / "ord/main.cpp"


class OrdStartupFailureTest(unittest.TestCase):
    def test_readiness_is_published_only_after_init_completes(self):
        compiler = shutil.which("g++")
        self.assertIsNotNone(compiler, "g++ is required for the native ORD contract")

        with tempfile.TemporaryDirectory(prefix="ord-readiness.") as raw:
            work = Path(raw)
            run_dir = work / "run"
            run_dir.mkdir()
            (work / "main.cpp").write_bytes(ORD_MAIN.read_bytes())
            (work / "tcpServer.h").write_text(
                r"""
#ifndef _TCPSERVER_H_
#define _TCPSERVER_H_
#define _UTIL_H_
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
#define LOG_NOTICE 0
#define _FILE_ "main.cpp"
#define __LOG(...) do { } while (0)
class CTCPServer {
public:
    int m_flagDestroy;
    CTCPServer() : m_flagDestroy(0) {}
    static CTCPServer *getInstance() {
        static CTCPServer server;
        return &server;
    }
    int init() {
        const char *run_dir = std::getenv("PIM_CAMERA_RUN_DIR");
        char entered[512] = {};
        char release[512] = {};
        std::snprintf(entered, sizeof(entered), "%s/init-entered", run_dir);
        std::snprintf(release, sizeof(release), "%s/release-init", run_dir);
        FILE *marker = std::fopen(entered, "w");
        if (!marker)
            return -1;
        std::fclose(marker);
        while (access(release, F_OK) != 0)
            usleep(10000);
        return 0;
    }
    int destroy() { return 0; }
};
#endif
""",
                encoding="utf-8",
            )
            binary = work / "ord-readiness-probe"
            compiled = subprocess.run(
                [
                    compiler,
                    "-std=c++11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    str(work / "main.cpp"),
                    "-o",
                    str(binary),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                check=False,
            )
            self.assertEqual(0, compiled.returncode, compiled.stderr)

            invocation = "0123456789abcdef0123456789abcdef"
            ready = run_dir / "ord-ready"
            entered = run_dir / "init-entered"
            release = run_dir / "release-init"
            env = os.environ.copy()
            env["PIM_CAMERA_RUN_DIR"] = str(run_dir)
            env["INVOCATION_ID"] = invocation
            process = subprocess.Popen(
                [str(binary)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
            )
            try:
                deadline = time.monotonic() + 2
                while not entered.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(entered.exists(), "ORD init probe did not start")
                self.assertFalse(ready.exists(), "ORD became ready before init returned")

                release.touch()
                deadline = time.monotonic() + 2
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertEqual(
                    invocation + "\n",
                    ready.read_text(encoding="ascii") if ready.exists() else "",
                    "ORD did not publish readiness for its systemd invocation",
                )
                self.assertIsNone(process.poll(), "ORD exited after publishing readiness")
            finally:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)

            ready.unlink()
            entered.unlink()
            release.unlink()
            sentinel = work / "sentinel"
            sentinel.write_text("do-not-touch\n", encoding="ascii")
            process = subprocess.Popen(
                [str(binary)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
            )
            try:
                deadline = time.monotonic() + 2
                while not entered.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(entered.exists(), "second ORD init probe did not start")
                temporary = Path(f"{ready}.tmp.{process.pid}")
                os.link(sentinel, temporary)
                release.touch()
                self.assertEqual(
                    1,
                    process.wait(timeout=2),
                    "ORD reused a pre-existing readiness temporary",
                )
                self.assertEqual(
                    "do-not-touch\n",
                    sentinel.read_text(encoding="ascii"),
                    "ORD overwrote a pre-existing readiness temporary",
                )
                self.assertFalse(ready.exists(), "ORD published a pre-existing temporary")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=2)

    def test_positive_init_failure_exits_without_publishing_readiness(self):
        compiler = shutil.which("g++")
        self.assertIsNotNone(compiler, "g++ is required for the native ORD contract")

        with tempfile.TemporaryDirectory(prefix="ord-positive-init-failure.") as raw:
            work = Path(raw)
            run_dir = work / "run"
            run_dir.mkdir()
            (work / "main.cpp").write_bytes(ORD_MAIN.read_bytes())
            (work / "tcpServer.h").write_text(
                r"""
#ifndef _TCPSERVER_H_
#define _TCPSERVER_H_
#define _UTIL_H_
#include <cerrno>
#define LOG_NOTICE 0
#define _FILE_ "main.cpp"
#define __LOG(...) do { } while (0)
class CTCPServer {
public:
    int m_flagDestroy;
    CTCPServer() : m_flagDestroy(0) {}
    static CTCPServer *getInstance() {
        static CTCPServer server;
        return &server;
    }
    int init() { return EAGAIN; }
    int destroy() { return 0; }
};
#endif
""",
                encoding="utf-8",
            )
            binary = work / "ord-positive-init-probe"
            compiled = subprocess.run(
                [
                    compiler,
                    "-std=c++11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    str(work / "main.cpp"),
                    "-o",
                    str(binary),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                check=False,
            )
            self.assertEqual(0, compiled.returncode, compiled.stderr)

            invocation = "0123456789abcdef0123456789abcdef"
            ready = run_dir / "ord-ready"
            env = os.environ.copy()
            env["PIM_CAMERA_RUN_DIR"] = str(run_dir)
            env["INVOCATION_ID"] = invocation
            process = subprocess.Popen(
                [str(binary)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
            )
            try:
                deadline = time.monotonic() + 2
                while (
                    process.poll() is None
                    and not ready.exists()
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                returncode = process.poll()
                self.assertIsNotNone(
                    returncode,
                    "positive initialization failure left ORD running",
                )
                self.assertNotEqual(
                    0,
                    returncode,
                    "positive initialization failure exited successfully",
                )
                self.assertFalse(
                    ready.exists(),
                    "positive initialization failure published readiness",
                )
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=2)

    def test_init_failure_exits_nonzero_before_destroy_can_mask_it(self):
        compiler = shutil.which("g++")
        self.assertIsNotNone(compiler, "g++ is required for the native ORD contract")

        with tempfile.TemporaryDirectory(prefix="ord-startup-failure.") as raw:
            work = Path(raw)
            (work / "main.cpp").write_bytes(ORD_MAIN.read_bytes())
            (work / "tcpServer.h").write_text(
                r"""
#ifndef _TCPSERVER_H_
#define _TCPSERVER_H_
#define _UTIL_H_
#include <cstdlib>
#include <unistd.h>
#define LOG_NOTICE 0
#define _FILE_ "main.cpp"
#define __LOG(...) do { } while (0)
class CTCPServer {
public:
    int m_flagDestroy;
    static CTCPServer *getInstance() {
        static CTCPServer server;
        return &server;
    }
    int init() { return -1; }
    int destroy() { std::_Exit(0); }
};
#endif
""",
                encoding="utf-8",
            )
            binary = work / "ord-main-probe"
            compiled = subprocess.run(
                [
                    compiler,
                    "-std=c++11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    str(work / "main.cpp"),
                    "-o",
                    str(binary),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                check=False,
            )
            self.assertEqual(0, compiled.returncode, compiled.stderr)

            result = subprocess.run(
                [str(binary)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                timeout=2,
                check=False,
            )
            self.assertNotEqual(
                0,
                result.returncode,
                "ORD init failure was masked as a successful process exit",
            )

    def test_bind_collision_preserves_errno_address_and_port(self):
        compiler = shutil.which("g++")
        self.assertIsNotNone(compiler, "g++ is required for the native ORD contract")

        probe = r"""
#include "socket_diagnostics.h"
#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <sys/socket.h>
#include <unistd.h>

int main() {
    int first = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    int second = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (first < 0 || second < 0)
        return 10;

    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(0);
    if (inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) != 1)
        return 11;
    if (bind(first, reinterpret_cast<sockaddr *>(&address), sizeof(address)) < 0)
        return 12;
    if (listen(first, 1) < 0)
        return 13;
    socklen_t length = sizeof(address);
    if (getsockname(first, reinterpret_cast<sockaddr *>(&address), &length) < 0)
        return 14;

    char diagnostic[256] = {};
    errno = 0;
    int rc = ord_bind_socket(second, &address, diagnostic, sizeof(diagnostic));
    int bind_errno = errno;
    char port[32] = {};
    std::snprintf(port, sizeof(port), "port=%u", ntohs(address.sin_port));

    close(second);
    close(first);
    if (rc >= 0 || bind_errno != EADDRINUSE)
        return 20;
    if (!std::strstr(diagnostic, "address=127.0.0.1"))
        return 21;
    if (!std::strstr(diagnostic, port))
        return 22;
    if (!std::strstr(diagnostic, "errno="))
        return 23;
    if (!std::strstr(diagnostic, std::strerror(EADDRINUSE)))
        return 24;
    std::printf("%s\n", diagnostic);
    return 0;
}
"""
        with tempfile.TemporaryDirectory(prefix="ord-bind-diagnostic.") as raw:
            work = Path(raw)
            source = work / "probe.cpp"
            binary = work / "bind-probe"
            source.write_text(probe, encoding="utf-8")
            compiled = subprocess.run(
                [
                    compiler,
                    "-std=c++11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I",
                    str(ORD_DIR),
                    str(source),
                    "-o",
                    str(binary),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                check=False,
            )
            self.assertEqual(0, compiled.returncode, compiled.stderr)
            result = subprocess.run(
                [str(binary)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                timeout=2,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
