#!/usr/bin/env bash
# Verifies scripts/smoke_test.sh fails fast with clear, actionable error
# messages for invalid or missing input, instead of assuming a repository
# layout that doesn't exist in ferrite-ops.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# 1. FERRITE_BIN points at something that isn't executable.
touch "${WORK_DIR}/not-executable"
OUTPUT="$(FERRITE_BIN="${WORK_DIR}/not-executable" bash "${REPO_ROOT}/scripts/smoke_test.sh" 2>&1)"
STATUS=$?
assert_eq 1 "$STATUS" "smoke_test.sh exits 1 when FERRITE_BIN is not executable"
assert_contains "$OUTPUT" "is not an executable file" "smoke_test.sh reports a clear error for a non-executable FERRITE_BIN"

# 2. FERRITE_SOURCE_DIR does not contain a Cargo.toml.
mkdir -p "${WORK_DIR}/empty-source"
OUTPUT="$(FERRITE_SOURCE_DIR="${WORK_DIR}/empty-source" bash "${REPO_ROOT}/scripts/smoke_test.sh" 2>&1)"
STATUS=$?
assert_eq 1 "$STATUS" "smoke_test.sh exits 1 when FERRITE_SOURCE_DIR lacks a Cargo.toml"
assert_contains "$OUTPUT" "does not contain a Cargo.toml" "smoke_test.sh reports a clear error for an invalid FERRITE_SOURCE_DIR"

# 3. Nothing set and nothing on PATH: must not silently fall back to a
#    sibling ../ferrite checkout or any other assumed location.
OUTPUT="$(env -i PATH=/usr/bin:/bin HOME="$HOME" bash "${REPO_ROOT}/scripts/smoke_test.sh" 2>&1)"
STATUS=$?
assert_eq 1 "$STATUS" "smoke_test.sh exits 1 when no binary can be resolved anywhere"
assert_contains "$OUTPUT" "Could not locate the 'ferrite' binary" "smoke_test.sh reports a clear error when no binary is resolvable"

# 4. Never falls back to a sibling ../ferrite checkout even if one exists.
SIBLING_DIR="${WORK_DIR}/sibling-root/ferrite"
mkdir -p "$SIBLING_DIR"
echo '[package]' > "${SIBLING_DIR}/Cargo.toml"
OUTPUT="$(cd "${WORK_DIR}/sibling-root" && env -i PATH=/usr/bin:/bin HOME="$HOME" bash "${REPO_ROOT}/scripts/smoke_test.sh" 2>&1)"
STATUS=$?
assert_eq 1 "$STATUS" "smoke_test.sh does not silently build from a sibling ../ferrite checkout"
assert_contains "$OUTPUT" "Could not locate the 'ferrite' binary" "smoke_test.sh still reports a resolution error rather than using a sibling checkout"

harness_summary
