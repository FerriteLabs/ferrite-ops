#!/usr/bin/env bash
# Verifies scripts/smoke_test.sh falls back to PATH-resolved ferrite /
# ferrite-cli binaries when FERRITE_BIN/FERRITE_CLI_BIN/FERRITE_SOURCE_DIR
# are not set.
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

OUTPUT="$(env -u FERRITE_BIN -u FERRITE_CLI_BIN -u FERRITE_SOURCE_DIR \
          PATH="${WORK_DIR}/bin:${PATH}" \
          bash "${REPO_ROOT}/scripts/smoke_test.sh" 2>&1)"
STATUS=$?

assert_eq 0 "$STATUS" "smoke_test.sh exits 0 when ferrite/ferrite-cli are found on PATH"
assert_contains "$OUTPUT" "PONG" "smoke_test.sh output reports a PONG reply via PATH resolution"
assert_contains "$OUTPUT" "Using ferrite binary:     ${WORK_DIR}/bin/ferrite" "smoke_test.sh reports the PATH-resolved ferrite binary"

harness_summary
