#!/usr/bin/env bash
# Static and functional coverage for version-sync.yml's release-ordering
# guard: automated and manual dispatches must never regress the canonical
# active-release.env. There is no downgrade override of any kind — an equal
# retry is a no-op unless the checksum changed (which fails loudly), and an
# older candidate is always skipped. No network or Docker is required.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

VERSION_SYNC_YML="${REPO_ROOT}/.github/workflows/version-sync.yml"
ORDER="${REPO_ROOT}/scripts/release-ordering.sh"
CONTENT="$(cat "$VERSION_SYNC_YML")"
ZERO="0000000000000000000000000000000000000000000000000000000000000000"
ONES="1111111111111111111111111111111111111111111111111111111111111111"

# --- Static checks ----------------------------------------------------------
assert_not_contains "$CONTENT" "allow_downgrade" \
  "version-sync.yml no longer exposes any allow_downgrade override"
assert_not_contains "$CONTENT" "ALLOW_DOWNGRADE" \
  "version-sync.yml no longer reads an ALLOW_DOWNGRADE variable anywhere"
assert_not_contains "$CONTENT" "client_payload.allow_downgrade" \
  "a repository_dispatch client payload cannot reference a removed allow_downgrade"
assert_contains "$CONTENT" "ORDER_SCRIPT: scripts/release-ordering.sh" \
  "version-sync.yml wires in the shared ordering guard script"
assert_contains "$CONTENT" '"$ORDER_SCRIPT" classify' \
  "version-sync.yml classifies the candidate with the shared ordering guard"
assert_contains "$CONTENT" "id: guard" \
  "version-sync.yml defines the ordering guard step"
assert_eq "3" "$(grep -c "if: steps.guard.outputs.proceed == 'true'" "$VERSION_SYNC_YML")" \
  "the sync, RPM, and PR steps are all gated on the guard proceeding"
assert_contains "$CONTENT" "rollbacks are a separate, explicitly human-driven process" \
  "version-sync.yml documents that rollbacks are deferred to a future human process"
assert_contains "$CONTENT" "There is no override, manual or" \
  "version-sync.yml documents that the OLDER skip has no override of any kind"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  skip: python3/PyYAML unavailable; skipping guard functional replay."
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
GUARD_SCRIPT="${TMP}/guard.sh"
if ! python3 - "$VERSION_SYNC_YML" "$GUARD_SCRIPT" <<'PYEOF'
import sys, yaml
sync_path, out_path = sys.argv[1:]
with open(sync_path) as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["sync"]["steps"]
run = next(s["run"] for s in steps if s.get("name") == "Guard release ordering")
with open(out_path, "w") as f:
    f.write(run)
PYEOF
then
  harness_fail "could not extract the ordering guard step from version-sync.yml"
  harness_summary
  exit $?
fi
harness_ok "extracted the ordering guard step from version-sync.yml"

# Confirm the extracted step's own source never references an ALLOW_DOWNGRADE
# variable either — i.e. this isn't merely hidden by unreachable branches.
assert_not_contains "$(cat "$GUARD_SCRIPT")" "ALLOW_DOWNGRADE" \
  "the extracted guard step source contains no ALLOW_DOWNGRADE reference"

# Fixture repo whose canonical active-release.env is 0.4.0 / ZERO checksum.
FIXTURE="${TMP}/repo"
mkdir -p "$FIXTURE"
printf 'FERRITE_VERSION=0.4.0\nFERRITE_SOURCE_SHA256=%s\n' "$ZERO" \
  > "${FIXTURE}/active-release.env"

run_guard() {
  local candidate_ver="$1" candidate_sha="$2" out="$3"
  : > "$out"
  (
    cd "$FIXTURE" &&
      CANDIDATE_VERSION="$candidate_ver" \
      CANDIDATE_SHA256="$candidate_sha" \
      ORDER_SCRIPT="$ORDER" \
      GITHUB_OUTPUT="$out" \
      bash "$GUARD_SCRIPT" >"${out}.log" 2>&1
  )
}

# Newer candidate: proceed.
if run_guard "0.4.1" "$ONES" "${TMP}/newer.out"; then
  assert_contains "$(cat "${TMP}/newer.out")" "proceed=true" \
    "a newer automated candidate proceeds with the sync"
else
  harness_fail "newer candidate unexpectedly errored: $(cat "${TMP}/newer.out.log")"
fi

# Equal version, identical checksum: no-op skip.
if run_guard "0.4.0" "$ZERO" "${TMP}/equal_same.out"; then
  assert_contains "$(cat "${TMP}/equal_same.out")" "proceed=false" \
    "an identical retry is a no-op (proceed=false)"
  assert_contains "$(cat "${TMP}/equal_same.out.log")" "nothing to sync" \
    "an identical retry explains that there is nothing to sync"
else
  harness_fail "equal/same-checksum retry unexpectedly errored: $(cat "${TMP}/equal_same.out.log")"
fi

# Equal version, different checksum: fail loudly.
if run_guard "0.4.0" "$ONES" "${TMP}/equal_diff.out"; then
  harness_fail "equal version with a different checksum unexpectedly proceeded"
else
  assert_contains "$(cat "${TMP}/equal_diff.out.log")" "source checksum differs" \
    "a same-version checksum conflict fails loudly"
fi

# Older candidate: always skipped. This is a manual workflow_dispatch-style
# invocation (no ALLOW_DOWNGRADE variable exists anymore to try to override
# it with), so this single case now covers every trigger path.
if run_guard "0.3.9" "$ONES" "${TMP}/older.out"; then
  assert_contains "$(cat "${TMP}/older.out")" "proceed=false" \
    "an older candidate always skips the downgrade, with no override available"
  assert_contains "$(cat "${TMP}/older.out.log")" "skipping downgrade" \
    "an older candidate reports the skipped downgrade"
  assert_contains "$(cat "${TMP}/older.out.log")" "never applied automatically or via manual override" \
    "the skip message makes clear there is no override of any kind"
else
  harness_fail "older candidate unexpectedly errored: $(cat "${TMP}/older.out.log")"
fi

# Even if a caller tried to smuggle a stray ALLOW_DOWNGRADE=true into the
# step's environment (e.g. a leftover from an old invocation), the guard
# must still skip: the variable is no longer read anywhere.
run_guard_with_stray_env() {
  local out="${TMP}/stray_env.out"
  : > "$out"
  (
    cd "$FIXTURE" &&
      CANDIDATE_VERSION="0.3.9" \
      CANDIDATE_SHA256="$ONES" \
      ALLOW_DOWNGRADE="true" \
      ORDER_SCRIPT="$ORDER" \
      GITHUB_OUTPUT="$out" \
      bash "$GUARD_SCRIPT" >"${out}.log" 2>&1
  )
}
if run_guard_with_stray_env; then
  assert_contains "$(cat "${TMP}/stray_env.out")" "proceed=false" \
    "a stray ALLOW_DOWNGRADE=true in the environment has no effect on the guard"
else
  harness_fail "guard unexpectedly errored with a stray ALLOW_DOWNGRADE env var: $(cat "${TMP}/stray_env.out.log")"
fi

# Malicious candidate version: rejected by the shared guard, never executed.
MARKER="$(mktemp -u)"
if run_guard "0.4.9\$(touch ${MARKER})" "$ONES" "${TMP}/malicious.out"; then
  harness_fail "guard unexpectedly accepted a malicious candidate version"
else
  harness_ok "guard rejects a malicious candidate version"
fi
if [[ -e "$MARKER" ]]; then
  harness_fail "guard executed a command substitution from input data"
  rm -f "$MARKER"
else
  harness_ok "guard treats a malicious candidate version as inert data"
fi

if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$VERSION_SYNC_YML"; then
    harness_ok "actionlint accepts the guarded version-sync workflow"
  else
    harness_fail "actionlint rejected the guarded version-sync workflow"
  fi
else
  echo "  skip: actionlint not available; static and functional checks completed."
fi

harness_summary
