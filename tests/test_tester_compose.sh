#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck disable=SC1091
source "${HERE}/lib/harness.sh"

COMPOSE_FILE="${REPO_ROOT}/docker-compose.tester.yml"
CONTENT="$(cat "$COMPOSE_FILE")"

assert_contains "$CONTENT" 'ghcr.io/ferritelabs/ferrite:0.4.0' "tester Compose defaults to the v0.4.0 baseline"
assert_contains "$CONTENT" "\${FERRITE_TEST_IMAGE:-" "tester image is configurable"
assert_contains "$CONTENT" "\${FERRITE_TEST_PORT:-6379}" "Redis-compatible host port is configurable"
assert_contains "$CONTENT" "\${FERRITE_TEST_METRICS_PORT:-9090}" "metrics host port is configurable"
assert_contains "$CONTENT" 'ferrite-tester-data:/var/lib/ferrite/data' "tester Compose uses a named data volume"
assert_contains "$CONTENT" 'test: ["CMD", "ferrite-cli", "PING"]' "healthcheck uses ferrite-cli"
assert_contains "$CONTENT" "resources:" "tester Compose declares conservative resource defaults"
assert_not_contains "$CONTENT" "container_name:" "tester Compose leaves container naming project-scoped"
assert_not_contains "$CONTENT" "build:" "tester Compose never builds from local context"
assert_not_contains "$CONTENT" "ferrite:latest" "tester Compose never defaults to latest"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  RENDERED="$(
    FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite:0.4.0-rc.1" \
    FERRITE_TEST_PORT=16379 \
    FERRITE_TEST_METRICS_PORT=19090 \
      docker compose -f "$COMPOSE_FILE" config 2>&1
  )"
  STATUS=$?
  assert_eq 0 "$STATUS" "docker compose renders the tester file"
  assert_contains "$RENDERED" "ghcr.io/ferritelabs/ferrite:0.4.0-rc.1" "render honors the image override"
  assert_contains "$RENDERED" "published: \"16379\"" "render honors the Redis-compatible port override"
  assert_contains "$RENDERED" "published: \"19090\"" "render honors the metrics port override"
else
  echo "  skip: Docker Compose unavailable; static Compose validation completed"
fi

harness_summary
