#!/usr/bin/env bash
# End-to-end coverage for the Playground image: proves the HTTP API and public
# RESP port share the real Ferrite data store, and that PID 1 shuts down and
# reaps its child without leaving a running container behind.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "  skip: docker is not installed in this environment."
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "  skip: no reachable Docker daemon in this environment."
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "  skip: curl is not installed in this environment."
  exit 0
fi

IMAGE_TAG="ferrite-ops-playground-runtime:$$"
CONTAINER_ID=""
BUILD_LOG="$(mktemp)"
RUN_LOG="$(mktemp)"

cleanup() {
  if [[ -n "$CONTAINER_ID" ]]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi
  docker image rm -f "$IMAGE_TAG" >/dev/null 2>&1 || true
  rm -f "$BUILD_LOG" "$RUN_LOG"
}
trap cleanup EXIT

resp_cmd() {
  local host="$1" port="$2"
  shift 2
  local fd line1="" line2=""
  exec {fd}<>"/dev/tcp/${host}/${port}" || return 1
  {
    printf '*%d\r\n' "$#"
    local arg
    for arg in "$@"; do
      printf '$%d\r\n%s\r\n' "${#arg}" "$arg"
    done
  } >&"${fd}"
  IFS=$'\r' read -r -t 5 line1 <&"${fd}" || true
  if [[ "$line1" == \$* ]]; then
    IFS=$'\r' read -r -t 5 line2 <&"${fd}" || true
  fi
  exec {fd}<&-
  if [[ -n "$line2" ]]; then
    printf '%s' "$line2"
  else
    printf '%s' "${line1#[-+:]}"
  fi
}

if docker build -f "${REPO_ROOT}/Dockerfile.playground" -t "$IMAGE_TAG" "$REPO_ROOT" \
  >"$BUILD_LOG" 2>&1; then
  harness_ok "exact Playground image builds"
else
  harness_fail "Playground build failed: $(tail -60 "$BUILD_LOG")"
  harness_summary
  exit $?
fi

CONTAINER_ID="$(docker run -d -P "$IMAGE_TAG" 2>>"$RUN_LOG")"
if [[ -z "$CONTAINER_ID" ]]; then
  harness_fail "Playground container failed to start: $(tail -40 "$RUN_LOG")"
  harness_summary
  exit $?
fi
harness_ok "Playground container starts with its exact entrypoint"

HTTP_PORT="$(docker port "$CONTAINER_ID" 8080/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')"
RESP_PORT="$(docker port "$CONTAINER_ID" 6379/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')"
if [[ -z "$HTTP_PORT" || -z "$RESP_PORT" ]]; then
  harness_fail "could not resolve Playground HTTP/RESP published ports"
  harness_summary
  exit $?
fi

HEALTH=""
for _ in $(seq 1 80); do
  HEALTH="$(curl -fsS --max-time 2 "http://127.0.0.1:${HTTP_PORT}/api/health" 2>/dev/null || true)"
  [[ "$HEALTH" == *'"success":true'* && "$HEALTH" == *'"resp":"PONG"'* ]] && break
  sleep 0.25
done
assert_contains "$HEALTH" '"success":true' "HTTP health succeeds only after the real RESP PING succeeds"
assert_contains "$HEALTH" '"version":"0.4.0"' "HTTP health reports the image's Ferrite version"

INDEX="$(curl -fsS --max-time 5 "http://127.0.0.1:${HTTP_PORT}/" 2>/dev/null || true)"
assert_contains "$INDEX" 'id="command-form"' "root serves an interactive command form"
assert_contains "$INDEX" 'fetch("/api/execute"' "interactive page submits commands to the JSON API"

RESP_SET="$(resp_cmd 127.0.0.1 "$RESP_PORT" SET from-resp visible-over-http 2>/dev/null || true)"
assert_eq "OK" "$RESP_SET" "data can be written through the public RESP port"

DETAIL="$(curl -fsS --max-time 5 \
  "http://127.0.0.1:${HTTP_PORT}/api/keys/detail/from-resp" 2>/dev/null || true)"
assert_contains "$DETAIL" '"key":"from-resp"' "HTTP key detail reads the key written through RESP"
assert_contains "$DETAIL" '"value":"visible-over-http"' "HTTP key detail returns the real RESP value"

HTTP_SET="$(curl -fsS --max-time 5 -X POST \
  -H 'content-type: application/json' \
  --data '{"command":"SET from-http visible-over-resp"}' \
  "http://127.0.0.1:${HTTP_PORT}/api/execute" 2>/dev/null || true)"
assert_contains "$HTTP_SET" '"success":true' "HTTP execute accepts a real SET command"
assert_contains "$HTTP_SET" '"data":"OK"' "HTTP execute returns Ferrite's real RESP result"

RESP_GET="$(resp_cmd 127.0.0.1 "$RESP_PORT" GET from-http 2>/dev/null || true)"
assert_eq "visible-over-resp" "$RESP_GET" "data written through HTTP is visible through public RESP"

CHILDREN_BEFORE="$(docker exec "$CONTAINER_ID" sh -c \
  'for stat in /proc/[0-9]*/stat; do set -- $(cat "$stat"); [ "${4:-}" = "1" ] && printf "%s\n" "${2:-}"; done' \
  2>/dev/null || true)"
assert_contains "$CHILDREN_BEFORE" "(ferrite)" "launcher PID 1 supervises a Ferrite child before shutdown"

if docker stop --time 15 "$CONTAINER_ID" >/dev/null 2>>"$RUN_LOG"; then
  harness_ok "docker stop completes within the graceful shutdown bound"
else
  harness_fail "docker stop failed: $(tail -40 "$RUN_LOG")"
fi

RUNNING="$(docker inspect --format='{{.State.Running}}' "$CONTAINER_ID" 2>/dev/null || true)"
EXIT_CODE="$(docker inspect --format='{{.State.ExitCode}}' "$CONTAINER_ID" 2>/dev/null || true)"
assert_eq "false" "$RUNNING" "Playground container is not left running after SIGTERM"
assert_eq "0" "$EXIT_CODE" "launcher PID 1 exits cleanly after reaping Ferrite"

if docker top "$CONTAINER_ID" >/dev/null 2>&1; then
  harness_fail "stopped Playground container still reports live processes"
else
  harness_ok "no child process remains in the stopped container"
fi

harness_summary
