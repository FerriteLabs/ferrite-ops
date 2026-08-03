#!/usr/bin/env bash
# End-to-end coverage for the Playground image: proves the HTTP API and public
# RESP port share the real Ferrite data store, and that PID 1 shuts down and
# reaps its child without leaving a running container behind.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
ACTIVE_RELEASE="${REPO_ROOT}/active-release.env"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

EXPECTED_VERSION="$(sed -n 's/^FERRITE_VERSION=//p' "$ACTIVE_RELEASE")"

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
assert_contains "$HEALTH" "\"version\":\"${EXPECTED_VERSION}\"" \
  "HTTP health reports the active Ferrite version"

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

# --- RESP3 compatibility ------------------------------------------------------
# Clients may negotiate RESP3 with HELLO 3 on the public port; the launcher's
# proxy must decode and forward RESP3 replies unchanged rather than breaking
# the connection.
resp3_session() {
  local host="$1" port="$2" fd line output=""
  exec {fd}<>"/dev/tcp/${host}/${port}" || return 1
  {
    printf '*2\r\n$5\r\nHELLO\r\n$1\r\n3\r\n'
    printf '*3\r\n$3\r\nSET\r\n$9\r\nresp3-key\r\n$10\r\nresp3-val!\r\n'
    printf '*2\r\n$3\r\nGET\r\n$9\r\nresp3-key\r\n'
  } >&"${fd}"
  while IFS= read -r -t 5 line <&"${fd}"; do
    output+="${line}"$'\n'
    [[ "$line" == *"resp3-val!"* ]] && break
  done
  exec {fd}<&-
  printf '%s' "$output"
}

RESP3_OUTPUT="$(resp3_session 127.0.0.1 "$RESP_PORT" 2>/dev/null | tr -d '\r' || true)"
assert_contains "$RESP3_OUTPUT" "proto" "HELLO 3 is forwarded and its RESP3 map reply reaches the client"
assert_contains "$RESP3_OUTPUT" "resp3-val!" "ordinary commands still work after a RESP3 handshake"
assert_not_contains "$RESP3_OUTPUT" "playground backend error" "RESP3 replies do not break the proxy"

# --- Bounded key detail ------------------------------------------------------
# A list far larger than one page must return a bounded page plus honest
# total/truncation metadata rather than the whole collection.
for index in $(seq 1 150); do
  resp_cmd 127.0.0.1 "$RESP_PORT" RPUSH bounded-list "item-${index}" >/dev/null 2>&1 || true
done
LIST_DETAIL="$(curl -fsS --max-time 10 \
  "http://127.0.0.1:${HTTP_PORT}/api/keys/detail/bounded-list" 2>/dev/null || true)"
assert_contains "$LIST_DETAIL" '"length":150' "key detail reports the real list total"
assert_contains "$LIST_DETAIL" '"returned":100' "key detail returns at most one bounded page"
assert_contains "$LIST_DETAIL" '"truncated":true' "key detail reports truncation"
assert_not_contains "$LIST_DETAIL" 'item-150' "key detail does not return the whole list"

for index in $(seq 1 150); do
  resp_cmd 127.0.0.1 "$RESP_PORT" HSET bounded-hash "field-${index}" "value-${index}" >/dev/null 2>&1 || true
done
HASH_DETAIL="$(curl -fsS --max-time 10 \
  "http://127.0.0.1:${HTTP_PORT}/api/keys/detail/bounded-hash" 2>/dev/null || true)"
assert_contains "$HASH_DETAIL" '"length":150' "hash key detail reports the real total"
assert_contains "$HASH_DETAIL" '"returned":0' "hash key detail does not enumerate fields"
assert_contains "$HASH_DETAIL" '"value_omitted":true' "hash key detail marks its value as omitted"
assert_contains "$HASH_DETAIL" 'HSCAN is not effectively bounded' \
  "hash key detail explains why enumeration is omitted"

# --- Playground lifecycle/admin policy -------------------------------------
# The public RESP port is owned by the launcher's proxy, not by Ferrite, so
# administrative/lifecycle commands must be refused on both entry points while
# ordinary Redis-compatible commands keep working and the child stays alive.
HTTP_SHUTDOWN="$(curl -s --max-time 5 -o /dev/stdout -w '\n%{http_code}' -X POST \
  -H 'content-type: application/json' \
  --data '{"command":"SHUTDOWN"}' \
  "http://127.0.0.1:${HTTP_PORT}/api/execute" 2>/dev/null || true)"
assert_contains "$HTTP_SHUTDOWN" '403' "HTTP execute refuses SHUTDOWN with a 403"
assert_contains "$HTTP_SHUTDOWN" '"success":false' "HTTP SHUTDOWN is reported as a failure"
assert_contains "$HTTP_SHUTDOWN" 'playground' "HTTP SHUTDOWN rejection explains the playground policy"

for admin_command in DEBUG CONFIG MODULE ACL SAVE BGSAVE BGREWRITEAOF REPLICAOF; do
  ADMIN_REPLY="$(curl -s --max-time 5 -X POST -H 'content-type: application/json' \
    --data "{\"command\":\"${admin_command} HELP\"}" \
    "http://127.0.0.1:${HTTP_PORT}/api/execute" 2>/dev/null || true)"
  assert_contains "$ADMIN_REPLY" '"success":false' \
    "HTTP execute refuses the administrative command ${admin_command}"
done

for rejected_command in \
  "PLUGIN LIST" \
  "AUDIT START" \
  "MIGRATE.START redis://example.invalid" \
  "LRANGE bounded-list 0 -1" \
  "XRANGE stream - +" \
  "COPY source destination DB 16" \
  "XTRIM stream MAXLEN =" \
  "XTRIM stream MAXLEN 100 LIMIT 10" \
  "XADD stream MAXLEN = 100 LIMIT 10 * field value" \
  "XADD stream 18446744073709551615-18446744073709551615 field value" \
  "SETBIT bitmap 4294967288 1" \
  "SCAN 0 COUNT 100" \
  "SSCAN set 0 COUNT 100" \
  "HSCAN bounded-hash 0 COUNT 100" \
  "ZSCAN zset 0 COUNT 100" \
  "XREAD COUNT 10 STREAMS stream 0-0" \
  "XREAD STREAMS COUNT 10 stream 0-0" \
  "XREADGROUP GROUP group consumer COUNT 10 STREAMS stream >"; do
  REJECTED_REPLY="$(curl -s --max-time 5 -X POST -H 'content-type: application/json' \
    --data "{\"command\":\"${rejected_command}\"}" \
    "http://127.0.0.1:${HTTP_PORT}/api/execute" 2>/dev/null || true)"
  assert_contains "$REJECTED_REPLY" '"success":false' \
    "HTTP execute rejects ${rejected_command} before forwarding"
done

RESP_SHUTDOWN="$(resp_cmd 127.0.0.1 "$RESP_PORT" SHUTDOWN NOSAVE 2>/dev/null || true)"
assert_contains "$RESP_SHUTDOWN" "playground" "public RESP port refuses SHUTDOWN with a policy error"

RESP_CONFIG="$(resp_cmd 127.0.0.1 "$RESP_PORT" CONFIG SET appendonly yes 2>/dev/null || true)"
assert_contains "$RESP_CONFIG" "playground" "public RESP port refuses CONFIG SET"

for rejected_command in \
  "PLUGIN LIST" \
  "AUDIT START" \
  "MIGRATE.START redis://example.invalid" \
  "LRANGE bounded-list 0 -1" \
  "XRANGE stream - +" \
  "COPY source destination DB 16" \
  "XTRIM stream MAXLEN =" \
  "XTRIM stream MAXLEN 100 LIMIT 10" \
  "XADD stream MAXLEN = 100 LIMIT 10 * field value" \
  "XADD stream 18446744073709551615-18446744073709551615 field value" \
  "SETBIT bitmap 4294967288 1" \
  "SCAN 0 COUNT 100" \
  "SSCAN set 0 COUNT 100" \
  "HSCAN bounded-hash 0 COUNT 100" \
  "ZSCAN zset 0 COUNT 100" \
  "XREAD COUNT 10 STREAMS stream 0-0" \
  "XREAD STREAMS COUNT 10 stream 0-0" \
  "XREADGROUP GROUP group consumer COUNT 10 STREAMS stream >"; do
  read -r -a rejected_arguments <<<"$rejected_command"
  REJECTED_REPLY="$(resp_cmd 127.0.0.1 "$RESP_PORT" "${rejected_arguments[@]}" 2>/dev/null || true)"
  assert_contains "$REJECTED_REPLY" "playground" \
    "public RESP port rejects ${rejected_command} before forwarding"
done

sleep 1
STILL_RUNNING="$(docker inspect --format='{{.State.Running}}' "$CONTAINER_ID" 2>/dev/null || true)"
assert_eq "true" "$STILL_RUNNING" "container survives unauthenticated SHUTDOWN attempts"

RESP_PING_AFTER="$(resp_cmd 127.0.0.1 "$RESP_PORT" PING 2>/dev/null || true)"
assert_eq "PONG" "$RESP_PING_AFTER" "public RESP port still serves ordinary commands after refusals"

RESP_SET_AFTER="$(resp_cmd 127.0.0.1 "$RESP_PORT" SET after-shutdown-attempt still-alive 2>/dev/null || true)"
assert_eq "OK" "$RESP_SET_AFTER" "SET works through the public RESP port after refusals"
RESP_GET_AFTER="$(resp_cmd 127.0.0.1 "$RESP_PORT" GET after-shutdown-attempt 2>/dev/null || true)"
assert_eq "still-alive" "$RESP_GET_AFTER" "GET works through the public RESP port after refusals"

HTTP_SET_AFTER="$(curl -fsS --max-time 5 -X POST -H 'content-type: application/json' \
  --data '{"command":"SET http-after-shutdown still-alive"}' \
  "http://127.0.0.1:${HTTP_PORT}/api/execute" 2>/dev/null || true)"
assert_contains "$HTTP_SET_AFTER" '"data":"OK"' "SET works through HTTP after refusals"
HTTP_GET_AFTER="$(curl -fsS --max-time 5 -X POST -H 'content-type: application/json' \
  --data '{"command":"GET http-after-shutdown"}' \
  "http://127.0.0.1:${HTTP_PORT}/api/execute" 2>/dev/null || true)"
assert_contains "$HTTP_GET_AFTER" '"data":"still-alive"' "GET works through HTTP after refusals"

# The Ferrite child must listen on the internal loopback port only; the
# public port belongs to the launcher's policy-enforcing proxy.
CHILD_CMDLINE="$(docker exec "$CONTAINER_ID" sh -c \
  'for cmd in /proc/[0-9]*/cmdline; do tr "\0" " " < "$cmd"; echo; done' 2>/dev/null || true)"
assert_contains "$CHILD_CMDLINE" "--bind 127.0.0.1 --port 6380" \
  "Ferrite child is spawned on the internal loopback port 6380"
assert_not_contains "$CHILD_CMDLINE" "--bind 0.0.0.0" \
  "Ferrite child is never bound directly to a public address"

CHILDREN_BEFORE="$(docker exec "$CONTAINER_ID" sh -c \
  'for stat in /proc/[0-9]*/stat; do set -- $(cat "$stat"); [ "${4:-}" = "1" ] && printf "%s\n" "${2:-}"; done' \
  2>/dev/null || true)"
assert_contains "$CHILDREN_BEFORE" "(ferrite)" "launcher PID 1 supervises a Ferrite child before shutdown"

STOP_STARTED="$(date +%s)"
if docker stop "$CONTAINER_ID" >/dev/null 2>>"$RUN_LOG"; then
  STOP_ELAPSED=$(( $(date +%s) - STOP_STARTED ))
  if [[ "$STOP_ELAPSED" -lt 10 ]]; then
    harness_ok "plain docker stop completes before Docker's default SIGKILL deadline"
  else
    harness_fail "plain docker stop took ${STOP_ELAPSED}s (expected less than 10s)"
  fi
else
  harness_fail "plain docker stop failed: $(tail -40 "$RUN_LOG")"
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
