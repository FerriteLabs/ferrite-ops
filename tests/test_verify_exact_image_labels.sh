#!/usr/bin/env bash
# Static and functional coverage for scripts/verify-exact-image-labels.sh —
# the single trusted helper shared by release.yml's pre-build "Check existing
# exact GHCR tag" step and reconcile-release-tags.yml's "Verify every exact
# stable GHCR source" step. Both workflows previously risked drifting on what
# "this exact tag's metadata is trustworthy" means: release.yml's own inline
# jq only ever inspected the FIRST platform of a multi-platform manifest
# (silently ignoring every other platform), while reconcile-release-tags.yml
# already inspected every platform. This suite exercises the shared helper
# directly against fixtures covering a matching amd64+arm64 manifest, one
# mismatched platform, missing labels, and a single-platform image, so a
# regression in either mode is caught here rather than only inside a much
# larger workflow-replay test.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

SCRIPT="${REPO_ROOT}/scripts/verify-exact-image-labels.sh"
METADATA_SCRIPT="${REPO_ROOT}/scripts/inspect-exact-image-metadata.sh"
FIXTURES="${HERE}/fixtures/verify-exact-image-labels"
RELEASE_YML="${REPO_ROOT}/.github/workflows/release.yml"
RECONCILE_YML="${REPO_ROOT}/.github/workflows/reconcile-release-tags.yml"

SHA_A="$(printf 'a%.0s' $(seq 1 64))"

if [[ ! -x "$SCRIPT" ]]; then
  harness_fail "scripts/verify-exact-image-labels.sh is not executable"
  harness_summary
  exit $?
fi

for fixture in \
  multi-platform-match.json \
  multi-platform-mismatched-sha256.json \
  multi-platform-mismatched-version.json \
  multi-platform-missing-labels.json \
  multi-platform-invalid-sha-format.json \
  multi-platform-match-with-attestation.json \
  multi-platform-mismatch-with-attestation.json \
  single-platform-match.json \
  single-platform-mismatched-version.json \
  single-platform-missing-labels.json \
  empty-image.json \
  malformed.json; do
  if [[ ! -f "${FIXTURES}/${fixture}" ]]; then
    harness_fail "missing fixture: ${fixture}"
    harness_summary
    exit $?
  fi
done

run_exact() {
  local fixture="$1" version="$2" sha256="$3"
  bash "$SCRIPT" exact "$version" "$sha256" <"${FIXTURES}/${fixture}"
}

run_consistent() {
  local fixture="$1" version="$2"
  bash "$SCRIPT" consistent "$version" <"${FIXTURES}/${fixture}"
}

# --- "exact" mode: caller supplies the specific known-correct labels -------

# Matching amd64+arm64: every platform carries the exact expected labels.
if run_exact multi-platform-match.json "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_ok "exact mode passes when every platform (amd64+arm64) carries the exact expected version and checksum labels"
else
  harness_fail "exact mode incorrectly rejected a consistent matching amd64+arm64 image"
fi

# Buildx includes provenance/SBOM attestations as descriptor-marked
# `unknown/unknown` entries. They are not runtime platforms and carry no
# Ferrite labels, so they must be excluded without weakening verification of
# amd64/arm64.
if run_exact multi-platform-match-with-attestation.json "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_ok "exact mode ignores descriptor-marked attestation entries while verifying every runtime platform"
else
  harness_fail "exact mode incorrectly rejected matching runtime platforms because a BuildKit attestation entry lacks runtime labels"
fi

if run_exact multi-platform-mismatch-with-attestation.json "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_fail "exact mode let a descriptor-marked attestation entry hide a mismatched runtime platform"
else
  harness_ok "exact mode still fails on a mismatched runtime platform when attestations are present"
fi

# One mismatched platform (different source-sha256 on arm64): must fail.
if run_exact multi-platform-mismatched-sha256.json "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_fail "exact mode incorrectly accepted a multi-platform image with one platform's source-sha256 label mismatched"
else
  harness_ok "exact mode fails closed when one platform (arm64) has a mismatched source-checksum label"
fi

# One mismatched platform (different version on arm64): must fail.
if run_exact multi-platform-mismatched-version.json "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_fail "exact mode incorrectly accepted a multi-platform image with one platform's version label mismatched"
else
  harness_ok "exact mode fails closed when one platform (arm64) has a mismatched version label"
fi

# Missing labels entirely on one platform: must fail.
if run_exact multi-platform-missing-labels.json "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_fail "exact mode incorrectly accepted a multi-platform image with one platform missing its labels"
else
  harness_ok "exact mode fails closed when one platform (arm64) is missing its labels entirely"
fi

# Single-platform image: exact match still passes.
if run_exact single-platform-match.json "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_ok "exact mode passes for a single-platform image whose labels match exactly"
else
  harness_fail "exact mode incorrectly rejected a matching single-platform image"
fi

# Single-platform image: mismatched version fails.
if run_exact single-platform-mismatched-version.json "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_fail "exact mode incorrectly accepted a single-platform image with a mismatched version label"
else
  harness_ok "exact mode fails closed for a single-platform image with a mismatched version label"
fi

# Single-platform image: missing labels entirely fails.
if run_exact single-platform-missing-labels.json "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_fail "exact mode incorrectly accepted a single-platform image with no labels"
else
  harness_ok "exact mode fails closed for a single-platform image with no labels at all"
fi

# An empty image object (zero platforms) always fails.
if run_exact empty-image.json "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_fail "exact mode incorrectly accepted an image with zero platforms"
else
  harness_ok "exact mode fails closed for an image with zero platforms"
fi

# Malformed JSON on stdin fails with a clear diagnostic, not a crash.
MALFORMED_ERR="$(run_exact malformed.json "1.2.3" "$SHA_A" 2>&1 1>/dev/null)"
MALFORMED_STATUS=0
run_exact malformed.json "1.2.3" "$SHA_A" >/dev/null 2>&1 || MALFORMED_STATUS=$?
if [ "$MALFORMED_STATUS" -eq 0 ]; then
  harness_fail "exact mode incorrectly accepted malformed JSON input"
else
  assert_contains "$MALFORMED_ERR" "malformed manifest JSON" \
    "exact mode reports a clear diagnostic for malformed input JSON"
fi

# --- "consistent" mode: no independently known canonical checksum ---------
# (used by reconcile-release-tags.yml, which trusts only that every platform
# agrees with every other platform on a well-formed checksum).

if run_consistent multi-platform-match.json "1.2.3" >/dev/null 2>&1; then
  harness_ok "consistent mode passes when every platform (amd64+arm64) shares the same well-formed checksum"
else
  harness_fail "consistent mode incorrectly rejected a consistent matching amd64+arm64 image"
fi

if run_consistent multi-platform-match-with-attestation.json "1.2.3" >/dev/null 2>&1; then
  harness_ok "consistent mode ignores descriptor-marked attestations while requiring all runtime platforms to agree"
else
  harness_fail "consistent mode incorrectly treated a BuildKit attestation as an unlabeled runtime platform"
fi

if run_consistent multi-platform-mismatch-with-attestation.json "1.2.3" >/dev/null 2>&1; then
  harness_fail "consistent mode let an attestation entry hide disagreement between runtime platforms"
else
  harness_ok "consistent mode detects runtime-platform disagreement when attestations are present"
fi

if run_consistent multi-platform-mismatched-sha256.json "1.2.3" >/dev/null 2>&1; then
  harness_fail "consistent mode incorrectly accepted a multi-platform image whose platforms disagree on the source-checksum label"
else
  harness_ok "consistent mode fails closed when platforms disagree with each other on the source-checksum label"
fi

if run_consistent multi-platform-invalid-sha-format.json "1.2.3" >/dev/null 2>&1; then
  harness_fail "consistent mode incorrectly accepted a malformed (non-hex) source-checksum label"
else
  harness_ok "consistent mode fails closed on a malformed (non-64-hex) source-checksum label"
fi

if run_consistent multi-platform-missing-labels.json "1.2.3" >/dev/null 2>&1; then
  harness_fail "consistent mode incorrectly accepted a multi-platform image with one platform missing its labels"
else
  harness_ok "consistent mode fails closed when one platform is missing its labels entirely"
fi

if run_consistent single-platform-match.json "1.2.3" >/dev/null 2>&1; then
  harness_ok "consistent mode passes for a single-platform image with a well-formed checksum"
else
  harness_fail "consistent mode incorrectly rejected a well-formed single-platform image"
fi

if run_consistent single-platform-missing-labels.json "1.2.3" >/dev/null 2>&1; then
  harness_fail "consistent mode incorrectly accepted a single-platform image with no labels"
else
  harness_ok "consistent mode fails closed for a single-platform image with no labels at all"
fi

if run_consistent empty-image.json "1.2.3" >/dev/null 2>&1; then
  harness_fail "consistent mode incorrectly accepted an image with zero platforms"
else
  harness_ok "consistent mode fails closed for an image with zero platforms"
fi

# --- Usage / argument validation --------------------------------------------
if bash "$SCRIPT" >/dev/null 2>&1; then
  harness_fail "the script incorrectly accepted zero arguments"
else
  harness_ok "the script rejects zero arguments"
fi
if bash "$SCRIPT" bogus-mode "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_fail "the script incorrectly accepted an unknown mode"
else
  harness_ok "the script rejects an unknown mode"
fi
if bash "$SCRIPT" exact "1.2.3" >/dev/null 2>&1; then
  harness_fail "'exact' mode incorrectly accepted a missing sha256 argument"
else
  harness_ok "'exact' mode requires both a version and a sha256 argument"
fi
if echo "" | bash "$SCRIPT" exact "1.2.3" "$SHA_A" >/dev/null 2>&1; then
  harness_fail "the script incorrectly accepted empty stdin"
else
  harness_ok "the script rejects empty stdin"
fi
UNKNOWN_EXIT=2
bash "$SCRIPT" >/dev/null 2>&1
assert_eq "$UNKNOWN_EXIT" "$?" \
  "a usage error exits with status 2, distinct from a verification failure (status 1)"

# --- Wiring: both workflows delegate to this one shared script -------------
assert_contains "$(cat "$RELEASE_YML")" "LABELS_SCRIPT: scripts/verify-exact-image-labels.sh" \
  "release.yml wires in the shared exact-tag label verification helper"
assert_contains "$(cat "$RELEASE_YML")" "METADATA_SCRIPT: scripts/inspect-exact-image-metadata.sh" \
  "release.yml wires in the shared digest-pinned metadata helper"
assert_contains "$(cat "$RELEASE_YML")" 'bash "$LABELS_SCRIPT" exact "$VERSION" "$SHA256"' \
  "release.yml invokes the shared helper in 'exact' mode with its own known-correct labels"
assert_contains "$(cat "$RECONCILE_YML")" "LABELS_SCRIPT: scripts/verify-exact-image-labels.sh" \
  "reconcile-release-tags.yml wires in the shared exact-tag label verification helper"
assert_contains "$(cat "$RECONCILE_YML")" "METADATA_SCRIPT: scripts/inspect-exact-image-metadata.sh" \
  "reconcile-release-tags.yml wires in the shared digest-pinned metadata helper"
assert_contains "$(cat "$RECONCILE_YML")" 'bash "$LABELS_SCRIPT" consistent "$VERSION"' \
  "reconcile-release-tags.yml invokes the shared helper in 'consistent' mode (no independently known canonical checksum)"

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning "$SCRIPT" "$METADATA_SCRIPT"; then
    harness_ok "shellcheck accepts the shared exact-tag metadata helpers"
  else
    harness_fail "shellcheck rejected a shared exact-tag metadata helper"
  fi
else
  echo "  skip: shellcheck not available."
fi

harness_summary
