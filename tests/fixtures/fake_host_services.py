#!/usr/bin/env python3
"""Deterministic loopback RESP/HTTP servers for host reachability tests.

The tester host probe must be exercised against something that actually
speaks (or deliberately mis-speaks) RESP and HTTP; a fake `docker` binary
proves nothing about whether the published ports answer. This fixture binds
both services to 127.0.0.1 on ephemeral ports, writes the chosen ports to a
file, and serves a scripted behavior chosen per service so every failure mode
the probe claims to detect is covered without any network access.

Standard library only, mirroring scripts/tester-host-probe.py.
"""

from __future__ import annotations

import argparse
import http.server
import os
import socket
import sys
import threading
import time

RESP_MODES = ("pong", "error", "garbage", "hang", "close", "none")
HTTP_MODES = ("ok", "empty", "error", "notfound", "hang", "none")

# Long enough that a bounded probe timeout always expires first, short enough
# that a leaked fixture process cannot linger for an entire CI run.
HANG_SECONDS = 30
MAX_LIFETIME_SECONDS = 120

METRICS_BODY = b"# HELP ferrite_up 1\n# TYPE ferrite_up gauge\nferrite_up 1\n"


def reserve_closed_port() -> int:
    """Return a port that is guaranteed not to be listening right now."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def serve_resp(listener: socket.socket, mode: str) -> None:
    while True:
        try:
            connection, _ = listener.accept()
        except OSError:
            return
        with connection:
            if mode == "close":
                continue
            if mode == "hang":
                time.sleep(HANG_SECONDS)
                continue
            try:
                connection.settimeout(5)
                connection.recv(1024)
                if mode == "pong":
                    connection.sendall(b"+PONG\r\n")
                elif mode == "error":
                    connection.sendall(b"-ERR unknown command 'PING'\r\n")
                elif mode == "garbage":
                    connection.sendall(b"HTTP/1.1 400 Bad Request\r\n")
            except OSError:
                continue


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    mode = "ok"
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.mode == "hang":
            time.sleep(HANG_SECONDS)
            return
        if self.mode == "error":
            self.send_response(500)
            body = b"internal error\n"
        elif self.mode == "notfound":
            self.send_response(404)
            body = b"not found\n"
        elif self.mode == "empty":
            self.send_response(200)
            body = b""
        else:
            self.send_response(200)
            body = METRICS_BODY
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, *_args: object) -> None:
        """Silence per-request logging; the test asserts on the probe output."""


def write_ports(path: str, resp_port: int, http_port: int) -> None:
    """Publish ports atomically so a reader never sees a partial file."""
    temporary = f"{path}.tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(f"resp_port={resp_port}\nhttp_port={http_port}\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resp-mode", choices=RESP_MODES, default="pong")
    parser.add_argument("--http-mode", choices=HTTP_MODES, default="ok")
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args(argv)

    resp_listener: socket.socket | None = None
    if args.resp_mode == "none":
        resp_port = reserve_closed_port()
    else:
        resp_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        resp_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        resp_listener.bind(("127.0.0.1", 0))
        resp_listener.listen(8)
        resp_port = resp_listener.getsockname()[1]

    http_server: http.server.ThreadingHTTPServer | None = None
    if args.http_mode == "none":
        http_port = reserve_closed_port()
    else:
        handler = type("ScriptedMetricsHandler", (MetricsHandler,), {"mode": args.http_mode})
        http_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        http_server.daemon_threads = True
        http_port = http_server.server_address[1]

    if resp_listener is not None:
        threading.Thread(
            target=serve_resp, args=(resp_listener, args.resp_mode), daemon=True
        ).start()
    if http_server is not None:
        threading.Thread(target=http_server.serve_forever, daemon=True).start()

    write_ports(args.port_file, resp_port, http_port)

    # Bounded lifetime: the test kills this process, but a self-imposed cap
    # guarantees no orphan survives a failed or interrupted test run.
    time.sleep(MAX_LIFETIME_SECONDS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
