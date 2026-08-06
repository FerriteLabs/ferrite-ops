#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck disable=SC1091
source "${HERE}/lib/harness.sh"

COMPOSE_FILE="${REPO_ROOT}/docker-compose.tester.yml"
CONTENT="$(cat "$COMPOSE_FILE")"

assert_contains "$CONTENT" "\${FERRITE_TEST_IMAGE:?" "tester image is a required variable with no default"
assert_not_contains "$CONTENT" "\${FERRITE_TEST_IMAGE:-" "tester image must not silently default to any baseline"
assert_contains "$CONTENT" "\${FERRITE_TEST_PORT:-6379}" "Redis-compatible host port is configurable"
assert_contains "$CONTENT" "\${FERRITE_TEST_METRICS_PORT:-9090}" "metrics host port is configurable"
assert_contains "$CONTENT" "127.0.0.1:\${FERRITE_TEST_PORT:-6379}" "Redis-compatible port is bound to loopback only"
assert_contains "$CONTENT" "127.0.0.1:\${FERRITE_TEST_METRICS_PORT:-9090}" "metrics port is bound to loopback only"
assert_contains "$CONTENT" 'ferrite-tester-data:/var/lib/ferrite/data' "tester Compose uses a named data volume"
assert_contains "$CONTENT" 'test: ["CMD", "ferrite-cli", "PING"]' "healthcheck uses ferrite-cli"
assert_contains "$CONTENT" "resources:" "tester Compose declares conservative resource defaults"
assert_not_contains "$CONTENT" "container_name:" "tester Compose leaves container naming project-scoped"
assert_not_contains "$CONTENT" "build:" "tester Compose never builds from local context"
assert_not_contains "$CONTENT" "ferrite:latest" "tester Compose never defaults to latest"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  # Missing FERRITE_TEST_IMAGE must fail config rendering itself, before any
  # other Docker call, since the variable has no default.
  MISSING_OUTPUT="$(
    env -u FERRITE_TEST_IMAGE \
    FERRITE_TEST_PORT=16379 \
    FERRITE_TEST_METRICS_PORT=19090 \
      docker compose -f "$COMPOSE_FILE" config 2>&1
  )"
  MISSING_STATUS=$?
  if [[ "$MISSING_STATUS" -ne 0 ]]; then
    harness_ok "docker compose config fails when FERRITE_TEST_IMAGE is unset"
  else
    harness_fail "docker compose config fails when FERRITE_TEST_IMAGE is unset"
  fi
  assert_contains "$MISSING_OUTPUT" "FERRITE_TEST_IMAGE" "missing-variable error names FERRITE_TEST_IMAGE"

  RENDERED="$(
    FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    FERRITE_TEST_PORT=16379 \
    FERRITE_TEST_METRICS_PORT=19090 \
      docker compose -f "$COMPOSE_FILE" config 2>&1
  )"
  STATUS=$?
  assert_eq 0 "$STATUS" "docker compose renders the tester file when FERRITE_TEST_IMAGE is supplied"
  assert_contains "$RENDERED" "ghcr.io/ferritelabs/ferrite@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "render honors the exact image override"
  assert_contains "$RENDERED" "published: \"16379\"" "render honors the Redis-compatible port override"
  assert_contains "$RENDERED" "published: \"19090\"" "render honors the metrics port override"
  HOST_IP_COUNT="$(printf '%s\n' "$RENDERED" | grep -c 'host_ip: 127.0.0.1')"
  assert_eq 2 "$HOST_IP_COUNT" "both rendered ports are bound to host_ip 127.0.0.1"
else
  echo "  skip: Docker Compose unavailable; static Compose validation completed"
fi

harness_summary
