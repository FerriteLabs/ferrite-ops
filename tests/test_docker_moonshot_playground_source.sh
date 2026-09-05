#!/usr/bin/env bash
# Validates that Dockerfile.moonshot and Dockerfile.playground each
# actually build and fetch their pinned, checksum-verified Ferrite source
# tarball (D-01/F-07). Skips cleanly, like tests/test_docker_build.sh, when
# no Docker daemon is reachable.
#
# Mirrors tests/test_docker_build.sh's approach for the primary Dockerfile:
# only the cheap `source` stage is built here (a fast network fetch + hash
# check), not the full Rust compile, to keep tests/run.sh's fast gate fast.
# Full end-to-end builds of these two Dockerfiles were performed manually
# for this pass (see AUDIT.md's D-01 resolution section) but are not
# re-run automatically here for the same reason test_docker_build.sh
# doesn't re-run the primary Dockerfile's full build either.
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

for DOCKERFILE_NAME in "Dockerfile.moonshot" "Dockerfile.playground"; do
  IMAGE_TAG="ferrite-ops-test-source-$(echo "$DOCKERFILE_NAME" | tr '[:upper:].' '[:lower:]-'):$$"
  BUILD_LOG="$(mktemp)"
  cleanup() {
    docker image rm -f "$IMAGE_TAG" >/dev/null 2>&1 || true
    rm -f "$BUILD_LOG"
  }
  trap cleanup EXIT

  if docker build -f "${REPO_ROOT}/${DOCKERFILE_NAME}" --target source \
      -t "$IMAGE_TAG" "$REPO_ROOT" >"$BUILD_LOG" 2>&1; then
    harness_ok "docker build -f ${DOCKERFILE_NAME} --target source succeeds (fetches and verifies the pinned Ferrite source)"
  else
    harness_fail "docker build -f ${DOCKERFILE_NAME} --target source failed: $(tail -30 "$BUILD_LOG")"
  fi

  cleanup
  trap - EXIT
done

harness_summary
