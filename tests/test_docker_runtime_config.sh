#!/usr/bin/env bash
# Runtime assertion (as opposed to test_dockerfile_static.sh's purely
# textual checks) that the generated container config in the
# `runtime-config` Dockerfile stage actually binds the server and metrics
# listeners to 0.0.0.0, and that the public ferrite.example.toml the stage
# is derived from is left untouched on disk. This stage deliberately has no
# dependency on the (expensive) Rust build, so it builds in a couple of
# seconds — safe to run as part of the fast tests/run.sh gate. Skips
# cleanly, like the other Docker-dependent tests in this suite, when no
# Docker daemon is reachable.
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

IMAGE_TAG="ferrite-ops-test-runtime-config:$$"
BUILD_LOG="$(mktemp)"
CONFIG_DUMP="$(mktemp)"
cleanup() {
  docker image rm -f "$IMAGE_TAG" >/dev/null 2>&1 || true
  rm -f "$BUILD_LOG" "$CONFIG_DUMP"
}
trap cleanup EXIT

if docker build --target runtime-config -t "$IMAGE_TAG" "$REPO_ROOT" >"$BUILD_LOG" 2>&1; then
  harness_ok "docker build --target runtime-config succeeds (generates container runtime config)"
else
  harness_fail "docker build --target runtime-config failed: $(tail -30 "$BUILD_LOG")"
  harness_summary
  exit $?
fi

if docker run --rm --entrypoint cat "$IMAGE_TAG" /etc/ferrite/ferrite.toml > "$CONFIG_DUMP" 2>>"$BUILD_LOG"; then
  harness_ok "generated container runtime config is readable in the built image"
else
  harness_fail "could not read /etc/ferrite/ferrite.toml from the built image: $(tail -30 "$BUILD_LOG")"
fi

BIND_ZERO_COUNT="$(grep -c '^bind = "0\.0\.0\.0"$' "$CONFIG_DUMP" 2>/dev/null || true)"
assert_eq "2" "${BIND_ZERO_COUNT:-0}" \
  "generated runtime config binds both [server] and [metrics] to 0.0.0.0"
assert_not_contains "$(cat "$CONFIG_DUMP")" "127.0.0.1" \
  "generated runtime config no longer contains any loopback-only bind"

# The public example this config is derived from must be untouched on disk.
EXAMPLE_TOML="${REPO_ROOT}/ferrite.example.toml"
if [[ -f "$EXAMPLE_TOML" ]]; then
  EXAMPLE_BIND_COUNT="$(grep -c '^bind = "127\.0\.0\.1"$' "$EXAMPLE_TOML" || true)"
  assert_eq "2" "${EXAMPLE_BIND_COUNT:-0}" \
    "public ferrite.example.toml on disk still documents 127.0.0.1 as the default bind"
fi

harness_summary
