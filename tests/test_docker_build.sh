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
# exactly the part of the Dockerfile this audit fixed (F-02). It also
# verifies the source-integrity contract added on top of that fetch: the
# required FERRITE_SOURCE_SHA256 build-arg must be verified before
# extraction, and a build with a missing or mismatched checksum must fail.
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
  harness_ok "docker build --target source succeeds with the default FERRITE_SOURCE_SHA256 (checksum verifies)"
else
  harness_fail "docker build --target source failed: $(tail -30 "$BUILD_LOG")"
fi

# A build with an explicitly empty checksum must fail loudly (not silently
# skip verification) before ever extracting the tarball.
EMPTY_SHA_LOG="$(mktemp)"
if docker build --target source --build-arg FERRITE_SOURCE_SHA256= \
    -t "${IMAGE_TAG}-empty-sha" "$REPO_ROOT" >"$EMPTY_SHA_LOG" 2>&1; then
  harness_fail "docker build unexpectedly succeeded with an empty FERRITE_SOURCE_SHA256"
  docker image rm -f "${IMAGE_TAG}-empty-sha" >/dev/null 2>&1 || true
else
  if grep -q "FERRITE_SOURCE_SHA256 build-arg is required" "$EMPTY_SHA_LOG"; then
    harness_ok "docker build fails with a clear error when FERRITE_SOURCE_SHA256 is empty"
  else
    harness_fail "docker build failed for an empty FERRITE_SOURCE_SHA256, but not with the expected error message: $(tail -20 "$EMPTY_SHA_LOG")"
  fi
fi
rm -f "$EMPTY_SHA_LOG"

# A build with a wrong (but well-formed) checksum must fail the
# verification step rather than silently proceeding with an unverified
# download, whether or not FERRITE_VERSION/FERRITE_SOURCE_URL were
# overridden.
BAD_SHA_LOG="$(mktemp)"
BAD_SHA="0000000000000000000000000000000000000000000000000000000000000000"
if docker build --target source --build-arg "FERRITE_SOURCE_SHA256=${BAD_SHA}" \
    -t "${IMAGE_TAG}-bad-sha" "$REPO_ROOT" >"$BAD_SHA_LOG" 2>&1; then
  harness_fail "docker build unexpectedly succeeded with a mismatched FERRITE_SOURCE_SHA256"
  docker image rm -f "${IMAGE_TAG}-bad-sha" >/dev/null 2>&1 || true
else
  if grep -qi "FAILED\|did not match" "$BAD_SHA_LOG"; then
    harness_ok "docker build fails checksum verification when FERRITE_SOURCE_SHA256 doesn't match the tarball"
  else
    harness_fail "docker build failed for a mismatched FERRITE_SOURCE_SHA256, but not via the checksum check: $(tail -20 "$BAD_SHA_LOG")"
  fi
fi
rm -f "$BAD_SHA_LOG"

harness_summary
