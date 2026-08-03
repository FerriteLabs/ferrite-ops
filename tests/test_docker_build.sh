#!/usr/bin/env bash
# Validates the Dockerfile actually builds when a Docker daemon is
# available; skips clearly and successfully when it is not (e.g. sandboxed
# CI runners without Docker-in-Docker), per the policy-neutral requirement
# that this suite stays useful either way.
#
# The full multi-stage image (compiling the entire Ferrite Rust workspace)
# is already built and verified by the separate "Docker Build" CI job
# (`docker build -t ferrite:test .`), which can take a long time on
# emulated architectures. Re-running that full build here would make
# tests/run.sh — meant to be a fast gate before the build/lint jobs —
# prohibitively slow and redundant. Instead, this test builds only the
# `source` stage: it exercises the real network fetch of the Ferrite
# source tarball and confirms Cargo.toml is present afterwards, which is
# exactly the part of the Dockerfile this audit fixed (F-02).
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

IMAGE_TAG="ferrite-ops-test-source-stage:$$"
BUILD_LOG="$(mktemp)"
cleanup() {
  docker image rm -f "$IMAGE_TAG" >/dev/null 2>&1 || true
  rm -f "$BUILD_LOG"
}
trap cleanup EXIT

if docker build --target source -t "$IMAGE_TAG" "$REPO_ROOT" >"$BUILD_LOG" 2>&1; then
  harness_ok "docker build --target source succeeds (fetches Ferrite source tarball)"
else
  harness_fail "docker build --target source failed: $(tail -30 "$BUILD_LOG")"
fi

harness_summary
