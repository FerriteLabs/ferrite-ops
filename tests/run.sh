#!/usr/bin/env bash
# Self-contained Bash test runner (no third-party test framework).
#
# Discovers and runs every tests/test_*.sh script, prints a summary, and
# exits non-zero if any script fails. Intended to run before CI's
# build/lint gates (docker build, helm lint, shellcheck) so structural or
# behavioral regressions in scripts/Dockerfile/charts are caught even
# without a Docker daemon or a real Ferrite build available.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL=0
FAILED=0
FAILED_NAMES=()

shopt -s nullglob
TEST_FILES=("${HERE}"/test_*.sh)
shopt -u nullglob

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
  echo "run.sh: no tests/test_*.sh scripts found." >&2
  exit 1
fi

for test_file in "${TEST_FILES[@]}"; do
  name="$(basename "$test_file")"
  echo "=== ${name} ==="
  TOTAL=$((TOTAL + 1))
  if bash "$test_file"; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name}"
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$name")
  fi
  echo
done

echo "=================================="
echo "tests/run.sh: ${TOTAL} suite(s) run, $((TOTAL - FAILED)) passed, ${FAILED} failed"
if [[ "$FAILED" -gt 0 ]]; then
  echo "Failed suites: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
