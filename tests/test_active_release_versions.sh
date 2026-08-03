#!/usr/bin/env bash
# Prevents active deployment and release defaults from drifting away from the
# machine-readable active-release.env source of truth. Historical changelogs,
# migration notes, and version-scoped compatibility guards are deliberately
# outside this active-file allowlist.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

ACTIVE_RELEASE="${REPO_ROOT}/active-release.env"
if [[ ! -f "$ACTIVE_RELEASE" ]]; then
  echo "  FAIL: ${ACTIVE_RELEASE} not found" >&2
  exit 1
fi

assert_eq "1" "$(grep -c '^FERRITE_VERSION=' "$ACTIVE_RELEASE")" \
  "active-release.env defines FERRITE_VERSION exactly once"
assert_eq "1" "$(grep -c '^FERRITE_SOURCE_SHA256=' "$ACTIVE_RELEASE")" \
  "active-release.env defines FERRITE_SOURCE_SHA256 exactly once"
EXPECTED_VERSION="$(sed -n 's/^FERRITE_VERSION=//p' "$ACTIVE_RELEASE")"
EXPECTED_SHA256="$(sed -n 's/^FERRITE_SOURCE_SHA256=//p' "$ACTIVE_RELEASE")"
if ! printf '%s\n' "$EXPECTED_VERSION" |
  grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'; then
  harness_fail "active-release.env contains a valid semver version"
fi
if ! printf '%s\n' "$EXPECTED_SHA256" | grep -qE '^[0-9a-f]{64}$'; then
  harness_fail "active-release.env contains a lowercase 64-character source SHA256"
fi

for dockerfile in Dockerfile Dockerfile.moonshot Dockerfile.playground; do
  path="${REPO_ROOT}/${dockerfile}"
  version="$(grep -oE '^ARG FERRITE_VERSION=[0-9A-Za-z.+-]+' "$path" | cut -d= -f2)"
  checksum="$(grep -oE '^ARG FERRITE_SOURCE_SHA256=[0-9a-f]+' "$path" | cut -d= -f2)"
  assert_eq "$EXPECTED_VERSION" "$version" "${dockerfile} matches active-release.env version"
  assert_eq "$EXPECTED_SHA256" "$checksum" "${dockerfile} matches active-release.env source checksum"
done

PRIMARY_CHART="${REPO_ROOT}/charts/ferrite/Chart.yaml"
SIDECAR_CHART="${REPO_ROOT}/charts/ferrite-sidecar/Chart.yaml"
assert_contains "$(cat "$PRIMARY_CHART")" "version: ${EXPECTED_VERSION}" \
  "primary Helm chart version tracks the active release"
assert_contains "$(cat "$PRIMARY_CHART")" "appVersion: \"${EXPECTED_VERSION}\"" \
  "primary Helm appVersion tracks the active Ferrite image"
assert_contains "$(cat "$SIDECAR_CHART")" "appVersion: \"${EXPECTED_VERSION}\"" \
  "sidecar appVersion tracks the active Ferrite image"

QUICKSTART="${REPO_ROOT}/docker-compose.quickstart.yml"
DEFAULT_COMPOSE="${REPO_ROOT}/docker-compose.yml"
MOONSHOT_COMPOSE="${REPO_ROOT}/docker-compose.moonshot.yml"
assert_contains "$(cat "$QUICKSTART")" \
  "image: ghcr.io/ferritelabs/ferrite:${EXPECTED_VERSION}" \
  "quickstart pins the active Ferrite image"
assert_contains "$(cat "$DEFAULT_COMPOSE")" \
  "image: ferrite:\${FERRITE_VERSION:-${EXPECTED_VERSION}}" \
  "default Compose uses the active release instead of a floating latest tag"
assert_eq "2" \
  "$(grep -F -c "FERRITE_VERSION:-${EXPECTED_VERSION}" "$MOONSHOT_COMPOSE")" \
  "Moonshot Compose pins both build defaults to the active release"
assert_eq "2" \
  "$(grep -F -c "FERRITE_SOURCE_SHA256:-${EXPECTED_SHA256}" "$MOONSHOT_COMPOSE")" \
  "Moonshot Compose pins both build checksums to active-release.env"

ARGOCD="${REPO_ROOT}/gitops/argocd/overlays/production.yaml"
FLUX="${REPO_ROOT}/gitops/flux/overlays/production.yaml"
assert_contains "$(cat "$ARGOCD")" "targetRevision: v${EXPECTED_VERSION}" \
  "Argo CD production tracks the active release tag"
assert_contains "$(cat "$ARGOCD")" "value: \"${EXPECTED_VERSION}\"" \
  "Argo CD production pins the active image version"
assert_contains "$(cat "$FLUX")" "tag: v${EXPECTED_VERSION}" \
  "Flux production tracks the active release tag"
assert_contains "$(cat "$FLUX")" "tag: \"${EXPECTED_VERSION}\"" \
  "Flux production pins the active image version"

KUSTOMIZE_STATEFULSET="${REPO_ROOT}/gitops/kustomize/base/statefulset.yaml"
assert_contains "$(cat "$KUSTOMIZE_STATEFULSET")" \
  "image: ghcr.io/ferritelabs/ferrite:${EXPECTED_VERSION}" \
  "Kustomize base StatefulSet pins the active Ferrite image from GHCR instead of a floating latest tag or optional Docker Hub"

for terraform_file in \
  terraform/common/variables.tf \
  terraform/aws-ecs/main.tf \
  terraform/aws-eks/main.tf; do
  assert_contains \
    "$(grep -A5 '^variable "ferrite_version"' "${REPO_ROOT}/${terraform_file}")" \
    "default     = \"${EXPECTED_VERSION}\"" \
    "${terraform_file} defaults to the active Ferrite version"
done
assert_eq "2" \
  "$(grep -c "ferrite_version[[:space:]]*= \"${EXPECTED_VERSION}\"" "${REPO_ROOT}/terraform/README.md")" \
  "Terraform examples use the active Ferrite version"

RELEASE_WORKFLOW="${REPO_ROOT}/.github/workflows/release.yml"
assert_contains "$(cat "$RELEASE_WORKFLOW")" "default: 'v${EXPECTED_VERSION}'" \
  "release workflow dispatch defaults to the active release"

harness_summary
