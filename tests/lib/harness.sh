#!/usr/bin/env bash
# Minimal, dependency-free Bash test harness shared by tests/test_*.sh.
# No third-party test framework is used per project policy.
#
# Intended usage in a test file:
#   #!/usr/bin/env bash
#   set -euo pipefail
#   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=tests/lib/harness.sh
#   source "${HERE}/lib/harness.sh"
#
#   assert_eq 0 "$exit_code" "description of the assertion"
#   harness_summary   # must be the last line; sets the script's exit code

HARNESS_PASS_COUNT=0
HARNESS_FAIL_COUNT=0

harness_ok() {
  HARNESS_PASS_COUNT=$((HARNESS_PASS_COUNT + 1))
  echo "  ok: $1"
}

harness_fail() {
  HARNESS_FAIL_COUNT=$((HARNESS_FAIL_COUNT + 1))
  echo "  FAIL: $1" >&2
}

assert_eq() {
  local expected="$1" actual="$2" desc="${3:-values should match}"
  if [[ "$expected" == "$actual" ]]; then
    harness_ok "$desc"
  else
    harness_fail "$desc (expected: '$expected', actual: '$actual')"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" desc="${3:-output should contain expected text}"
  if [[ "$haystack" == *"$needle"* ]]; then
    harness_ok "$desc"
  else
    harness_fail "$desc (needle '$needle' not found in: ${haystack:0:300})"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" desc="${3:-output should not contain unexpected text}"
  if [[ "$haystack" != *"$needle"* ]]; then
    harness_ok "$desc"
  else
    harness_fail "$desc (unexpected needle '$needle' found)"
  fi
}

assert_true() {
  local condition="$1" desc="${2:-condition should be true}"
  if [[ "$condition" -eq 0 ]]; then
    harness_ok "$desc"
  else
    harness_fail "$desc"
  fi
}

# Print a summary and return a process exit code reflecting pass/fail.
harness_summary() {
  echo "  --- $(basename "$0"): ${HARNESS_PASS_COUNT} passed, ${HARNESS_FAIL_COUNT} failed ---"
  [[ "$HARNESS_FAIL_COUNT" -eq 0 ]]
}
