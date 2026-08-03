#!/usr/bin/env bash
# Validates that the default Moonshot Compose path is self-contained,
# release-pinned, and cannot silently fall back to an ordinary Ferrite build.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.moonshot.yml"
DOCKERFILE="${REPO_ROOT}/Dockerfile.moonshot"
ACTIVE_RELEASE="${REPO_ROOT}/active-release.env"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

COMPOSE_CONTENT="$(cat "$COMPOSE_FILE")"
DOCKERFILE_CONTENT="$(cat "$DOCKERFILE")"
EXPECTED_VERSION="$(sed -n 's/^FERRITE_VERSION=//p' "$ACTIVE_RELEASE")"
EXPECTED_SHA256="$(sed -n 's/^FERRITE_SOURCE_SHA256=//p' "$ACTIVE_RELEASE")"

assert_not_contains "$COMPOSE_CONTENT" "../ferrite" \
  "Moonshot Compose never depends on a sibling Ferrite checkout"
assert_contains "$COMPOSE_CONTENT" "context: ." \
  "Moonshot Compose uses ferrite-ops as its build context"
assert_contains "$COMPOSE_CONTENT" "dockerfile: Dockerfile.moonshot" \
  "Moonshot Compose selects the repository-owned Moonshot Dockerfile"
assert_contains "$COMPOSE_CONTENT" "FERRITE_VERSION: \"\${FERRITE_VERSION:-${EXPECTED_VERSION}}\"" \
  "Moonshot Compose passes the current Ferrite version explicitly"
assert_contains "$COMPOSE_CONTENT" "FERRITE_SOURCE_SHA256: \"\${FERRITE_SOURCE_SHA256:-${EXPECTED_SHA256}}\"" \
  "Moonshot Compose passes the matching v0.4.0 checksum explicitly"
assert_contains "$COMPOSE_CONTENT" 'FERRITE_FEATURES: "${FERRITE_FEATURES:-forge-runtime}"' \
  "Moonshot Compose explicitly defaults to forge-runtime"
assert_not_contains "$COMPOSE_CONTENT" "ferrite.example.toml" \
  "Moonshot Compose does not replace the image's generated, verified default config"
assert_contains "$DOCKERFILE_CONTENT" 'ARG FERRITE_FEATURES="forge-runtime"' \
  "Moonshot Dockerfile itself defaults to forge-runtime"
assert_not_contains "$DOCKERFILE_CONTENT" 'ARG FERRITE_FEATURES="default"' \
  "Moonshot Dockerfile cannot silently use ordinary default features"
assert_contains "$DOCKERFILE_CONTENT" 'ENV FERRITE_COMPILED_FEATURES="${FERRITE_FEATURES}"' \
  "Moonshot image exposes compiled feature evidence"

harness_summary
