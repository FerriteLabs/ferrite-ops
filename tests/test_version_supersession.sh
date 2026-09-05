#!/usr/bin/env bash
# Static and functional coverage for version-supersession.yml, the merge-time
# guard that prevents a stale version-sync PR from regressing the canonical
# active-release.env once main has advanced. The functional replay uses only
# temporary local Git repositories and plain directories (no network).
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
assert_contains "$CONTENT" "merge_group:" \
  "supersession check runs at merge-queue time"
assert_contains "$CONTENT" "workflow_run:" \
  "automated PR checks reconcile after Version Sync runs"
assert_contains "$CONTENT" "push:" \
  "automated PR checks reconcile whenever main advances"
assert_contains "$CONTENT" "active-release.env" \
  "supersession check is scoped to active-release.env changes"
assert_contains "$CONTENT" "contents: read" \
  "supersession check is read-only"
assert_contains "$CONTENT" "head.sha" \
  "supersession check reads the PR head, not the merge ref"
assert_contains "$CONTENT" '"$ORDER_SCRIPT" classify' \
  "supersession check classifies the PR against the base with the shared guard"
assert_contains "$CONTENT" "checks: write" \
  "automated PR reconciliation can attach a required check to the PR head"
assert_contains "$CONTENT" 'startswith("version-sync/")' \
  "reconciliation is limited to automated version-sync branches"
assert_contains "$CONTENT" 'repos/${REPOSITORY}/check-runs' \
  "reconciliation writes the supersession result to each PR head"

# --- Trust boundary: candidate vs trusted checkout --------------------------
assert_contains "$CONTENT" "path: candidate" \
  "the untrusted PR/merge-queue candidate is checked out into its own directory"
assert_contains "$CONTENT" "path: trusted" \
  "the trusted base branch is checked out into its own directory"
assert_contains "$CONTENT" "ORDER_SCRIPT: trusted/scripts/release-ordering.sh" \
  "the supersession check only ever invokes the trusted checkout's ordering script"
assert_contains "$CONTENT" "candidate/active-release.env" \
  "the candidate's active-release.env is read as data, from its own directory"
assert_contains "$CONTENT" "Checkout candidate (untrusted, data only)" \
  "the candidate checkout step is explicitly documented as data-only"
assert_contains "$CONTENT" "does not yet define active-release.env" \
  "the initial active-release bootstrap is allowed without executing candidate code"

# Scope-check: the supersession job's own YAML text must never reference the
# ordering script from the untrusted checkout root (only trusted/scripts/...).
SUPERSESSION_JOB_YAML="$(python3 - "$WORKFLOW" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
print(yaml.safe_dump(doc["jobs"]["supersession"]))
PYEOF
)"
assert_not_contains "$SUPERSESSION_JOB_YAML" "ORDER_SCRIPT: scripts/release-ordering.sh" \
  "the supersession job's own definition never wires the ordering script from the untrusted checkout root"

# --- Reconciliation concurrency and freshness -------------------------------
assert_contains "$CONTENT" "group: version-supersession-reconcile" \
  "reconciliation is serialized by a fixed concurrency group"
assert_contains "$CONTENT" "cancel-in-progress: true" \
  "an overlapping reconciliation run cancels a stale in-flight one"
assert_contains "$CONTENT" "Read current main tip immediately before classification" \
  "reconciliation re-reads main's tip immediately before classifying/posting"
assert_contains "$CONTENT" "git fetch --no-tags --depth=1 origin main" \
  "reconciliation fetches a fresh main tip rather than reusing the initial checkout"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  skip: python3/PyYAML unavailable; skipping supersession functional replay."
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CHECK_SCRIPT="${TMP}/check.sh"
MAIN_TIP_SCRIPT="${TMP}/main_tip.sh"
RECONCILE_SCRIPT="${TMP}/reconcile.sh"

extract_step() {
  local job="$1" step_name="$2" out="$3"
  python3 - "$WORKFLOW" "$job" "$step_name" "$out" <<'PYEOF'
import sys, yaml
wf_path, job, step_name, out_path = sys.argv[1:]
with open(wf_path) as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"][job]["steps"]
run = next(s["run"] for s in steps if s.get("name") == step_name)
with open(out_path, "w") as f:
    f.write(run)
PYEOF
}

if ! extract_step "supersession" "Reject a superseded active-release change" "$CHECK_SCRIPT"; then
  harness_fail "could not extract the supersession check step"
  harness_summary
  exit $?
fi
harness_ok "extracted the supersession check step from the workflow"

if ! extract_step "reconcile-automated-prs" "Read current main tip immediately before classification" "$MAIN_TIP_SCRIPT"; then
  harness_fail "could not extract the main-tip reconciliation step"
  harness_summary
  exit $?
fi
harness_ok "extracted the main-tip freshness step from the workflow"

if ! extract_step "reconcile-automated-prs" "Check every open automated version-sync PR" "$RECONCILE_SCRIPT"; then
  harness_fail "could not extract the automated PR reconciliation step"
  harness_summary
  exit $?
fi
harness_ok "extracted the automated PR reconciliation step from the workflow"

write_env() { printf 'FERRITE_VERSION=%s\nFERRITE_SOURCE_SHA256=%s\n' "$1" "$2" > "${3}/active-release.env"; }

# Build a plain candidate/trusted directory pair (no git needed for basic
# classification replay) and run the extracted check step against them.
run_supersession() {
  local pr_version="$1" pr_sha="$2" base_version="$3" base_sha="$4" out="$5"
  local work="${TMP}/case-$$-${RANDOM}"
  mkdir -p "${work}/candidate" "${work}/trusted/scripts"
  write_env "$pr_version" "$pr_sha" "${work}/candidate"
  write_env "$base_version" "$base_sha" "${work}/trusted"
  cp "$ORDER" "${work}/trusted/scripts/release-ordering.sh"
  chmod +x "${work}/trusted/scripts/release-ordering.sh"
  : > "$out"
  (
    cd "$work" &&
      BASE_REF="main" ORDER_SCRIPT="trusted/scripts/release-ordering.sh" \
      bash "$CHECK_SCRIPT" >"$out" 2>&1
  )
  local rc=$?
  rm -rf "$work"
  return $rc
}

# The first PR that introduces active-release.env has no canonical base value
# or trusted ordering script yet. It must pass without executing candidate code.
BOOTSTRAP_WORK="${TMP}/bootstrap-case"
mkdir -p "${BOOTSTRAP_WORK}/candidate" "${BOOTSTRAP_WORK}/trusted"
write_env "0.4.0" "$ONES" "${BOOTSTRAP_WORK}/candidate"
if (
  cd "$BOOTSTRAP_WORK" &&
    BASE_REF="main" ORDER_SCRIPT="trusted/scripts/release-ordering.sh" \
    bash "$CHECK_SCRIPT" >"${TMP}/bootstrap.out" 2>&1
); then
  assert_contains "$(cat "${TMP}/bootstrap.out")" "allowing its initial introduction" \
    "the first active-release.env introduction passes without a trusted base script"
else
  harness_fail "initial active-release.env introduction unexpectedly failed: $(cat "${TMP}/bootstrap.out")"
fi

# A genuinely newer PR (0.4.3) over current main (0.4.2): passes.
if run_supersession "0.4.3" "$ONES" "0.4.2" "$ONES" "${TMP}/newer.out"; then
  assert_contains "$(cat "${TMP}/newer.out")" "does not regress" \
    "a newer PR than current main passes the supersession check"
else
  harness_fail "newer PR unexpectedly failed supersession: $(cat "${TMP}/newer.out")"
fi

# A stale PR (0.4.1) branched before main advanced to 0.4.2: rejected.
if run_supersession "0.4.1" "$ONES" "0.4.2" "$ONES" "${TMP}/stale.out"; then
  harness_fail "a superseded PR unexpectedly passed the supersession check"
else
  assert_contains "$(cat "${TMP}/stale.out")" "has been superseded" \
    "a stale/superseded PR is rejected at merge time"
fi

# A PR that keeps main's version with the same checksum: no regression, passes.
if run_supersession "0.4.2" "$ONES" "0.4.2" "$ONES" "${TMP}/equal_same.out"; then
  assert_contains "$(cat "${TMP}/equal_same.out")" "does not regress" \
    "a PR matching current main with the same checksum passes"
else
  harness_fail "equal/same PR unexpectedly failed supersession: $(cat "${TMP}/equal_same.out")"
fi

# A PR that keeps main's version but changes the checksum: rejected loudly.
if run_supersession "0.4.2" "$ZERO" "0.4.2" "$ONES" "${TMP}/equal_diff.out"; then
  harness_fail "a same-version checksum-conflict PR unexpectedly passed"
else
  assert_contains "$(cat "${TMP}/equal_diff.out")" "source must not be rewritten" \
    "a same-version checksum-conflict PR is rejected"
fi

# --- Malicious PR: candidate replaces scripts/release-ordering.sh ----------
# A malicious PR ships its own scripts/release-ordering.sh that always claims
# NEWER (to bypass the guard) and leaves a marker proving it ran. Even though
# the candidate proposes an older version than main, the check must still
# reject it — because it must classify using ONLY the trusted checkout's
# script, never the candidate's.
MALICIOUS_MARKER="${TMP}/malicious-ran.marker"
rm -f "$MALICIOUS_MARKER"
MALICIOUS_WORK="${TMP}/malicious-case"
mkdir -p "${MALICIOUS_WORK}/candidate/scripts" "${MALICIOUS_WORK}/trusted/scripts"
write_env "0.3.0" "$ONES" "${MALICIOUS_WORK}/candidate"
write_env "0.4.2" "$ONES" "${MALICIOUS_WORK}/trusted"
cp "$ORDER" "${MALICIOUS_WORK}/trusted/scripts/release-ordering.sh"
chmod +x "${MALICIOUS_WORK}/trusted/scripts/release-ordering.sh"
python3 - "$MALICIOUS_WORK" "$MALICIOUS_MARKER" <<'PYEOF'
import sys, os, stat
work, marker = sys.argv[1:]
path = os.path.join(work, "candidate", "scripts", "release-ordering.sh")
script = "#!/usr/bin/env bash\ntouch " + marker + "\necho NEWER\nexit 0\n"
with open(path, "w") as f:
    f.write(script)
os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
PYEOF
MALICIOUS_OUT="${TMP}/malicious.out"
: > "$MALICIOUS_OUT"
(
  cd "$MALICIOUS_WORK" &&
    BASE_REF="main" ORDER_SCRIPT="trusted/scripts/release-ordering.sh" \
    bash "$CHECK_SCRIPT" >"$MALICIOUS_OUT" 2>&1
)
if [[ $? -eq 0 ]]; then
  harness_fail "a malicious PR's replaced release-ordering.sh unexpectedly bypassed the guard"
else
  assert_contains "$(cat "$MALICIOUS_OUT")" "has been superseded" \
    "a malicious PR is still correctly classified using the trusted script (real OLDER result)"
fi
if [[ -e "$MALICIOUS_MARKER" ]]; then
  harness_fail "the candidate's malicious release-ordering.sh was executed"
else
  harness_ok "the candidate's malicious release-ordering.sh was never executed"
fi
rm -rf "$MALICIOUS_WORK"

# --- Overlapping/stale reconciliation: main-tip freshness -------------------
# Simulate main advancing between two reconciliation reads. Each read must
# fetch and report the CURRENT tip, not a value cached from an earlier,
# now-stale checkout — this is what the concurrency+re-fetch design prevents.
REMOTE="${TMP}/origin.git"
git init -q --bare "$REMOTE"
SEED="${TMP}/seed"
git init -q -b main "$SEED"
git -C "$SEED" config user.name "Test User"
git -C "$SEED" config user.email "test@example.invalid"
write_env "0.4.0" "$ZERO" "$SEED"
git -C "$SEED" add .
git -C "$SEED" commit -q -m "release 0.4.0"
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q -u origin main

RECON_WORK="${TMP}/recon-checkout"
git clone -q "$REMOTE" "$RECON_WORK"

read_main_tip() {
  local out="$1"
  : > "$out"
  ( cd "$RECON_WORK" && GITHUB_OUTPUT="$out" bash "$MAIN_TIP_SCRIPT" >"${out}.log" 2>&1 )
}

# First reconciliation read: main is still at 0.4.0.
if read_main_tip "${TMP}/tip1.out"; then
  assert_contains "$(cat "${TMP}/tip1.out")" "version=0.4.0" \
    "the first reconciliation read reports main's current tip (0.4.0)"
else
  harness_fail "first main-tip read unexpectedly failed: $(cat "${TMP}/tip1.out.log")"
fi

# main advances to 0.4.2 — simulating a second, newer push/Version Sync
# completion racing an earlier, now-stale reconciliation attempt.
write_env "0.4.2" "$ONES" "$SEED"
git -C "$SEED" commit -q -am "release 0.4.2"
git -C "$SEED" push -q origin main

# A second reconciliation read from the SAME checkout must observe the
# fresh tip (0.4.2), not the value cached at clone time (0.4.0) — proving
# the guard re-fetches immediately before classification rather than
# trusting a possibly-stale earlier checkout.
if read_main_tip "${TMP}/tip2.out"; then
  assert_contains "$(cat "${TMP}/tip2.out")" "version=0.4.2" \
    "a later reconciliation read observes main's advanced tip (0.4.2), not a stale cached value"
else
  harness_fail "second main-tip read unexpectedly failed: $(cat "${TMP}/tip2.out.log")"
fi

# --- Reconciliation loop: malformed metadata does not block later PRs ------
RECONCILE_FIXTURE="${TMP}/reconcile-repo"
MOCK_BIN="${TMP}/mock-bin"
MOCK_CHECKS="${TMP}/checks.jsonl"
mkdir -p "$RECONCILE_FIXTURE" "$MOCK_BIN"
: > "$MOCK_CHECKS"
cat > "${MOCK_BIN}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"/pulls?state=open&per_page=100"*)
    printf '1\tsha-invalid\tversion-sync/invalid\n'
    printf '2\tsha-stale\tversion-sync/0.4.1\n'
    ;;
  *"ref=sha-invalid"*)
    printf 'FERRITE_VERSION=not-semver\nFERRITE_SOURCE_SHA256=%s\n' \
      '1111111111111111111111111111111111111111111111111111111111111111' | base64
    ;;
  *"ref=sha-stale"*)
    printf 'FERRITE_VERSION=0.4.1\nFERRITE_SOURCE_SHA256=%s\n' \
      '1111111111111111111111111111111111111111111111111111111111111111' | base64
    ;;
  *"/check-runs"*)
    payload="$(cat)"
    printf '%s' "$payload" | jq -c . >> "$MOCK_CHECKS"
    printf '{}\n'
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 1
    ;;
esac
MOCKEOF
chmod +x "${MOCK_BIN}/gh"

if (
  cd "$RECONCILE_FIXTURE" &&
    PATH="${MOCK_BIN}:$PATH" \
    MOCK_CHECKS="$MOCK_CHECKS" \
    GH_TOKEN="test-token" \
    REPOSITORY="ferritelabs/ferrite-ops" \
    ORDER_SCRIPT="$ORDER" \
    BASE_VERSION="0.4.2" \
    BASE_SHA256="$ONES" \
    bash "$RECONCILE_SCRIPT" >"${TMP}/reconcile.out" 2>&1
); then
  harness_fail "reconciliation unexpectedly succeeded despite malformed metadata"
else
  harness_ok "reconciliation reports malformed release metadata"
fi
assert_eq "2" "$(wc -l < "$MOCK_CHECKS" | tr -d ' ')" \
  "a malformed PR does not prevent later PRs from receiving checks"
assert_eq "2" "$(jq -r '.conclusion' "$MOCK_CHECKS" | grep -c '^failure$')" \
  "malformed and stale PRs both receive fail-closed checks"
assert_contains "$(cat "${TMP}/reconcile.out")" "PR #2: OLDER (failure)" \
  "reconciliation continues through the stale PR after an earlier error"

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
