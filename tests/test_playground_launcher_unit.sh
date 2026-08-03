#!/usr/bin/env bash
# Runs the repository-owned playground launcher's Rust unit tests.
#
# The launcher owns the playground's public RESP proxy, its shared command
# policy, and the Ferrite child lifecycle, so its unit tests are part of the
# repository's own test gate. Skips cleanly when cargo is unavailable.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

MANIFEST="${REPO_ROOT}/playground-launcher/Cargo.toml"
if [[ ! -f "$MANIFEST" ]]; then
  echo "  FAIL: ${MANIFEST} not found" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "  skip: cargo is not installed in this environment; skipping launcher unit tests."
  echo "  (CI installs the Rust toolchain before running this suite.)"
  exit 0
fi

TEST_LOG="$(mktemp)"
trap 'rm -f "$TEST_LOG"' EXIT

if cargo test --manifest-path "$MANIFEST" >"$TEST_LOG" 2>&1; then
  harness_ok "playground-launcher unit tests pass"
  SUMMARY="$(grep -E '^test result:' "$TEST_LOG" | head -1)"
  echo "  ${SUMMARY}"
else
  harness_fail "playground-launcher unit tests failed: $(tail -60 "$TEST_LOG")"
fi

harness_summary
