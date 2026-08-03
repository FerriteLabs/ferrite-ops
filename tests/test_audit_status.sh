#!/usr/bin/env bash
# Keeps the audit status aligned with the implemented release/runtime fixes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
AUDIT_CONTENT="$(cat "${REPO_ROOT}/AUDIT.md")"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

assert_contains "$AUDIT_CONTENT" "| F-18 |" "AUDIT.md records the Moonshot finding"
assert_contains "$AUDIT_CONTENT" "| F-19 |" "AUDIT.md records the Playground finding"
assert_contains "$AUDIT_CONTENT" "Fixed; D-01 resolved" "AUDIT.md marks D-01 resolved"
assert_contains "$AUDIT_CONTENT" "## Release Drift Resolution" "AUDIT.md records release drift as resolved"
assert_contains "$AUDIT_CONTENT" "D-02 is the only deferred item." "AUDIT.md leaves only D-02 deferred"
assert_not_contains "$AUDIT_CONTENT" "| D-01 |" "AUDIT.md no longer lists D-01 as deferred"

harness_summary
