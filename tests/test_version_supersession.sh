#!/usr/bin/env bash
# Static and functional coverage for version-supersession.yml, the merge-time
# guard that prevents a stale version-sync PR from regressing the canonical
# active-release.env once main has advanced. The functional replay uses only
# temporary local Git repositories.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

WORKFLOW="${REPO_ROOT}/.github/workflows/version-supersession.yml"
ORDER="${REPO_ROOT}/scripts/release-ordering.sh"
CONTENT="$(cat "$WORKFLOW")"
ZERO="0000000000000000000000000000000000000000000000000000000000000000"
ONES="1111111111111111111111111111111111111111111111111111111111111111"

# --- Static checks ----------------------------------------------------------
assert_contains "$CONTENT" "pull_request:" \
  "supersession check runs on pull requests"
assert_contains "$CONTENT" "active-release.env" \
  "supersession check is scoped to active-release.env changes"
assert_contains "$CONTENT" "contents: read" \
  "supersession check is read-only"
assert_not_contains "$CONTENT" "contents: write" \
  "supersession check never writes to the repository"
assert_contains "$CONTENT" "head.sha" \
  "supersession check reads the PR head, not the merge ref"
assert_contains "$CONTENT" '"$ORDER_SCRIPT" classify' \
  "supersession check classifies the PR against the base with the shared guard"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  skip: python3/PyYAML unavailable; skipping supersession functional replay."
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CHECK_SCRIPT="${TMP}/check.sh"
if ! python3 - "$WORKFLOW" "$CHECK_SCRIPT" <<'PYEOF'
import sys, yaml
wf_path, out_path = sys.argv[1:]
with open(wf_path) as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["supersession"]["steps"]
run = next(s["run"] for s in steps if s.get("name") == "Reject a superseded active-release change")
with open(out_path, "w") as f:
    f.write(run)
PYEOF
then
  harness_fail "could not extract the supersession check step"
  harness_summary
  exit $?
fi
harness_ok "extracted the supersession check step from the workflow"

REMOTE="${TMP}/origin.git"
git init -q --bare "$REMOTE"

# Seed origin/main with a canonical release, then advance it so main is ahead.
SEED="${TMP}/seed"
git init -q -b main "$SEED"
git -C "$SEED" config user.name "Test User"
git -C "$SEED" config user.email "test@example.invalid"
write_env() { printf 'FERRITE_VERSION=%s\nFERRITE_SOURCE_SHA256=%s\n' "$1" "$2" > "${3}/active-release.env"; }

write_env "0.4.0" "$ZERO" "$SEED"
git -C "$SEED" add .
git -C "$SEED" commit -q -m "release 0.4.0"
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q -u origin main
# main advances to 0.4.2 (this is what supersedes stale PRs branched from 0.4.0).
write_env "0.4.2" "$ONES" "$SEED"
git -C "$SEED" commit -q -am "release 0.4.2"
git -C "$SEED" push -q origin main

# Build a PR-head working clone whose active-release.env is $1/$2, run the
# extracted check with origin pointed at the shared bare remote.
run_supersession() {
  local pr_version="$1" pr_sha="$2" out="$3"
  local work="${TMP}/pr-$$-${RANDOM}"
  git clone -q "$REMOTE" "$work"
  write_env "$pr_version" "$pr_sha" "$work"
  : > "$out"
  (
    cd "$work" &&
      BASE_REF="main" ORDER_SCRIPT="$ORDER" \
      bash "$CHECK_SCRIPT" >"$out" 2>&1
  )
  local rc=$?
  rm -rf "$work"
  return $rc
}

# A genuinely newer PR (0.4.3) over current main (0.4.2): passes.
if run_supersession "0.4.3" "$ONES" "${TMP}/newer.out"; then
  assert_contains "$(cat "${TMP}/newer.out")" "does not regress" \
    "a newer PR than current main passes the supersession check"
else
  harness_fail "newer PR unexpectedly failed supersession: $(cat "${TMP}/newer.out")"
fi

# A stale PR (0.4.1) branched before main advanced to 0.4.2: rejected.
if run_supersession "0.4.1" "$ONES" "${TMP}/stale.out"; then
  harness_fail "a superseded PR unexpectedly passed the supersession check"
else
  assert_contains "$(cat "${TMP}/stale.out")" "has been superseded" \
    "a stale/superseded PR is rejected at merge time"
fi

# A PR that keeps main's version with the same checksum: no regression, passes.
if run_supersession "0.4.2" "$ONES" "${TMP}/equal_same.out"; then
  assert_contains "$(cat "${TMP}/equal_same.out")" "does not regress" \
    "a PR matching current main with the same checksum passes"
else
  harness_fail "equal/same PR unexpectedly failed supersession: $(cat "${TMP}/equal_same.out")"
fi

# A PR that keeps main's version but changes the checksum: rejected loudly.
if run_supersession "0.4.2" "$ZERO" "${TMP}/equal_diff.out"; then
  harness_fail "a same-version checksum-conflict PR unexpectedly passed"
else
  assert_contains "$(cat "${TMP}/equal_diff.out")" "source must not be rewritten" \
    "a same-version checksum-conflict PR is rejected"
fi

if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$WORKFLOW"; then
    harness_ok "actionlint accepts the supersession check workflow"
  else
    harness_fail "actionlint rejected the supersession check workflow"
  fi
else
  echo "  skip: actionlint not available; static and functional checks completed."
fi

harness_summary
