#!/usr/bin/env bash
# Verifies scripts/smoke_test.sh succeeds end-to-end against explicit
# FERRITE_BIN/FERRITE_CLI_BIN paths, with no real Ferrite server involved.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip: python3 not available, fake ferrite server fixture requires it"
  exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

"${HERE}/fixtures/make_fake_ferrite.sh" "${WORK_DIR}/bin"

OUTPUT="$(FERRITE_BIN="${WORK_DIR}/bin/ferrite" \
          FERRITE_CLI_BIN="${WORK_DIR}/bin/ferrite-cli" \
          bash "${REPO_ROOT}/scripts/smoke_test.sh" 2>&1)"
STATUS=$?

assert_eq 0 "$STATUS" "smoke_test.sh exits 0 with valid explicit FERRITE_BIN/FERRITE_CLI_BIN"
assert_contains "$OUTPUT" "PONG" "smoke_test.sh output reports a PONG reply"
assert_contains "$OUTPUT" "Using ferrite binary:     ${WORK_DIR}/bin/ferrite" "smoke_test.sh reports the resolved ferrite binary path"

harness_summary
