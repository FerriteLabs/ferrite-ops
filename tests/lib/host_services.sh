#!/usr/bin/env bash
# Shared helpers for running the scripted loopback RESP/HTTP fixture
# (tests/fixtures/fake_host_services.py).
#
# Host reachability cannot be proven with a fake `docker` binary, so tests
# that exercise `tester.sh start` (or the probe directly) run real servers on
# loopback ephemeral ports. Sourcing this file exposes:
#
#   host_services_start <resp-mode> <http-mode>   sets RESP_PORT/METRICS_PORT
#   host_services_stop                            terminates the fixture
#
# Callers are responsible for calling host_services_stop from their EXIT trap.

HOST_SERVICES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_SERVICES_FIXTURE="${HOST_SERVICES_LIB_DIR}/../fixtures/fake_host_services.py"
HOST_SERVICES_PID=""
RESP_PORT=""
METRICS_PORT=""

host_services_stop() {
  if [[ -n "$HOST_SERVICES_PID" ]]; then
    kill "$HOST_SERVICES_PID" >/dev/null 2>&1 || true
    wait "$HOST_SERVICES_PID" 2>/dev/null || true
    HOST_SERVICES_PID=""
  fi
}

# Starts the fixture and publishes its ephemeral ports into RESP_PORT and
# METRICS_PORT. The fixture writes the port file atomically, so polling for a
# non-empty file can never observe a partially written value.
host_services_start() {
  local resp_mode="$1" http_mode="$2" port_file attempt
  host_services_stop

  if [[ ! -f "$HOST_SERVICES_FIXTURE" ]]; then
    echo "  FAIL: host services fixture missing at ${HOST_SERVICES_FIXTURE}" >&2
    return 1
  fi

  port_file="$(mktemp)"
  : >"$port_file"

  python3 "$HOST_SERVICES_FIXTURE" \
    --resp-mode "$resp_mode" \
    --http-mode "$http_mode" \
    --port-file "$port_file" &
  HOST_SERVICES_PID=$!

  for ((attempt = 0; attempt < 200; attempt++)); do
    [[ -s "$port_file" ]] && break
    sleep 0.05
  done

  RESP_PORT="$(sed -n 's/^resp_port=//p' "$port_file")"
  METRICS_PORT="$(sed -n 's/^http_port=//p' "$port_file")"
  rm -f "$port_file"

  if [[ ! "$RESP_PORT" =~ ^[0-9]+$ || ! "$METRICS_PORT" =~ ^[0-9]+$ ]]; then
    echo "  FAIL: fake host services (${resp_mode}/${http_mode}) failed to publish ports" >&2
    host_services_stop
    return 1
  fi
}
