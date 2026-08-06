#!/usr/bin/env bash
# Host reachability tests for scripts/tester-host-probe.py and the
# `tester.sh start` integration that depends on it.
#
# Reachability is deliberately NOT tested through the fake `docker` fixture:
# a fake Docker can only prove which commands were invoked, never that the
# published loopback ports actually answer. These tests therefore run real
# loopback servers (tests/fixtures/fake_host_services.py) that speak, or
# deliberately mis-speak, RESP and HTTP.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"
# shellcheck source=tests/lib/host_services.sh
source "${HERE}/lib/host_services.sh"

PROBE="${REPO_ROOT}/scripts/tester-host-probe.py"
TESTER="${REPO_ROOT}/scripts/tester.sh"
SERVICES="${HERE}/fixtures/fake_host_services.py"

if [[ ! -f "$SERVICES" ]]; then
  echo "  FAIL: ${SERVICES} not found" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "  FAIL: python3 is required to test the host reachability probe" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"

cleanup() {
  host_services_stop
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

start_fake_services() {
  host_services_start "$@" || harness_fail "fake host services ($1/$2) failed to start"
}

run_probe() {
  python3 "$PROBE" \
    --port "$RESP_PORT" \
    --metrics-port "$METRICS_PORT" \
    --timeout 1 \
    --retries 0 2>&1
}

assert_nonzero() {
  local status="$1" description="$2"
  if [[ "$status" -ne 0 ]]; then
    harness_ok "$description"
  else
    harness_fail "$description"
  fi
}

assert_true "$(python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PROBE"; echo $?)" \
  "tester-host-probe.py is syntactically valid Python 3"

# The probe must not require anything beyond the standard library, because a
# tester is only asked to install Docker and Python 3.
IMPORTS="$(python3 - "$PROBE" <<'PYIMPORTS'
import ast
import sys

tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
modules = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        modules.update(alias.name.split(".")[0] for alias in node.names)
    elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
        modules.add(node.module.split(".")[0])
print(" ".join(sorted(modules)))
PYIMPORTS
)"
NON_STDLIB=""
for module in $IMPORTS; do
  case "$module" in
    __future__ | argparse | errno | http | socket | sys | time) ;;
    *) NON_STDLIB+="${module} " ;;
  esac
done
assert_eq "" "$NON_STDLIB" "probe imports only Python standard library modules"

# --- Argument validation happens before any connection is attempted. -------

OUTPUT="$(python3 "$PROBE" --port 0 --metrics-port 9090 2>&1)"
assert_nonzero $? "probe rejects an out-of-range port"
assert_contains "$OUTPUT" "port must be between 1 and 65535" "port rejection is actionable"

OUTPUT="$(python3 "$PROBE" --port 6379 --metrics-port not-a-port 2>&1)"
assert_nonzero $? "probe rejects a non-numeric metrics port"

OUTPUT="$(python3 "$PROBE" --port 6379 --metrics-port 9090 --timeout 0 2>&1)"
assert_nonzero $? "probe rejects a zero timeout"
assert_contains "$OUTPUT" "timeout must be between" "timeout rejection names the bounds"

OUTPUT="$(python3 "$PROBE" --port 6379 --metrics-port 9090 --timeout 1000 2>&1)"
assert_nonzero $? "probe rejects an unbounded timeout"

OUTPUT="$(python3 "$PROBE" --port 6379 2>&1)"
assert_nonzero $? "probe requires the metrics port"

OUTPUT="$(python3 "$PROBE" --port 6379 --metrics-port 9090 --metrics-path metrics 2>&1)"
assert_nonzero $? "probe rejects a metrics path without a leading slash"

# --- Happy path -----------------------------------------------------------

start_fake_services pong ok
OUTPUT="$(run_probe)"
STATUS=$?
assert_eq 0 "$STATUS" "probe succeeds against a RESP +PONG and a non-empty 200 /metrics"
assert_contains "$OUTPUT" "returned +PONG" "probe reports the RESP result"
assert_contains "$OUTPUT" "non-empty body" "probe reports the metrics result"
assert_contains "$OUTPUT" "Host reachability verified" "probe states the overall conclusion"

# --- RESP failure modes ---------------------------------------------------

start_fake_services error ok
OUTPUT="$(run_probe)"
STATUS=$?
assert_nonzero "$STATUS" "probe fails when PING returns a RESP error"
assert_contains "$OUTPUT" "expected '+PONG'" "RESP error failure names the expected reply"

start_fake_services garbage ok
OUTPUT="$(run_probe)"
STATUS=$?
assert_nonzero "$STATUS" "probe fails when the port serves a non-RESP protocol"
assert_contains "$OUTPUT" "expected '+PONG'" "non-RESP failure names the expected reply"

start_fake_services close ok
OUTPUT="$(run_probe)"
STATUS=$?
assert_nonzero "$STATUS" "probe fails when the RESP port closes without replying"
assert_contains "$OUTPUT" "closed the connection before replying" "closed-connection failure is actionable"

start_fake_services hang ok
START_SECONDS=$SECONDS
OUTPUT="$(run_probe)"
STATUS=$?
ELAPSED=$((SECONDS - START_SECONDS))
assert_nonzero "$STATUS" "probe fails when the RESP port never replies"
assert_contains "$OUTPUT" "timed out" "silent-server failure explains the timeout"
if ((ELAPSED <= 10)); then
  harness_ok "silent RESP server probe is bounded by the timeout (${ELAPSED}s)"
else
  harness_fail "silent RESP server probe is bounded by the timeout (took ${ELAPSED}s)"
fi

start_fake_services none ok
OUTPUT="$(run_probe)"
STATUS=$?
assert_nonzero "$STATUS" "probe fails when nothing listens on the Redis-compatible port"
assert_contains "$OUTPUT" "nothing is accepting connections" "refused-connection failure is actionable"
assert_contains "$OUTPUT" "tester.sh start" "refused-connection failure names the remedy"

# --- Metrics failure modes ------------------------------------------------

start_fake_services pong empty
OUTPUT="$(run_probe)"
STATUS=$?
assert_nonzero "$STATUS" "probe fails when /metrics returns an empty body"
assert_contains "$OUTPUT" "empty" "empty-metrics failure is actionable"

start_fake_services pong error
OUTPUT="$(run_probe)"
STATUS=$?
assert_nonzero "$STATUS" "probe fails when /metrics returns HTTP 500"
assert_contains "$OUTPUT" "returned HTTP 500" "5xx metrics failure names the status"

start_fake_services pong notfound
OUTPUT="$(run_probe)"
STATUS=$?
assert_nonzero "$STATUS" "probe fails when /metrics returns HTTP 404"
assert_contains "$OUTPUT" "returned HTTP 404" "404 metrics failure names the status"

start_fake_services pong hang
START_SECONDS=$SECONDS
OUTPUT="$(run_probe)"
STATUS=$?
ELAPSED=$((SECONDS - START_SECONDS))
assert_nonzero "$STATUS" "probe fails when /metrics never responds"
assert_contains "$OUTPUT" "timed out" "hanging metrics failure explains the timeout"
if ((ELAPSED <= 10)); then
  harness_ok "hanging metrics probe is bounded by the timeout (${ELAPSED}s)"
else
  harness_fail "hanging metrics probe is bounded by the timeout (took ${ELAPSED}s)"
fi

# Each body byte arrives within the socket timeout, but the complete response
# exceeds one total attempt deadline. A per-read timeout would incorrectly
# allow this response to run to completion.
start_fake_services pong drip
START_SECONDS=$SECONDS
OUTPUT="$(
  python3 "$PROBE" \
    --port "$RESP_PORT" \
    --metrics-port "$METRICS_PORT" \
    --timeout 0.5 \
    --retries 0 2>&1
)"
STATUS=$?
ELAPSED=$((SECONDS - START_SECONDS))
assert_nonzero "$STATUS" "probe rejects a slow-drip metrics body after the total deadline"
assert_contains "$OUTPUT" "total deadline expired while reading" "slow-drip failure identifies the total body deadline"
if ((ELAPSED <= 2)); then
  harness_ok "slow-drip metrics probe obeys one total deadline (${ELAPSED}s)"
else
  harness_fail "slow-drip metrics probe obeys one total deadline (took ${ELAPSED}s)"
fi

start_fake_services pong none
OUTPUT="$(run_probe)"
STATUS=$?
assert_nonzero "$STATUS" "probe fails when nothing listens on the metrics port"
assert_contains "$OUTPUT" "nothing is accepting connections" "refused metrics connection is actionable"

# A RESP failure must be reported even when metrics are healthy, and the
# probe must not claim success from a single healthy endpoint.
start_fake_services none ok
OUTPUT="$(run_probe)"
assert_not_contains "$OUTPUT" "Host reachability verified" "probe never claims success when RESP fails"

start_fake_services pong none
OUTPUT="$(run_probe)"
assert_not_contains "$OUTPUT" "Host reachability verified" "probe never claims success when metrics fail"

# --- tester.sh start integration -----------------------------------------
#
# The fake `docker` fixture makes the container appear healthy and correctly
# imaged; reachability is still decided by the real loopback servers above.

"${HERE}/fixtures/make_fake_docker.sh" "${WORK_DIR}/bin"
FAKE_LOG="${WORK_DIR}/docker.log"
FAKE_STATE="${WORK_DIR}/state"
touch "$FAKE_LOG"
mkdir -p "$FAKE_STATE"
FAKE_IMAGE="ghcr.io/ferritelabs/ferrite@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

run_start() {
  env \
    PATH="${WORK_DIR}/bin:${PATH}" \
    FAKE_DOCKER_LOG="$FAKE_LOG" \
    FAKE_DOCKER_STATE="$FAKE_STATE" \
    FERRITE_TEST_POLL_INTERVAL="0.05" \
    FERRITE_TEST_IMAGE="$FAKE_IMAGE" \
    FERRITE_TEST_PORT="$RESP_PORT" \
    FERRITE_TEST_METRICS_PORT="$METRICS_PORT" \
    FERRITE_TEST_PROBE_TIMEOUT=1 \
    FERRITE_TEST_PROBE_RETRIES=0 \
    "$@" 2>&1
}

start_fake_services pong ok
: >"$FAKE_LOG"
OUTPUT="$(run_start bash "$TESTER" start)"
STATUS=$?
assert_eq 0 "$STATUS" "start succeeds when the host can actually reach both ports"
assert_contains "$OUTPUT" "RESP PING on 127.0.0.1:${RESP_PORT} returned +PONG" "start probes the Redis-compatible port from the host"
assert_contains "$OUTPUT" "returned HTTP 200 with a non-empty body" "start probes /metrics from the host"
assert_contains "$OUTPUT" "Ferrite is available on localhost:${RESP_PORT}" "start claims availability only after the probe passes"

start_fake_services none ok
: >"$FAKE_LOG"
OUTPUT="$(run_start bash "$TESTER" start)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_nonzero "$STATUS" "start fails when the Redis-compatible port is unreachable from the host"
assert_contains "$OUTPUT" "NOT reachable from this host" "unreachable start failure is actionable"
assert_not_contains "$OUTPUT" "Ferrite is available on localhost" "start never claims localhost availability when unreachable"
assert_contains "$CALLS" ".Config.Image" "host reachability runs after container health and image verification"

start_fake_services pong none
: >"$FAKE_LOG"
OUTPUT="$(run_start bash "$TESTER" start)"
STATUS=$?
assert_nonzero "$STATUS" "start fails when the metrics port is unreachable from the host"
assert_not_contains "$OUTPUT" "Ferrite is available on localhost" "start never claims availability when metrics are unreachable"

start_fake_services pong error
: >"$FAKE_LOG"
OUTPUT="$(run_start bash "$TESTER" start)"
STATUS=$?
assert_nonzero "$STATUS" "start fails when /metrics returns a non-2xx status"
assert_contains "$OUTPUT" "returned HTTP 500" "start surfaces the exact metrics status"

# python3 is a hard requirement for `start`, and its absence must fail before
# any Docker call rather than silently skipping reachability verification.
start_fake_services pong ok
: >"$FAKE_LOG"
OUTPUT="$(run_start FERRITE_TEST_PYTHON="${WORK_DIR}/definitely-not-python" bash "$TESTER" start)"
STATUS=$?
assert_nonzero "$STATUS" "start fails when python3 is unavailable"
assert_contains "$OUTPUT" "Python 3 is required" "missing-python failure is actionable"
if [[ ! -s "$FAKE_LOG" ]]; then
  harness_ok "missing-python rejection occurs before any Docker call"
else
  harness_fail "missing-python rejection occurs before any Docker call"
fi

# A probe script missing from the checkout must fail start, not be skipped.
INCOMPLETE_ROOT="${WORK_DIR}/incomplete"
mkdir -p "${INCOMPLETE_ROOT}/scripts"
cp "$TESTER" "${INCOMPLETE_ROOT}/scripts/tester.sh"
cp "${REPO_ROOT}/docker-compose.tester.yml" "${INCOMPLETE_ROOT}/"
start_fake_services pong ok
: >"$FAKE_LOG"
OUTPUT="$(run_start bash "${INCOMPLETE_ROOT}/scripts/tester.sh" start)"
STATUS=$?
assert_nonzero "$STATUS" "start fails when the host reachability probe is missing from the checkout"
assert_contains "$OUTPUT" "host reachability probe is missing" "missing-probe failure is actionable"

# Invalid probe settings are rejected by validation, before any Docker call.
: >"$FAKE_LOG"
OUTPUT="$(run_start FERRITE_TEST_PROBE_TIMEOUT=0 bash "$TESTER" start)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects an out-of-range probe timeout"
assert_contains "$OUTPUT" "FERRITE_TEST_PROBE_TIMEOUT" "probe timeout rejection names the variable"

: >"$FAKE_LOG"
OUTPUT="$(run_start FERRITE_TEST_PROBE_RETRIES=abc bash "$TESTER" start)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a non-numeric probe retry count"
assert_contains "$OUTPUT" "FERRITE_TEST_PROBE_RETRIES" "probe retry rejection names the variable"

host_services_stop
harness_summary
