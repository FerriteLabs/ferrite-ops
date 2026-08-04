#!/usr/bin/env bash
# Static and functional coverage for the immutable ferrite-ops release tag
# workflow. The functional replay uses only temporary local Git repositories.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

WORKFLOW="${REPO_ROOT}/.github/workflows/tag-ops-release.yml"
ACTIVE_RELEASE="${REPO_ROOT}/active-release.env"
CONTENT="$(cat "$WORKFLOW")"
EXPECTED_VERSION="$(sed -n 's/^FERRITE_VERSION=//p' "$ACTIVE_RELEASE")"
EXPECTED_TAG="ferrite-ops-v${EXPECTED_VERSION}"

assert_contains "$CONTENT" "branches: [main]" \
  "ops tag workflow runs only for pushes to main"
assert_contains "$CONTENT" "active-release.env" \
  "ops tag workflow is triggered by canonical release metadata changes"
assert_contains "$CONTENT" "charts/ferrite/Chart.yaml" \
  "ops tag workflow validates the primary release chart against canonical metadata before tagging"
assert_contains "$CONTENT" "gitops/argocd/overlays/production.yaml" \
  "ops tag workflow validates production Argo CD revisions before tagging"
assert_contains "$CONTENT" "gitops/flux/overlays/production.yaml" \
  "ops tag workflow validates production Flux revisions before tagging"
assert_contains "$CONTENT" "contents: write" \
  "ops tag workflow requests the content permission needed to push a tag"
assert_not_contains "$CONTENT" "pull-requests:" \
  "ops tag workflow does not request pull-request permissions"
assert_not_contains "$CONTENT" "packages:" \
  "ops tag workflow does not request package permissions"
assert_contains "$CONTENT" "git tag -a" \
  "ops tag workflow creates an annotated tag"
assert_contains "$CONTENT" 'git push --atomic \' \
  "ops tag workflow pushes atomically"
assert_contains "$CONTENT" '--force-with-lease="refs/heads/main:${MERGED_SHA}"' \
  "ops tag workflow's push carries a compare-and-swap lease on refs/heads/main"
assert_contains "$CONTENT" '"${MERGED_SHA}:refs/heads/main"' \
  "ops tag workflow's atomic push includes a same-commit main ref update to carry the lease check"
assert_contains "$CONTENT" '"refs/tags/${OPS_TAG}"' \
  "ops tag workflow's atomic push includes the immutable tag ref"
assert_contains "$CONTENT" "git ls-remote --exit-code --tags origin" \
  "ops tag workflow refuses an existing remote tag"
assert_not_contains "$CONTENT" "git tag -f" \
  "ops tag workflow never force-replaces a tag"
assert_not_contains "$CONTENT" "git push --force" \
  "ops tag workflow never force-pushes a tag"
assert_not_contains "$CONTENT" "targetRevision: HEAD" \
  "ops tag workflow never validates a mutable Argo CD revision"

# --- Trigger scoping, concurrency, and main-tip validation ------------------
assert_contains "$CONTENT" "group: ferrite-ops-tag-" \
  "ops tag workflow serializes tagging with a version-keyed concurrency group"
assert_contains "$CONTENT" "cancel-in-progress: false" \
  "ops tag workflow never cancels an in-flight tag push"
assert_contains "$CONTENT" "Validate this push is still the current main tip" \
  "ops tag workflow re-validates main's tip immediately before tagging"
assert_contains "$CONTENT" "git rev-parse origin/main" \
  "ops tag workflow reads the current remote main tip, not a cached value"
assert_contains "$CONTENT" "already superseded this one" \
  "ops tag workflow explains that a superseded push is refused"
assert_contains "$CONTENT" "resolve:" \
  "ops tag workflow resolves the canonical version in its own job"
assert_contains "$CONTENT" "needs.resolve.outputs.version" \
  "ops tag workflow keys its concurrency group on the resolved canonical version"

if ! command -v python3 >/dev/null 2>&1 ||
  ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  skip: python3/PyYAML unavailable; skipping workflow extraction replay."
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RESOLVE_SCRIPT="${TMP}/resolve.sh"
MAIN_TIP_SCRIPT="${TMP}/main_tip.sh"
VALIDATE_SCRIPT="${TMP}/validate.sh"
TAG_SCRIPT="${TMP}/tag.sh"
if python3 - "$WORKFLOW" "$RESOLVE_SCRIPT" "$MAIN_TIP_SCRIPT" "$VALIDATE_SCRIPT" "$TAG_SCRIPT" <<'PYEOF'
import sys
import yaml

workflow_path, resolve_path, main_tip_path, validate_path, tag_path = sys.argv[1:]
with open(workflow_path) as workflow_file:
    workflow = yaml.safe_load(workflow_file)

trigger = workflow.get(True, {}).get("push", {})
if trigger.get("branches") != ["main"]:
    raise SystemExit("tag workflow must trigger only on main")
if trigger.get("paths") != ["active-release.env"]:
    raise SystemExit(
        f"tag workflow must trigger ONLY on active-release.env changes, got: {trigger.get('paths')}"
    )

permissions = workflow.get("permissions", {})
if permissions != {"contents": "write"}:
    raise SystemExit(f"tag workflow permissions are not least-privilege: {permissions}")

resolve_steps = workflow["jobs"]["resolve"]["steps"]
resolve = next(
    step["run"] for step in resolve_steps if step.get("name") == "Read canonical version from this push"
)

tag_job = workflow["jobs"]["tag"]
if tag_job.get("needs") != "resolve":
    raise SystemExit("tag job must depend on the resolve job")
concurrency = tag_job.get("concurrency", {})
if "needs.resolve.outputs.version" not in concurrency.get("group", ""):
    raise SystemExit("tag job's concurrency group must be keyed on the resolved version")
if concurrency.get("cancel-in-progress") is not False:
    raise SystemExit("tag job's concurrency group must not cancel an in-flight tag push")

steps = tag_job["steps"]
main_tip = next(
    step["run"] for step in steps if step.get("name") == "Validate this push is still the current main tip"
)
validate = next(
    step["run"] for step in steps if step.get("name") == "Validate canonical ops release"
)
tag = next(
    step["run"]
    for step in steps
    if step.get("name") == "Create and push immutable annotated tag"
)
with open(resolve_path, "w") as output:
    output.write(resolve)
with open(main_tip_path, "w") as output:
    output.write(main_tip)
with open(validate_path, "w") as output:
    output.write(validate)
with open(tag_path, "w") as output:
    output.write(tag)
PYEOF
then
  harness_ok "ops tag workflow has the expected trigger, permissions, job split, and concurrency"
else
  harness_fail "ops tag workflow extraction failed"
  harness_summary
  exit $?
fi

FIXTURE="${TMP}/fixture"
REMOTE="${TMP}/origin.git"
mkdir -p "$FIXTURE"
for target in \
  active-release.env \
  Dockerfile \
  Dockerfile.moonshot \
  Dockerfile.playground \
  charts/ferrite/Chart.yaml \
  charts/ferrite-sidecar/Chart.yaml \
  gitops/argocd/overlays/production.yaml \
  gitops/flux/overlays/production.yaml; do
  mkdir -p "${FIXTURE}/$(dirname "$target")"
  cp "${REPO_ROOT}/${target}" "${FIXTURE}/${target}"
done

git init -q -b main "$FIXTURE"
git -C "$FIXTURE" config user.name "Test User"
git -C "$FIXTURE" config user.email "test@example.invalid"
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -q -m "test fixture"
git init -q --bare "$REMOTE"
git -C "$FIXTURE" remote add origin "$REMOTE"
git -C "$FIXTURE" push -q -u origin main
MERGED_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"

# --- resolve job: reads the canonical version from this exact push ---------
RESOLVE_OUT="${TMP}/resolve.out"
if ( cd "$FIXTURE" && GITHUB_OUTPUT="$RESOLVE_OUT" ORDER_SCRIPT="${REPO_ROOT}/scripts/release-ordering.sh" bash "$RESOLVE_SCRIPT" ); then
  assert_contains "$(cat "$RESOLVE_OUT")" "version=${EXPECTED_VERSION}" \
    "resolve job emits the canonical version for this push"
else
  harness_fail "resolve job unexpectedly failed"
fi

# --- resolve job: strict SemVer via the shared validator, not a locally
# duplicated regex -- rejects a leading zero in the core or in a numeric
# pre-release identifier, which the OLD locally duplicated regex accepted.
LEADING_ZERO_FIXTURE="${TMP}/leading-zero-fixture"
cp -R "$FIXTURE" "$LEADING_ZERO_FIXTURE"
sed -i.bak "s/^FERRITE_VERSION=.*/FERRITE_VERSION=1.2.3-01/" "${LEADING_ZERO_FIXTURE}/active-release.env"
rm -f "${LEADING_ZERO_FIXTURE}/active-release.env.bak"
if (
  cd "$LEADING_ZERO_FIXTURE" &&
    GITHUB_OUTPUT="${TMP}/leading_zero_resolve.out" \
      ORDER_SCRIPT="${REPO_ROOT}/scripts/release-ordering.sh" bash "$RESOLVE_SCRIPT"
) >"${TMP}/leading_zero_resolve.log" 2>&1; then
  harness_fail "resolve job unexpectedly accepted a leading-zero numeric pre-release identifier (1.2.3-01)"
else
  assert_contains "$(cat "${TMP}/leading_zero_resolve.log")" "strict SemVer" \
    "resolve job rejects a leading-zero numeric pre-release identifier via the shared validator"
fi

# --- main-tip validation: passes when this push IS the current tip ---------
if ( cd "$FIXTURE" && MERGED_SHA="$MERGED_SHA" bash "$MAIN_TIP_SCRIPT" >"${TMP}/tip_ok.log" 2>&1 ); then
  harness_ok "main-tip validation passes when this push is still main's current tip"
else
  harness_fail "main-tip validation unexpectedly failed: $(cat "${TMP}/tip_ok.log")"
fi

# --- main-tip validation: fails when main has since advanced ---------------
# Simulate a second, later push landing on main (e.g. a rapid follow-up
# release) between this workflow starting and reaching the tagging step.
echo "later change" >> "${FIXTURE}/active-release.env.later"
git -C "$FIXTURE" add active-release.env.later
git -C "$FIXTURE" commit -q -m "a later push supersedes the one being validated"
git -C "$FIXTURE" push -q origin main
if ( cd "$FIXTURE" && MERGED_SHA="$MERGED_SHA" bash "$MAIN_TIP_SCRIPT" >"${TMP}/tip_stale.log" 2>&1 ); then
  harness_fail "main-tip validation unexpectedly passed for a superseded push"
else
  assert_contains "$(cat "${TMP}/tip_stale.log")" "already superseded this one" \
    "main-tip validation refuses to tag a push that main (now at a newer commit) has since advanced past"
fi
# Reset the fixture back to the originally merged commit for the remaining
# tag-creation replays below, which validate tagging the ORIGINAL commit.
git -C "$FIXTURE" reset -q --hard "$MERGED_SHA"
git -C "$FIXTURE" push -q --force-with-lease origin main

OUTPUT="${TMP}/release.out"
: > "$OUTPUT"

if (
  cd "$FIXTURE" &&
    MERGED_SHA="$MERGED_SHA" GITHUB_OUTPUT="$OUTPUT" \
      ORDER_SCRIPT="${REPO_ROOT}/scripts/release-ordering.sh" bash "$VALIDATE_SCRIPT"
); then
  assert_contains "$(cat "$OUTPUT")" "version=${EXPECTED_VERSION}" \
    "canonical validation emits the active version"
  assert_contains "$(cat "$OUTPUT")" "tag=${EXPECTED_TAG}" \
    "canonical validation emits the immutable ops tag"
else
  harness_fail "canonical ops release validation unexpectedly failed"
fi

if (
  cd "$FIXTURE" &&
    MERGED_SHA="$MERGED_SHA" VERSION="$EXPECTED_VERSION" OPS_TAG="$EXPECTED_TAG" \
      bash "$TAG_SCRIPT"
); then
  assert_eq "tag" "$(git -C "$FIXTURE" cat-file -t "refs/tags/${EXPECTED_TAG}")" \
    "functional replay creates an annotated tag object"
  assert_eq "$MERGED_SHA" \
    "$(git --git-dir="$REMOTE" rev-parse "refs/tags/${EXPECTED_TAG}^{}")" \
    "functional replay pushes the tag at the merged commit"
else
  harness_fail "immutable ops tag creation unexpectedly failed"
fi


# --- Atomic push: main advances AFTER validation, but BEFORE the push ------
# Simulates the exact race item 5 hardens against: this run's earlier
# validation steps (main-tip check, canonical release validation) both
# passed against MERGED_SHA, but a second, independent push lands on origin
# main strictly between that validation and this run's own tag-creation
# step actually executing its push. The lease-guarded atomic push below must
# reject the push (and therefore never create the tag) even though nothing
# in THIS run's own local state changed — the earlier, separate main-tip
# pre-check cannot observe a race that happens after it already ran.
RACE_VERSION="9.9.9-race.1"
RACE_TAG="ferrite-ops-v${RACE_VERSION}"
RACE_MERGED_SHA="$(git --git-dir="$REMOTE" rev-parse refs/heads/main)"

RACE_CLONE="${TMP}/race-clone"
git clone -q "$REMOTE" "$RACE_CLONE"
git -C "$RACE_CLONE" config user.name "Other Workflow Run"
git -C "$RACE_CLONE" config user.email "other@example.invalid"
echo "a concurrent, independent push lands on main mid-race" >> "${RACE_CLONE}/active-release.env.race"
git -C "$RACE_CLONE" add active-release.env.race
git -C "$RACE_CLONE" commit -q -m "concurrent push that advances main mid-race"
git -C "$RACE_CLONE" push -q origin main
ADVANCED_SHA="$(git --git-dir="$REMOTE" rev-parse refs/heads/main)"
if [ "$ADVANCED_SHA" = "$RACE_MERGED_SHA" ]; then
  harness_fail "race fixture setup did not actually advance origin/main"
fi

if (
  cd "$FIXTURE" &&
    MERGED_SHA="$RACE_MERGED_SHA" VERSION="$RACE_VERSION" OPS_TAG="$RACE_TAG" \
      bash "$TAG_SCRIPT" >"${TMP}/race.log" 2>&1
); then
  harness_fail "atomic push unexpectedly succeeded after main advanced mid-race"
else
  assert_contains "$(cat "${TMP}/race.log")" "Atomic push rejected" \
    "the atomic lease-guarded push rejects a tag creation when main advanced between validation and push"
fi
if git ls-remote --exit-code --tags "$REMOTE" "refs/tags/${RACE_TAG}" >/dev/null 2>&1; then
  harness_fail "a rejected atomic push still left the tag behind on origin"
else
  harness_ok "a rejected atomic push leaves no tag behind on origin"
fi

git -C "$FIXTURE" tag -d "$EXPECTED_TAG" >/dev/null
if (
  cd "$FIXTURE" &&
    MERGED_SHA="$MERGED_SHA" VERSION="$EXPECTED_VERSION" OPS_TAG="$EXPECTED_TAG" \
      bash "$TAG_SCRIPT" >"${TMP}/duplicate.log" 2>&1
); then
  harness_fail "ops tag workflow unexpectedly overwrote an existing remote tag"
else
  assert_contains "$(cat "${TMP}/duplicate.log")" "already exists on origin" \
    "ops tag workflow clearly refuses an existing remote tag"
fi

sed -i.bak "s/appVersion: \"${EXPECTED_VERSION}\"/appVersion: \"9.9.9\"/" \
  "${FIXTURE}/charts/ferrite/Chart.yaml"
rm -f "${FIXTURE}/charts/ferrite/Chart.yaml.bak"
if (
  cd "$FIXTURE" &&
    MERGED_SHA="$MERGED_SHA" GITHUB_OUTPUT="${TMP}/drift.out" \
      ORDER_SCRIPT="${REPO_ROOT}/scripts/release-ordering.sh" bash "$VALIDATE_SCRIPT"
); then
  harness_fail "ops tag validation unexpectedly accepted chart/appVersion drift"
else
  harness_ok "ops tag validation rejects chart/appVersion drift before tagging"
fi

if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$WORKFLOW"; then
    harness_ok "actionlint accepts the immutable ops tag workflow"
  else
    harness_fail "actionlint rejected the immutable ops tag workflow"
  fi
else
  echo "  skip: actionlint not available; PyYAML/static/functional checks completed."
fi

harness_summary
