#!/usr/bin/env bash
# Unit coverage for scripts/release-ordering.sh — the shared SemVer
# precedence and release-classification engine used by the release promotion
# and version-sync ordering guards. No network or Docker is required.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

ORDER="${REPO_ROOT}/scripts/release-ordering.sh"
ZERO="0000000000000000000000000000000000000000000000000000000000000000"
ONES="1111111111111111111111111111111111111111111111111111111111111111"

if [[ ! -x "$ORDER" ]]; then
  echo "  FAIL: ${ORDER} is missing or not executable" >&2
  exit 1
fi

assert_cmp() {
  local a="$1" b="$2" expected="$3"
  assert_eq "$expected" "$("$ORDER" semver-cmp "$a" "$b")" \
    "semver-cmp ${a} vs ${b} is ${expected}"
}

# Numeric core precedence.
assert_cmp "0.4.1" "0.4.0" "gt"
assert_cmp "0.4.0" "0.4.1" "lt"
assert_cmp "0.4.0" "0.4.0" "eq"
assert_cmp "0.4.10" "0.4.9" "gt"
assert_cmp "1.0.0" "0.99.99" "gt"
assert_cmp "0.4.0" "0.4.0" "eq"

# Pre-release precedence per SemVer 2.0.
assert_cmp "0.5.0" "0.5.0-rc.1" "gt"
assert_cmp "0.5.0-rc.1" "0.5.0" "lt"
assert_cmp "0.5.0-rc.1" "0.5.0-rc.2" "lt"
assert_cmp "0.5.0-rc.2" "0.5.0-rc.10" "lt"
assert_cmp "0.5.0-alpha" "0.5.0-alpha.1" "lt"
assert_cmp "0.5.0-alpha.1" "0.5.0-beta" "lt"
assert_cmp "1.0.0-rc.1" "1.0.0-rc.1" "eq"

# ge exit-code contract.
if "$ORDER" ge "0.4.1" "0.4.0"; then
  harness_ok "ge treats a strictly newer version as promotable"
else
  harness_fail "ge rejected a strictly newer version"
fi
if "$ORDER" ge "0.4.0" "0.4.0"; then
  harness_ok "ge treats an equal version as promotable"
else
  harness_fail "ge rejected an equal version"
fi
if "$ORDER" ge "0.4.0" "0.4.1"; then
  harness_fail "ge accepted an older version"
else
  harness_ok "ge rejects a strictly older version"
fi

# classify covers the four ordering outcomes.
assert_eq "NEWER" "$("$ORDER" classify "0.4.1" "$ZERO" "0.4.0" "$ONES")" \
  "classify reports a newer candidate as NEWER"
assert_eq "OLDER" "$("$ORDER" classify "0.4.0" "$ZERO" "0.4.1" "$ONES")" \
  "classify reports an older candidate as OLDER"
assert_eq "EQUAL_SAME" "$("$ORDER" classify "0.4.0" "$ZERO" "0.4.0" "$ZERO")" \
  "classify reports an identical retry as EQUAL_SAME"
assert_eq "EQUAL_DIFFERENT" "$("$ORDER" classify "0.4.0" "$ZERO" "0.4.0" "$ONES")" \
  "classify reports a same-version checksum conflict as EQUAL_DIFFERENT"

# Untrusted input is rejected as inert data, never executed.
MARKER="$(mktemp -u)"
if "$ORDER" semver-cmp "0.4.0\$(touch ${MARKER})" "0.4.0" >/dev/null 2>&1; then
  harness_fail "semver-cmp accepted a shell-injection version"
else
  harness_ok "semver-cmp rejects a shell-injection version"
fi
if "$ORDER" classify "0.4.0" "not-a-sha" "0.4.0" "$ZERO" >/dev/null 2>&1; then
  harness_fail "classify accepted an invalid checksum"
else
  harness_ok "classify rejects an invalid checksum"
fi
if [[ -e "$MARKER" ]]; then
  harness_fail "release-ordering executed a command substitution from input"
  rm -f "$MARKER"
else
  harness_ok "release-ordering treats command substitutions as inert data"
fi

if "$ORDER" bogus-subcommand >/dev/null 2>&1; then
  harness_fail "release-ordering accepted an unknown subcommand"
else
  harness_ok "release-ordering rejects an unknown subcommand"
fi

harness_summary
