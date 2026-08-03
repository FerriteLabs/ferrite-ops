#!/usr/bin/env bash
# Prevents active deployment/release defaults from drifting behind Ferrite.
# Historical changelogs, migration notes, and version-scoped compatibility
# guards are intentionally outside this active-file allowlist.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

EXPECTED_VERSION="0.4.0"
EXPECTED_SHA256="b4db8cc8eb0d3c2cef4a019a47d550c347df69fb8a4f77550c814fae463005cf"

for dockerfile in Dockerfile Dockerfile.moonshot Dockerfile.playground; do
  path="${REPO_ROOT}/${dockerfile}"
  version="$(grep -oE '^ARG FERRITE_VERSION=[0-9A-Za-z.+-]+' "$path" | cut -d= -f2)"
  checksum="$(grep -oE '^ARG FERRITE_SOURCE_SHA256=[0-9a-f]+' "$path" | cut -d= -f2)"
  assert_eq "$EXPECTED_VERSION" "$version" "${dockerfile} defaults to Ferrite ${EXPECTED_VERSION}"
  assert_eq "$EXPECTED_SHA256" "$checksum" "${dockerfile} defaults to the matching v${EXPECTED_VERSION} checksum"
done

PRIMARY_CHART="${REPO_ROOT}/charts/ferrite/Chart.yaml"
SIDECAR_CHART="${REPO_ROOT}/charts/ferrite-sidecar/Chart.yaml"
assert_contains "$(cat "$PRIMARY_CHART")" "version: ${EXPECTED_VERSION}" \
  "primary Helm chart version tracks the current release"
assert_contains "$(cat "$PRIMARY_CHART")" "appVersion: \"${EXPECTED_VERSION}\"" \
  "primary Helm appVersion tracks the current Ferrite image"
assert_contains "$(cat "$SIDECAR_CHART")" "appVersion: \"${EXPECTED_VERSION}\"" \
  "sidecar appVersion tracks the Ferrite image while its chart version remains independent"

ACTIVE_FILES=(
  ".github/workflows/release.yml"
  "docker-compose.quickstart.yml"
  "docker-compose.moonshot.yml"
  "gitops/argocd/overlays/production.yaml"
  "gitops/flux/overlays/production.yaml"
  "terraform/README.md"
  "terraform/aws-ecs/main.tf"
  "terraform/aws-eks/main.tf"
  "terraform/common/variables.tf"
)

STALE_MATCHES=""
for relative_path in "${ACTIVE_FILES[@]}"; do
  path="${REPO_ROOT}/${relative_path}"
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    STALE_MATCHES+="${relative_path}:${match}"$'\n'
  done < <(grep -nE 'v?0\.[23]\.0' "$path" || true)
done

assert_eq "" "$STALE_MATCHES" \
  "active release/deployment files contain no stale v0.2.0 or v0.3.0 defaults"

harness_summary
