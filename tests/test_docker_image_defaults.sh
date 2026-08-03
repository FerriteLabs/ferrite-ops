#!/usr/bin/env bash
# Regression test for F-17/D-03's resolution: builds the exact default
# primary image (the same `docker build -t ferrite:test .` command CI runs,
# no --build-arg overrides) and runs it with its exact default ENTRYPOINT
# and CMD — no `-v`/`--config` mount, no config substitution of any kind —
# then proves the baked-in config the image ships with actually starts the
# real server and is reachable through Docker's published-port mapping.
#
# Unlike tests/test_docker_build.sh (which intentionally scopes down to the
# cheap `source` stage to keep this file fast to run) and
# tests/test_docker_runtime_config.sh (which now also depends on the full
# `builder` stage, per the F-17 fix below), this test deliberately builds
# and runs the complete default image: the specific defect this test
# guards against (the packaged runtime config isn't loadable / the
# container isn't reachable with zero mounts/overrides) can only be caught
# by exercising the real, unmodified default end to end. Docker's build
# cache keeps repeat runs fast in practice (the Rust compile is only ever
# redone when source/build-stage inputs actually change).
#
# Background: end-to-end verification for this audit found the packaged
# ferrite.example.toml is not actually loadable by the real v0.3.0 binary
# (`max_memory = "1GB"` is a quoted string where the parser wants a raw
# byte count; `eviction_policy = "noeviction"` isn't the accepted
# hyphenated value) — see AUDIT.md F-17. The fix generates the image's
# baked-in config with the exact freshly built `ferrite` binary itself
# (`ferrite init --minimal`) instead of packaging the example verbatim, so
# this test's job is to prove that resolution holds for the real, complete
# image a user actually pulls and runs.
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

IMAGE_TAG="ferrite-ops-test-image-defaults:$$"
CONTAINER_ID=""
BUILD_LOG="$(mktemp)"
RUN_LOG="$(mktemp)"

# Deterministic cleanup: always tears down the exact container ID this run
# created (never a name- or pattern-based kill) and the exact image tag
# this run built, regardless of where the script exits.
cleanup() {
  if [[ -n "$CONTAINER_ID" ]]; then
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi
  docker image rm -f "$IMAGE_TAG" >/dev/null 2>&1 || true
  rm -f "$BUILD_LOG" "$RUN_LOG"
}
trap cleanup EXIT

# --- Build the exact default image (no --build-arg overrides at all). -----
if docker build -t "$IMAGE_TAG" "$REPO_ROOT" >"$BUILD_LOG" 2>&1; then
  harness_ok "docker build -t <image> . succeeds with zero build-arg overrides (exact CI defaults)"
else
  harness_fail "docker build failed: $(tail -40 "$BUILD_LOG")"
  harness_summary
  exit $?
fi

# --- Run with exact default ENTRYPOINT/CMD: no -v, no --config, no env
#     overrides of bind/port. -P publishes both EXPOSEd ports to random
#     free host ports so this never collides with a port already in use.
CONTAINER_ID="$(docker run -d -P "$IMAGE_TAG" 2>>"$RUN_LOG")"
if [[ -n "$CONTAINER_ID" ]]; then
  harness_ok "docker run -d -P starts a container from the exact default image (no mounted/substituted config)"
else
  harness_fail "docker run failed to start a container: $(tail -40 "$RUN_LOG")"
  harness_summary
  exit $?
fi

REDIS_PORT="$(docker port "$CONTAINER_ID" 6379/tcp 2>/dev/null | head -1 | cut -d: -f2)"
METRICS_PORT="$(docker port "$CONTAINER_ID" 9090/tcp 2>/dev/null | head -1 | cut -d: -f2)"

if [[ -z "$REDIS_PORT" || -z "$METRICS_PORT" ]]; then
  harness_fail "could not resolve published host ports for container ${CONTAINER_ID}"
  harness_summary
  exit $?
fi

# --- Minimal, dependency-free RESP client (bash's built-in /dev/tcp) so
#     this test doesn't require redis-cli/ferrite-cli to be installed on
#     the host running tests/run.sh — matching this repo's no-third-party-
#     framework policy for tests/.
# Usage: resp_cmd <host> <port> <arg>...
# Prints the raw reply (CRLF-stripped) it received within the timeout.
# Returns non-zero if the TCP connection itself failed. Writes the RESP
# array directly to the socket fd with printf (never through a
# command-substitution helper): $(...) strips trailing newlines, which
# would silently truncate the mandatory trailing "\r\n" off the last
# argument and hang the server waiting for a terminator that never
# arrives - a real bug caught while developing this test.
resp_cmd() {
  local host="$1" port="$2"
  shift 2
  local fd
  exec {fd}<>"/dev/tcp/${host}/${port}" || return 1
  {
    printf '*%d\r\n' "$#"
    local arg
    for arg in "$@"; do
      printf '$%d\r\n%s\r\n' "${#arg}" "$arg"
    done
  } >&"${fd}"
  local line1="" line2=""
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

# Bounded readiness loop (mirrors scripts/smoke_test.sh's own PING retry
# pattern): up to 40 attempts / 10s for the real compiled server to finish
# starting up and accept the published port's forwarded connections.
PING_REPLY=""
for _ in $(seq 1 40); do
  PING_REPLY="$(resp_cmd 127.0.0.1 "$REDIS_PORT" PING 2>/dev/null || true)"
  [[ "$PING_REPLY" == "PONG" ]] && break
  sleep 0.25
done
assert_eq "PONG" "$PING_REPLY" \
  "default image responds PONG to PING on its published port with zero config overrides"

SET_REPLY="$(resp_cmd 127.0.0.1 "$REDIS_PORT" SET ferrite-ops-regression-key hello-ferrite 2>/dev/null || true)"
assert_eq "OK" "$SET_REPLY" "SET via the published port succeeds against the baked-in default config"

GET_REPLY="$(resp_cmd 127.0.0.1 "$REDIS_PORT" GET ferrite-ops-regression-key 2>/dev/null || true)"
assert_eq "hello-ferrite" "$GET_REPLY" "GET via the published port returns the value written by SET"

# Metrics: assert TCP reachability of the published metrics port. This is
# what F-13's bind-address fix concerns (the port accepting external
# connections at all through Docker's port mapping); an empty HTTP response
# body from the real v0.3.0 binary's metrics endpoint is a separate,
# pre-existing, out-of-scope behavior documented in AUDIT.md and is not
# asserted here.
if timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${METRICS_PORT}" 2>/dev/null; then
  harness_ok "metrics port is TCP-reachable on its published random host port"
else
  harness_fail "metrics port ${METRICS_PORT} was not TCP-reachable"
fi

# The healthcheck baked into the image (ferrite-cli PING) must also pass
# using nothing but the image's own defaults. The Dockerfile's HEALTHCHECK
# uses --interval=15s --start-period=5s, so Docker's first probe typically
# lands around 15s after container start (observed empirically); the
# bound below (up to 45s) gives at least two full intervals of headroom
# rather than a value tuned to the exact minimum observed.
HEALTH_OK=0
for _ in $(seq 1 90); do
  STATUS="$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_ID" 2>/dev/null || true)"
  if [[ "$STATUS" == "healthy" ]]; then
    HEALTH_OK=1
    break
  fi
  sleep 0.5
done
assert_eq "1" "$HEALTH_OK" "container's own HEALTHCHECK (ferrite-cli PING) reports healthy"

harness_summary
