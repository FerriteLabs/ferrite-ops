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
assert_contains "$CONTENT" '"refs/tags/${OPS_TAG}:refs/tags/${OPS_TAG}"' \
  "ops tag workflow pushes only the immutable tag ref"
assert_contains "$CONTENT" "git ls-remote --exit-code --tags origin" \
  "ops tag workflow refuses an existing remote tag"
assert_not_contains "$CONTENT" "git tag -f" \
  "ops tag workflow never force-replaces a tag"
assert_not_contains "$CONTENT" "git push --force" \
  "ops tag workflow never force-pushes a tag"
assert_not_contains "$CONTENT" "--force-with-lease" \
  "ops tag workflow does not use a misleading lease on unchanged main"
assert_not_contains "$CONTENT" ":refs/heads/main" \
  "ops tag workflow never includes main in the tag push"
assert_not_contains "$CONTENT" "targetRevision: HEAD" \
  "ops tag workflow never validates a mutable Argo CD revision"

# --- Trigger scoping, immutable target, and concurrency ---------------------
assert_contains "$CONTENT" "group: ferrite-ops-tag-" \
  "ops tag workflow serializes tagging with a version-keyed concurrency group"
assert_contains "$CONTENT" "cancel-in-progress: false" \
  "ops tag workflow never cancels an in-flight tag push"
assert_eq "2" "$(grep -c 'ref: \${{ github.sha }}' "$WORKFLOW")" \
  "both ops tag jobs explicitly check out the immutable push event SHA"
assert_not_contains "$CONTENT" "origin/main" \
  "ops tag workflow never rebinds its deterministic target to a later main tip"
assert_contains "$CONTENT" "resolve:" \
  "ops tag workflow resolves the canonical version in its own job"
assert_contains "$CONTENT" "needs.resolve.outputs.version" \
  "ops tag workflow keys its concurrency group on the resolved canonical version"
assert_eq "1" "$(grep -c 'VERSION="${RAW_VERSION#v}"' "$WORKFLOW")" \
  "ops tag workflow normalizes an optional leading v exactly once"

if ! command -v python3 >/dev/null 2>&1 ||
  ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  skip: python3/PyYAML unavailable; skipping workflow extraction replay."
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RESOLVE_SCRIPT="${TMP}/resolve.sh"
VALIDATE_SCRIPT="${TMP}/validate.sh"
TAG_SCRIPT="${TMP}/tag.sh"
if python3 - "$WORKFLOW" "$RESOLVE_SCRIPT" "$VALIDATE_SCRIPT" "$TAG_SCRIPT" <<'PYEOF'
import sys
import yaml

workflow_path, resolve_path, validate_path, tag_path = sys.argv[1:]
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

# The single normalization point accepts both canonical spellings and emits
# the same bare SemVer used by concurrency and all downstream validation.
PREFIXED_FIXTURE="${TMP}/prefixed-fixture"
cp -R "$FIXTURE" "$PREFIXED_FIXTURE"
sed -i.bak "s/^FERRITE_VERSION=.*/FERRITE_VERSION=v${EXPECTED_VERSION}/" "${PREFIXED_FIXTURE}/active-release.env"
rm -f "${PREFIXED_FIXTURE}/active-release.env.bak"
if (
  cd "$PREFIXED_FIXTURE" &&
    GITHUB_OUTPUT="${TMP}/prefixed_resolve.out" \
      ORDER_SCRIPT="${REPO_ROOT}/scripts/release-ordering.sh" bash "$RESOLVE_SCRIPT"
); then
  assert_contains "$(cat "${TMP}/prefixed_resolve.out")" "version=${EXPECTED_VERSION}" \
    "resolve job normalizes a v-prefixed canonical version exactly once"
else
  harness_fail "resolve job unexpectedly rejected a valid v-prefixed canonical version"
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
LEADING_ZERO_CORE_FIXTURE="${TMP}/leading-zero-core-fixture"
cp -R "$FIXTURE" "$LEADING_ZERO_CORE_FIXTURE"
sed -i.bak "s/^FERRITE_VERSION=.*/FERRITE_VERSION=01.2.3/" "${LEADING_ZERO_CORE_FIXTURE}/active-release.env"
rm -f "${LEADING_ZERO_CORE_FIXTURE}/active-release.env.bak"
if (
  cd "$LEADING_ZERO_CORE_FIXTURE" &&
    GITHUB_OUTPUT="${TMP}/leading_zero_core_resolve.out" \
      ORDER_SCRIPT="${REPO_ROOT}/scripts/release-ordering.sh" bash "$RESOLVE_SCRIPT"
) >"${TMP}/leading_zero_core_resolve.log" 2>&1; then
  harness_fail "resolve job unexpectedly accepted a leading-zero version core (01.2.3)"
else
  assert_contains "$(cat "${TMP}/leading_zero_core_resolve.log")" "strict SemVer" \
    "resolve job rejects a leading-zero version core via the shared validator"
fi

# Advance main after the triggering push. The workflow must still validate
# and tag MERGED_SHA because github.sha is the immutable release-metadata
# merge commit; an unrelated later main advance cannot change that target.
echo "later change" >> "${FIXTURE}/active-release.env.later"
git -C "$FIXTURE" add active-release.env.later
git -C "$FIXTURE" commit -q -m "an unrelated later main advance"
git -C "$FIXTURE" push -q origin main
git -C "$FIXTURE" reset -q --hard "$MERGED_SHA"

OUTPUT="${TMP}/release.out"
: > "$OUTPUT"

if (
  cd "$FIXTURE" &&
    MERGED_SHA="$MERGED_SHA" VERSION="$EXPECTED_VERSION" GITHUB_OUTPUT="$OUTPUT" \
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
    "later unrelated main advances do not change the deterministic tag target"
else
  harness_fail "immutable ops tag creation unexpectedly failed"
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
    "same-version duplicate events cannot overwrite the existing remote tag"
  assert_eq "$MERGED_SHA" \
    "$(git --git-dir="$REMOTE" rev-parse "refs/tags/${EXPECTED_TAG}^{}")" \
    "a rejected duplicate leaves the immutable tag target unchanged"
fi

sed -i.bak "s/appVersion: \"${EXPECTED_VERSION}\"/appVersion: \"9.9.9\"/" \
  "${FIXTURE}/charts/ferrite/Chart.yaml"
rm -f "${FIXTURE}/charts/ferrite/Chart.yaml.bak"
if (
  cd "$FIXTURE" &&
    MERGED_SHA="$MERGED_SHA" VERSION="$EXPECTED_VERSION" GITHUB_OUTPUT="${TMP}/drift.out" \
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
