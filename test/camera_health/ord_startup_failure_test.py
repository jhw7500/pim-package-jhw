#!/usr/bin/env python3
"""Hermetic native regression tests for ORD startup failures."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ORD_DIR = ROOT / "ord"
ORD_MAIN = ROOT / "ord/main.cpp"


class OrdStartupFailureTest(unittest.TestCase):
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
