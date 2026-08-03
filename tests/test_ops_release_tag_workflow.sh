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
  "ops tag workflow watches the primary release chart"
assert_contains "$CONTENT" "gitops/argocd/overlays/production.yaml" \
  "ops tag workflow watches production Argo CD revisions"
assert_contains "$CONTENT" "gitops/flux/overlays/production.yaml" \
  "ops tag workflow watches production Flux revisions"
assert_contains "$CONTENT" "contents: write" \
  "ops tag workflow requests the content permission needed to push a tag"
assert_not_contains "$CONTENT" "pull-requests:" \
  "ops tag workflow does not request pull-request permissions"
assert_not_contains "$CONTENT" "packages:" \
  "ops tag workflow does not request package permissions"
assert_contains "$CONTENT" "git tag -a" \
  "ops tag workflow creates an annotated tag"
assert_contains "$CONTENT" 'git push origin "refs/tags/${OPS_TAG}"' \
  "ops tag workflow pushes only the immutable tag ref"
assert_contains "$CONTENT" "git ls-remote --exit-code --tags origin" \
  "ops tag workflow refuses an existing remote tag"
assert_not_contains "$CONTENT" "git tag -f" \
  "ops tag workflow never force-replaces a tag"
assert_not_contains "$CONTENT" "git push --force" \
  "ops tag workflow never force-pushes a tag"
assert_not_contains "$CONTENT" "targetRevision: HEAD" \
  "ops tag workflow never validates a mutable Argo CD revision"

if ! command -v python3 >/dev/null 2>&1 ||
  ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  skip: python3/PyYAML unavailable; skipping workflow extraction replay."
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
VALIDATE_SCRIPT="${TMP}/validate.sh"
TAG_SCRIPT="${TMP}/tag.sh"
if python3 - "$WORKFLOW" "$VALIDATE_SCRIPT" "$TAG_SCRIPT" <<'PYEOF'
import sys
import yaml

workflow_path, validate_path, tag_path = sys.argv[1:]
with open(workflow_path) as workflow_file:
    workflow = yaml.safe_load(workflow_file)

trigger = workflow.get(True, {}).get("push", {})
if trigger.get("branches") != ["main"]:
    raise SystemExit("tag workflow must trigger only on main")

permissions = workflow.get("permissions", {})
if permissions != {"contents": "write"}:
    raise SystemExit(f"tag workflow permissions are not least-privilege: {permissions}")

steps = workflow["jobs"]["tag"]["steps"]
validate = next(
    step["run"] for step in steps if step.get("name") == "Validate canonical ops release"
)
tag = next(
    step["run"]
    for step in steps
    if step.get("name") == "Create and push immutable annotated tag"
)
with open(validate_path, "w") as output:
    output.write(validate)
with open(tag_path, "w") as output:
    output.write(tag)
PYEOF
then
  harness_ok "ops tag workflow has the expected trigger, permissions, and executable steps"
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
OUTPUT="${TMP}/release.out"
: > "$OUTPUT"

if (
  cd "$FIXTURE" &&
    MERGED_SHA="$MERGED_SHA" GITHUB_OUTPUT="$OUTPUT" bash "$VALIDATE_SCRIPT"
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
    MERGED_SHA="$MERGED_SHA" GITHUB_OUTPUT="${TMP}/drift.out" bash "$VALIDATE_SCRIPT"
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
