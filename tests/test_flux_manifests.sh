#!/usr/bin/env bash
# Ensures every Flux deployment uses GHCR and that production remains pinned
# to the canonical active image and immutable ferrite-ops source revision.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

EXPECTED_VERSION="$(sed -n 's/^FERRITE_VERSION=//p' "${REPO_ROOT}/active-release.env")"
EXPECTED_REPOSITORY="ghcr.io/ferritelabs/ferrite"
FLUX_FILES=(
  gitops/flux/helmrelease.yaml
  gitops/flux/overlays/staging.yaml
  gitops/flux/overlays/production.yaml
)

for relative in "${FLUX_FILES[@]}"; do
  path="${REPO_ROOT}/${relative}"
  assert_eq "1" "$(grep -c "repository: ${EXPECTED_REPOSITORY}" "$path")" \
    "${relative} uses the canonical GHCR image repository exactly once"
  assert_eq "0" "$(grep -c 'repository: ferritelabs/ferrite' "$path")" \
    "${relative} does not depend on the optional Docker Hub registry"
done

PRODUCTION="${REPO_ROOT}/gitops/flux/overlays/production.yaml"
assert_contains "$(cat "$PRODUCTION")" "tag: ferrite-ops-v${EXPECTED_VERSION}" \
  "Flux production pins the immutable canonical ops revision"
assert_contains "$(cat "$PRODUCTION")" "tag: \"${EXPECTED_VERSION}\"" \
  "Flux production pins the canonical active image tag"
assert_not_contains "$(cat "$PRODUCTION")" "branch: main" \
  "Flux production never follows mutable main"

if command -v python3 >/dev/null 2>&1 &&
  python3 -c "import yaml" >/dev/null 2>&1; then
  if python3 - "${FLUX_FILES[@]/#/${REPO_ROOT}/}" "$EXPECTED_REPOSITORY" \
    "$EXPECTED_VERSION" <<'PYEOF'
import sys
import yaml

*paths, expected_repository, expected_version = sys.argv[1:]
for path in paths:
    with open(path) as manifest:
        documents = list(yaml.safe_load_all(manifest))
    release = next(document for document in documents if document["kind"] == "HelmRelease")
    image = release["spec"]["values"]["image"]
    if image["repository"] != expected_repository:
        raise SystemExit(f"{path}: unexpected repository {image['repository']}")
    if path.endswith("production.yaml") and image["tag"] != expected_version:
        raise SystemExit(f"{path}: production tag is {image['tag']}")
PYEOF
  then
    harness_ok "all Flux manifests parse and expose the expected image values"
  else
    harness_fail "Flux manifests did not parse to the expected image values"
  fi
else
  echo "  skip: python3/PyYAML unavailable; static Flux checks completed."
fi

if command -v helm >/dev/null 2>&1; then
  if RENDERED="$(helm template ferrite "${REPO_ROOT}/charts/ferrite" \
    --set "image.repository=${EXPECTED_REPOSITORY}" \
    --set "image.tag=${EXPECTED_VERSION}" 2>&1)"; then
    assert_contains "$RENDERED" "image: ${EXPECTED_REPOSITORY}:${EXPECTED_VERSION}" \
      "Flux production image values render to the canonical GHCR image"
  else
    harness_fail "Helm could not render the Flux production image values: ${RENDERED}"
  fi
else
  echo "  skip: helm not available; rendered Flux image assertion skipped."
fi

harness_summary
