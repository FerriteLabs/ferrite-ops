#!/usr/bin/env bash
# Static and functional coverage for scripts/compute-source-checksum.sh —
# the single trusted helper shared by release.yml, version-sync.yml, and
# release-orchestration.yml for the canonical Ferrite source-archive SHA256.
#
# The canonical checksum is ALWAYS downloaded and computed fresh; a
# caller-supplied checksum (repository_dispatch payload or manual
# workflow_dispatch input) is NEVER trusted as truth on its own. This suite
# fakes `curl` to avoid any real network access and proves: a correct
# supplied value is accepted, a syntactically valid but wrong supplied value
# is rejected, no supplied value still yields the canonical computed
# checksum, and a download failure fails closed rather than silently
# proceeding without a canonical checksum.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

SCRIPT="${REPO_ROOT}/scripts/compute-source-checksum.sh"
RELEASE_YML="${REPO_ROOT}/.github/workflows/release.yml"
VERSION_SYNC_YML="${REPO_ROOT}/.github/workflows/version-sync.yml"
ORCHESTRATION_YML="${REPO_ROOT}/.github/workflows/release-orchestration.yml"

if [[ ! -x "$SCRIPT" ]]; then
  harness_fail "scripts/compute-source-checksum.sh is not executable"
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_BIN="${TMP}/bin"
mkdir -p "$FAKE_BIN"

FAKE_CONTENT="ferrite-canonical-source-fixture-v1"
CANONICAL_SHA256="$(printf '%s' "$FAKE_CONTENT" | shasum -a 256 | awk '{print $1}')"

# A stateful fake `curl` that always returns the same deterministic content
# for a successful download, or fails deterministically when
# CURL_FAIL=true — no real network access is ever made by this suite.
cat >"${FAKE_BIN}/curl" <<CURL_EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${CURL_FAIL:-false}" = "true" ]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
printf '%s' '${FAKE_CONTENT}'
CURL_EOF
chmod +x "${FAKE_BIN}/curl"

run_checksum() {
  local owner="$1" version="$2" supplied="${3:-}" fail="${4:-false}"
  (
    export PATH="${FAKE_BIN}:${PATH}"
    export CURL_FAIL="$fail"
    bash "$SCRIPT" "$owner" "$version" "$supplied"
  )
}

# --- No supplied value: canonical value is computed from scratch ----------
OUT="${TMP}/no_supplied.out"
ERR="${TMP}/no_supplied.err"
if run_checksum FerriteLabs 1.2.3 "" false >"$OUT" 2>"$ERR"; then
  assert_eq "$CANONICAL_SHA256" "$(cat "$OUT")" \
    "no supplied checksum: the canonical computed checksum is printed to stdout"
else
  harness_fail "no supplied checksum unexpectedly failed: $(cat "$ERR")"
fi

# --- Correct supplied value: matches the canonical computed checksum ------
OUT="${TMP}/correct_supplied.out"
ERR="${TMP}/correct_supplied.err"
if run_checksum FerriteLabs 1.2.3 "$CANONICAL_SHA256" false >"$OUT" 2>"$ERR"; then
  assert_eq "$CANONICAL_SHA256" "$(cat "$OUT")" \
    "a correct supplied checksum is confirmed and the canonical value is printed"
else
  harness_fail "a correct supplied checksum unexpectedly failed: $(cat "$ERR")"
fi

# Uppercase variant of the correct value is normalized and still accepted.
UPPER_SUPPLIED="$(printf '%s' "$CANONICAL_SHA256" | tr 'a-f' 'A-F')"
OUT="${TMP}/correct_supplied_upper.out"
ERR="${TMP}/correct_supplied_upper.err"
if run_checksum FerriteLabs 1.2.3 "$UPPER_SUPPLIED" false >"$OUT" 2>"$ERR"; then
  assert_eq "$CANONICAL_SHA256" "$(cat "$OUT")" \
    "an uppercase but otherwise correct supplied checksum is normalized and accepted"
else
  harness_fail "an uppercase correct supplied checksum unexpectedly failed: $(cat "$ERR")"
fi

# --- Syntactically valid but WRONG supplied value: rejected, not trusted --
WRONG_SHA256="$(printf 'f%.0s' $(seq 1 64))"
OUT="${TMP}/mismatch.out"
ERR="${TMP}/mismatch.err"
if run_checksum FerriteLabs 1.2.3 "$WRONG_SHA256" false >"$OUT" 2>"$ERR"; then
  harness_fail "a syntactically valid but mismatched supplied checksum was incorrectly accepted"
else
  assert_contains "$(cat "$ERR")" "does not match the canonical computed checksum" \
    "a syntactically valid but mismatched supplied checksum is rejected with a clear diagnostic"
fi
if [[ -s "$OUT" ]]; then
  harness_fail "a rejected mismatched checksum still printed a value to stdout"
else
  harness_ok "a rejected mismatched checksum prints nothing to stdout"
fi

# --- Syntactically invalid supplied value: rejected before any download --
INVALID_MARKER="${TMP}/invalid_download_marker"
cat >"${FAKE_BIN}/curl" <<CURL_EOF
#!/usr/bin/env bash
touch "${INVALID_MARKER}"
printf '%s' '${FAKE_CONTENT}'
CURL_EOF
chmod +x "${FAKE_BIN}/curl"
ERR="${TMP}/invalid_format.err"
if run_checksum FerriteLabs 1.2.3 "not-a-valid-checksum" false >/dev/null 2>"$ERR"; then
  harness_fail "a syntactically invalid supplied checksum was incorrectly accepted"
else
  assert_contains "$(cat "$ERR")" "64 hexadecimal characters" \
    "a syntactically invalid supplied checksum is rejected with a clear diagnostic"
fi
if [[ -e "$INVALID_MARKER" ]]; then
  harness_fail "an invalid supplied checksum format reached the download step before being rejected"
else
  harness_ok "an invalid supplied checksum format is rejected before any network access"
fi
# Restore the deterministic fake curl for subsequent cases.
cat >"${FAKE_BIN}/curl" <<CURL_EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${CURL_FAIL:-false}" = "true" ]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
printf '%s' '${FAKE_CONTENT}'
CURL_EOF
chmod +x "${FAKE_BIN}/curl"

# --- Download failure: fails closed instead of silently proceeding -------
ERR="${TMP}/download_failure.err"
if run_checksum FerriteLabs 1.2.3 "" true >/dev/null 2>"$ERR"; then
  harness_fail "a canonical source download failure was incorrectly ignored"
else
  assert_contains "$(cat "$ERR")" "failed to download or hash the canonical source archive" \
    "a canonical source download failure fails closed with a clear diagnostic"
fi

# A download failure also fails closed even when a syntactically valid
# checksum WAS supplied -- a supplied value can never substitute for a
# successful canonical download.
ERR="${TMP}/download_failure_with_supplied.err"
if run_checksum FerriteLabs 1.2.3 "$CANONICAL_SHA256" true >/dev/null 2>"$ERR"; then
  harness_fail "a supplied checksum incorrectly allowed the release to proceed despite a canonical download failure"
else
  assert_contains "$(cat "$ERR")" "failed to download or hash" \
    "a supplied checksum never substitutes for a failed canonical download"
fi

# --- Input validation -------------------------------------------------------
if run_checksum FerriteLabs "not-a-version" "" false >/dev/null 2>&1; then
  harness_fail "an invalid version was incorrectly accepted"
else
  harness_ok "an invalid version is rejected"
fi
if run_checksum "bad owner" 1.2.3 "" false >/dev/null 2>&1; then
  harness_fail "an invalid repository owner was incorrectly accepted"
else
  harness_ok "an invalid repository owner is rejected"
fi
if run_checksum FerriteLabs 1.2.3 >/dev/null 2>&1; then
  harness_ok "a minimal two-argument invocation (no supplied checksum) is accepted"
else
  harness_fail "a minimal two-argument invocation was unexpectedly rejected"
fi
if bash "$SCRIPT" >/dev/null 2>&1; then
  harness_fail "zero arguments was incorrectly accepted"
else
  harness_ok "zero arguments is rejected as a usage error"
fi
bash "$SCRIPT" >/dev/null 2>&1
assert_eq "2" "$?" \
  "a usage error exits with status 2, distinct from checksum/download failures (status 1)"

# A malicious command-substitution attempt in the supplied checksum is
# treated as inert data (rejected by the format check), never executed.
MARKER="$(mktemp -u)"
if run_checksum FerriteLabs 1.2.3 "\$(touch ${MARKER})" false >/dev/null 2>&1; then
  harness_fail "a malicious supplied checksum was incorrectly accepted"
else
  harness_ok "a malicious supplied checksum is rejected"
fi
if [[ -e "$MARKER" ]]; then
  harness_fail "a command substitution from the supplied checksum was executed"
  rm -f "$MARKER"
else
  harness_ok "a command substitution in the supplied checksum is treated as inert data"
fi

# --- Wiring: all three workflows delegate to this one shared script -------
assert_contains "$(cat "$RELEASE_YML")" "CHECKSUM_SCRIPT: scripts/compute-source-checksum.sh" \
  "release.yml wires in the shared canonical-checksum helper"
assert_contains "$(cat "$VERSION_SYNC_YML")" "CHECKSUM_SCRIPT: scripts/compute-source-checksum.sh" \
  "version-sync.yml wires in the shared canonical-checksum helper"
assert_contains "$(cat "$ORCHESTRATION_YML")" "CHECKSUM_SCRIPT: scripts/compute-source-checksum.sh" \
  "release-orchestration.yml wires in the shared canonical-checksum helper"
assert_contains "$(cat "$VERSION_SYNC_YML")" 'bash "$CHECKSUM_SCRIPT" "$REPOSITORY_OWNER" "$VERSION" "$INPUT_SHA256"' \
  "version-sync.yml always computes the canonical checksum, passing any supplied value only for comparison"
assert_contains "$(cat "$ORCHESTRATION_YML")" 'bash "$CHECKSUM_SCRIPT" "$REPOSITORY_OWNER" "$VERSION" "$INPUT_SHA256"' \
  "release-orchestration.yml always computes the canonical checksum, passing any supplied value only for comparison"
assert_not_contains "$(cat "$VERSION_SYNC_YML")" 'SHA256="$INPUT_SHA256"' \
  "version-sync.yml no longer trusts a supplied checksum directly as truth"
assert_not_contains "$(cat "$ORCHESTRATION_YML")" 'SHA256="$INPUT_SHA256"' \
  "release-orchestration.yml no longer trusts a supplied checksum directly as truth"

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning "$SCRIPT"; then
    harness_ok "shellcheck accepts the shared canonical-checksum helper"
  else
    harness_fail "shellcheck rejected the shared canonical-checksum helper"
  fi
else
  echo "  skip: shellcheck not available."
fi

harness_summary
