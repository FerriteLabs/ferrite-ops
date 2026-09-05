#!/usr/bin/env python3
"""Verify a running tester deployment is actually reachable from the host.

Docker reporting a container as healthy only proves the in-container
healthcheck passed. It says nothing about whether the published loopback
ports actually forward traffic, which is exactly the failure an external
tester hits first (a busy port, a partially published mapping, or a metrics
listener that never bound). This probe closes that gap from the host side:

1. Open a TCP connection to the Redis-compatible port and speak RESP: send
   an inline-safe ``PING`` array and require a ``+PONG`` simple string.
2. Issue an HTTP ``GET /metrics`` against the metrics port and require a 2xx
   status with a non-empty body.

It is intentionally dependency-free (Python 3 standard library only) so a
tester never has to install anything beyond Docker and Python, every timeout
is bounded so it can never hang a session, and every failure prints an
actionable message naming the exact endpoint and remedy.
"""

from __future__ import annotations

import argparse
import errno
import http.client
import socket
import sys
import time

PROGRAM = "tester-host-probe"

# Exit codes are distinct so callers (and tests) can tell *which* endpoint
# failed without parsing prose.
EXIT_OK = 0
EXIT_USAGE = 2
EXIT_RESP = 3
EXIT_METRICS = 4

PING_COMMAND = b"*1\r\n$4\r\nPING\r\n"
EXPECTED_PONG = "+PONG"

# A RESP simple string reply is tiny; refuse to buffer more than this so a
# misbehaving or non-Ferrite listener cannot stream unbounded data at us.
MAX_RESP_REPLY_BYTES = 1024

# Metrics payloads are text; read a bounded prefix only. We just need to
# prove the endpoint answers with content, not to parse it.
MAX_METRICS_BODY_BYTES = 65536

MIN_PORT = 1
MAX_PORT = 65535
MIN_TIMEOUT = 0.1
MAX_TIMEOUT = 300.0


class ProbeError(Exception):
    """A probe failed with an actionable, tester-facing explanation."""

    def __init__(self, message: str, exit_code: int) -> None:
        super().__init__(message)
        self.exit_code = exit_code


def _port(value: str) -> int:
    try:
        port = int(value, 10)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{value!r} is not an integer port") from None
    if not MIN_PORT <= port <= MAX_PORT:
        raise argparse.ArgumentTypeError(
            f"port must be between {MIN_PORT} and {MAX_PORT}; got {port}"
        )
    return port


def _timeout(value: str) -> float:
    try:
        seconds = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{value!r} is not a number") from None
    if not MIN_TIMEOUT <= seconds <= MAX_TIMEOUT:
        raise argparse.ArgumentTypeError(
            f"timeout must be between {MIN_TIMEOUT} and {MAX_TIMEOUT} seconds; got {seconds}"
        )
    return seconds


def _non_negative_int(value: str) -> int:
    try:
        parsed = int(value, 10)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{value!r} is not an integer") from None
    if parsed < 0:
        raise argparse.ArgumentTypeError(f"value must not be negative; got {parsed}")
    return parsed


def _connection_hint(host: str, port: int, exc: OSError) -> str:
    if isinstance(exc, socket.timeout) or exc.errno == errno.ETIMEDOUT:
        return (
            f"timed out connecting to {host}:{port}. A firewall or an "
            "overloaded host can cause this; retry, then stop and report it."
        )
    if exc.errno in (errno.ECONNREFUSED, errno.EHOSTUNREACH, errno.ENETUNREACH):
        return (
            f"nothing is accepting connections on {host}:{port}. Confirm "
            "'./scripts/tester.sh start' finished, that the port is published, "
            "and that no other process is holding it."
        )
    return f"could not connect to {host}:{port}: {exc}"


# A peer that resets or closes the connection mid-exchange surfaces as EOF on
# some platforms and as ECONNRESET/EPIPE on others (macOS resets when data is
# still unread in the receive buffer). Both mean the same thing to a tester.
_CLOSED_ERRNOS = frozenset(
    code
    for code in (
        getattr(errno, "ECONNRESET", None),
        getattr(errno, "EPIPE", None),
        getattr(errno, "ESHUTDOWN", None),
    )
    if code is not None
)


def _closed_before_reply(host: str, port: int) -> ProbeError:
    return ProbeError(
        f"{host}:{port} closed the connection before replying to PING. "
        "The published port is not serving a Redis-compatible endpoint.",
        EXIT_RESP,
    )


def _remaining(deadline: float, message: str, exit_code: int) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ProbeError(message, exit_code)
    return remaining


def _http_socket(
    connection: http.client.HTTPConnection,
    response: http.client.HTTPResponse | None = None,
) -> socket.socket:
    if connection.sock is not None:
        return connection.sock
    if response is not None and response.fp is not None:
        raw = getattr(response.fp, "raw", None)
        response_socket = getattr(raw, "_sock", None)
        if isinstance(response_socket, socket.socket):
            return response_socket
    raise ProbeError(
        "metrics probe lost its HTTP socket before the response completed.",
        EXIT_METRICS,
    )


def _read_resp_line(connection: socket.socket, host: str, port: int, deadline: float) -> str:
    buffer = bytearray()
    while b"\r\n" not in buffer:
        remaining = _remaining(
            deadline,
            (
                f"{host}:{port} accepted the connection but sent no complete RESP "
                "reply before the timeout. The port may be published to a "
                "different service than Ferrite."
            ),
            EXIT_RESP,
        )
        connection.settimeout(remaining)
        try:
            chunk = connection.recv(MAX_RESP_REPLY_BYTES)
        except socket.timeout:
            raise ProbeError(
                f"timed out waiting for a RESP reply from {host}:{port}. "
                "Confirm the container is healthy and the port is not being "
                "intercepted by another process.",
                EXIT_RESP,
            ) from None
        except OSError as exc:
            if exc.errno in _CLOSED_ERRNOS:
                raise _closed_before_reply(host, port) from exc
            raise ProbeError(
                f"failed reading the RESP reply from {host}:{port}: {exc}",
                EXIT_RESP,
            ) from exc

        if not chunk:
            raise _closed_before_reply(host, port)

        buffer.extend(chunk)
        if len(buffer) > MAX_RESP_REPLY_BYTES:
            raise ProbeError(
                f"{host}:{port} sent an oversized reply to PING; it is not a "
                "Redis-compatible endpoint.",
                EXIT_RESP,
            )

    line, _, _ = bytes(buffer).partition(b"\r\n")
    return line.decode("utf-8", errors="replace")


def probe_resp(host: str, port: int, timeout: float) -> str:
    """Send RESP PING to host:port and require an exact ``+PONG`` reply."""
    deadline = time.monotonic() + timeout
    try:
        connection = socket.create_connection(
            (host, port),
            timeout=_remaining(
                deadline,
                f"timed out before connecting to {host}:{port}.",
                EXIT_RESP,
            ),
        )
    except OSError as exc:
        raise ProbeError(
            f"Redis-compatible port probe failed: {_connection_hint(host, port, exc)}",
            EXIT_RESP,
        ) from exc

    try:
        connection.settimeout(
            _remaining(
                deadline,
                f"timed out before sending PING to {host}:{port}.",
                EXIT_RESP,
            )
        )
        try:
            connection.sendall(PING_COMMAND)
        except OSError as exc:
            if exc.errno in _CLOSED_ERRNOS:
                raise _closed_before_reply(host, port) from exc
            raise ProbeError(
                f"failed sending PING to {host}:{port}: {exc}. The published "
                "port is not serving a Redis-compatible endpoint.",
                EXIT_RESP,
            ) from exc

        reply = _read_resp_line(connection, host, port, deadline)
    finally:
        try:
            connection.close()
        except OSError:  # pragma: no cover - close failures are not actionable
            pass

    if reply != EXPECTED_PONG:
        raise ProbeError(
            f"{host}:{port} answered PING with {reply!r}, expected "
            f"{EXPECTED_PONG!r}. The published port is not serving the "
            "candidate Ferrite build.",
            EXIT_RESP,
        )
    return reply


def probe_metrics(host: str, port: int, timeout: float, path: str = "/metrics") -> int:
    """GET ``path`` on host:port and require a 2xx status with a body."""
    deadline = time.monotonic() + timeout
    url = f"http://{host}:{port}{path}"
    connection = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        try:
            connection.timeout = _remaining(
                deadline,
                f"metrics probe total deadline expired before connecting to {url}.",
                EXIT_METRICS,
            )
            connection.connect()
            _http_socket(connection).settimeout(
                _remaining(
                    deadline,
                    f"metrics probe total deadline expired before requesting {url}.",
                    EXIT_METRICS,
                )
            )
            connection.request("GET", path, headers={"Accept": "text/plain"})
            _http_socket(connection).settimeout(
                _remaining(
                    deadline,
                    f"metrics probe total deadline expired before response headers from {url}.",
                    EXIT_METRICS,
                )
            )
            response = connection.getresponse()
        except socket.timeout as exc:
            raise ProbeError(
                f"metrics probe timed out against {url}. "
                "Confirm the metrics port is published and the container is healthy.",
                EXIT_METRICS,
            ) from exc
        except OSError as exc:
            raise ProbeError(
                f"metrics probe failed: {_connection_hint(host, port, exc)}",
                EXIT_METRICS,
            ) from exc
        except http.client.HTTPException as exc:
            raise ProbeError(
                f"{url} did not return a valid HTTP "
                f"response ({exc}). The published port is not serving the "
                "Ferrite metrics endpoint.",
                EXIT_METRICS,
            ) from exc

        status = response.status
        body = bytearray()
        response_socket = _http_socket(connection, response)
        try:
            while len(body) < MAX_METRICS_BODY_BYTES:
                response_socket.settimeout(
                    _remaining(
                        deadline,
                        f"metrics probe total deadline expired while reading the response body from {url}.",
                        EXIT_METRICS,
                    )
                )
                chunk = response.read1(MAX_METRICS_BODY_BYTES - len(body))
                if not chunk:
                    break
                body.extend(chunk)
        except ProbeError:
            raise
        except socket.timeout as exc:
            raise ProbeError(
                f"metrics probe total deadline expired while reading the response body from {url}.",
                EXIT_METRICS,
            ) from exc
        except (OSError, http.client.HTTPException) as exc:
            raise ProbeError(
                f"failed reading the response body from {url}: {exc}",
                EXIT_METRICS,
            ) from exc
    finally:
        try:
            connection.close()
        except OSError:  # pragma: no cover - close failures are not actionable
            pass

    if not 200 <= status < 300:
        raise ProbeError(
            f"{url} returned HTTP {status}, expected a 2xx "
            "status. Check the container logs with './scripts/tester.sh diagnostics'.",
            EXIT_METRICS,
        )
    if not body.strip():
        raise ProbeError(
            f"{url} returned HTTP {status} with an empty "
            "body. Metrics are not being exported by the candidate build.",
            EXIT_METRICS,
        )
    return status


def _with_retries(probe, attempts: int, delay: float):
    """Run ``probe`` up to ``attempts`` times, returning its first success.

    Retries exist only to absorb the short window between Docker reporting a
    container healthy and the published port accepting traffic. The total
    wall-clock cost stays bounded by attempts * (timeout + delay).
    """
    last_error: ProbeError | None = None
    for attempt in range(1, attempts + 1):
        try:
            return probe()
        except ProbeError as exc:
            last_error = exc
            if attempt < attempts:
                time.sleep(delay)
    assert last_error is not None
    raise last_error


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog=PROGRAM,
        description=(
            "Verify the tester deployment is reachable from the host: RESP PING "
            "on the Redis-compatible port and HTTP GET /metrics on the metrics port."
        ),
    )
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="Host to probe (default: 127.0.0.1; the tester ports are loopback-only)",
    )
    parser.add_argument("--port", type=_port, required=True, help="Redis-compatible host port")
    parser.add_argument("--metrics-port", type=_port, required=True, help="Metrics host port")
    parser.add_argument(
        "--timeout",
        type=_timeout,
        default=5.0,
        help="Total wall-clock deadline per endpoint attempt in seconds (default: 5)",
    )
    parser.add_argument(
        "--retries",
        type=_non_negative_int,
        default=0,
        help="Extra attempts per endpoint after the first failure (default: 0)",
    )
    parser.add_argument(
        "--retry-delay",
        type=_timeout,
        default=0.5,
        help="Delay between attempts in seconds (default: 0.5)",
    )
    parser.add_argument(
        "--metrics-path",
        default="/metrics",
        help="Metrics path to request (default: /metrics)",
    )
    args = parser.parse_args(argv)
    if not args.host:
        parser.error("--host must not be empty")
    if not args.metrics_path.startswith("/"):
        parser.error("--metrics-path must start with '/'")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    attempts = args.retries + 1

    _with_retries(
        lambda: probe_resp(args.host, args.port, args.timeout), attempts, args.retry_delay
    )
    print(f"RESP PING on {args.host}:{args.port} returned {EXPECTED_PONG}.")

    status = _with_retries(
        lambda: probe_metrics(args.host, args.metrics_port, args.timeout, args.metrics_path),
        attempts,
        args.retry_delay,
    )
    print(
        f"HTTP GET {args.metrics_path} on {args.host}:{args.metrics_port} "
        f"returned HTTP {status} with a non-empty body."
    )
    print("Host reachability verified.")
    return EXIT_OK


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ProbeError as error:
        print(f"{PROGRAM}: error: {error}", file=sys.stderr)
        raise SystemExit(error.exit_code) from error
    except KeyboardInterrupt:  # pragma: no cover - interactive interrupt
        print(f"{PROGRAM}: interrupted", file=sys.stderr)
        raise SystemExit(EXIT_USAGE) from None
