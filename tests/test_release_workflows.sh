#!/usr/bin/env bash
# Validates that release.yml and version-sync.yml derive FERRITE_VERSION /
# FERRITE_SOURCE_SHA256 explicitly (rather than relying on the Dockerfile's
# pinned defaults for actual releases), while ordinary CI/scan workflows
# that build the image purely for testing/scanning purposes are left
# untouched and keep using those pinned defaults.
#
# Two layers of coverage:
#   1. Static/textual checks against the workflow YAML (no network needed).
#   2. A functional replay of release.yml's version/checksum derivation
#      logic against representative trigger payloads (push tag,
#      repository_dispatch, workflow_dispatch, and invalid semver), using
#      the real public GitHub tarball
#      URL to compute the checksum — skipped cleanly if python3 or network
#      access is unavailable.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

RELEASE_YML="${REPO_ROOT}/.github/workflows/release.yml"
RECONCILE_YML="${REPO_ROOT}/.github/workflows/reconcile-release-tags.yml"
VERSION_SYNC_YML="${REPO_ROOT}/.github/workflows/version-sync.yml"
ORCHESTRATION_YML="${REPO_ROOT}/.github/workflows/release-orchestration.yml"
ACTIVE_RELEASE="${REPO_ROOT}/active-release.env"

for f in "$RELEASE_YML" "$RECONCILE_YML" "$VERSION_SYNC_YML" "$ORCHESTRATION_YML" "$ACTIVE_RELEASE"; do
  if [[ ! -f "$f" ]]; then
    echo "  FAIL: ${f} not found" >&2
    exit 1
  fi
done

EXPECTED_VERSION="$(sed -n 's/^FERRITE_VERSION=//p' "$ACTIVE_RELEASE")"
EXPECTED_SHA256="$(sed -n 's/^FERRITE_SOURCE_SHA256=//p' "$ACTIVE_RELEASE")"
EXPECTED_MAJOR="${EXPECTED_VERSION%%.*}"
EXPECTED_MAJOR_MINOR="${EXPECTED_VERSION%.*}"
# release.yml no longer bakes the exact version tag directly into the
# metadata-action tag list; it only ever publishes a unique, throwaway
# candidate tag (candidate-<run id>-<run attempt>) and later promotes it to
# the exact tag separately (see tests/test_exact_image_immutability.sh).
# run_case() below fixes RUN_ID/RUN_ATTEMPT so this is deterministic.
EXPECTED_RUN_ID="424242"
EXPECTED_RUN_ATTEMPT="1"
EXPECTED_CANDIDATE_TAG="candidate-${EXPECTED_RUN_ID}-${EXPECTED_RUN_ATTEMPT}"
RELEASE_CONTENT="$(cat "$RELEASE_YML")"
RECONCILE_CONTENT="$(cat "$RECONCILE_YML")"
VERSION_SYNC_CONTENT="$(cat "$VERSION_SYNC_YML")"
ORCHESTRATION_CONTENT="$(cat "$ORCHESTRATION_YML")"
CHECKSUM_SCRIPT_CONTENT="$(cat "${REPO_ROOT}/scripts/compute-source-checksum.sh")"
LABELS_SCRIPT_CONTENT="$(cat "${REPO_ROOT}/scripts/verify-exact-image-labels.sh")"

# --- Static checks: release.yml ---------------------------------------------
assert_contains "$RELEASE_CONTENT" "FERRITE_SOURCE_SHA256" \
  "release.yml derives a FERRITE_SOURCE_SHA256 for the image it publishes"
assert_contains "$RELEASE_CONTENT" "build-args: \${{ needs.prepare.outputs.build_args }}" \
  "release.yml passes the derived FERRITE_VERSION/FERRITE_SOURCE_SHA256 to docker/build-push-action"
assert_contains "$RELEASE_CONTENT" 'grep -qE' \
  "release.yml validates the derived version against a semver pattern"
assert_contains "$RELEASE_CONTENT" "CHECKSUM_SCRIPT: scripts/compute-source-checksum.sh" \
  "release.yml wires in the shared canonical-checksum helper"
assert_contains "$RELEASE_CONTENT" 'bash "$CHECKSUM_SCRIPT"' \
  "release.yml delegates checksum computation to the shared helper"
assert_contains "$CHECKSUM_SCRIPT_CONTENT" "'^[0-9a-f]{64}$'" \
  "the shared checksum helper validates checksums as exactly 64 hexadecimal characters"
assert_contains "$CHECKSUM_SCRIPT_CONTENT" "shasum -a 256" \
  "the shared checksum helper computes the source archive checksum"
assert_contains "$RELEASE_CONTENT" "GITHUB_REF_NAME" \
  "release.yml derives the version from the push-tag ref for tag pushes"
assert_contains "$RELEASE_CONTENT" "github.event.client_payload.version" \
  "release.yml derives the version from repository_dispatch client_payload.version"
assert_contains "$RELEASE_CONTENT" "inputs.tag" \
  "release.yml derives the version from the workflow_dispatch input"
assert_contains "$RELEASE_CONTENT" "default: 'v${EXPECTED_VERSION}'" \
  "release.yml's workflow_dispatch default matches active-release.env"
assert_contains "$RELEASE_CONTENT" 'type=raw,value=${{ needs.prepare.outputs.candidate_tag }}' \
  "release.yml tags the build with a unique, throwaway candidate tag, never the exact version directly"
assert_not_contains "$RELEASE_CONTENT" 'type=raw,value=${{ needs.prepare.outputs.version }}' \
  "release.yml never bakes the exact version tag directly into the candidate build's metadata"
assert_not_contains "$RELEASE_CONTENT" 'type=raw,value=latest' \
  "release.yml never bakes a floating latest tag into the candidate build"
assert_not_contains "$RELEASE_CONTENT" 'type=raw,value=${{ needs.prepare.outputs.major_minor }}' \
  "release.yml no longer builds the floating major.minor tag inline; promotion advances it"
assert_not_contains "$RELEASE_CONTENT" 'type=raw,value=${{ needs.prepare.outputs.major }}' \
  "release.yml no longer builds the floating major tag inline; promotion advances it"

# --- Candidate OCI metadata: real normalized SemVer, not the run-specific
# candidate tag string (see tests/test_exact_image_immutability.sh and
# tests/test_release_reconciliation.sh for the complete-state consequences of
# this exact label). ---
assert_contains "$RELEASE_CONTENT" 'labels: |
            org.opencontainers.image.version=${{ needs.prepare.outputs.version }}' \
  "release.yml's GHCR candidate metadata step explicitly overrides org.opencontainers.image.version to the real normalized SemVer"
assert_eq "2" "$(grep -c 'org.opencontainers.image.version=\${{ needs.prepare.outputs.version }}' "$RELEASE_YML")" \
  "both the GHCR and Docker Hub candidate metadata steps explicitly set the real-SemVer version label"

# --- Event/ref trust and signature identity are derived together in prepare,
# before any registry login/write job can start. ---
assert_contains "$RELEASE_CONTENT" 'WORKFLOW_REF: ${{ github.ref }}' \
  "release.yml passes the workflow ref into the trusted prepare step"
assert_contains "$RELEASE_CONTENT" 'DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}' \
  "release.yml reads the configured default branch for dispatch trust"
assert_contains "$RELEASE_CONTENT" 'EXPECTED_REF="refs/tags/v${VERSION}"' \
  "push releases require the exact v-prefixed normalized candidate tag ref"
assert_contains "$RELEASE_CONTENT" 'Dispatch releases must run on refs/heads/main or the configured default branch' \
  "dispatch releases reject historical tags and non-default branches before registry access"
assert_contains "$RELEASE_CONTENT" 'certificate_identity_regexp: ${{ steps.release_meta.outputs.certificate_identity_regexp }}' \
  "prepare exports a Cosign identity allowance derived from the trusted event/ref pairings"
assert_not_contains "$RELEASE_CONTENT" 'CERTIFICATE_IDENTITY_REGEXP: ^https://github\.com/${{ github.repository_owner }}/$' \
  "release.yml no longer uses an org-wide cosign identity regexp"
assert_eq "3" "$(grep -c 'certificate-identity-regexp="\$CERTIFICATE_IDENTITY_REGEXP"' "$RELEASE_YML")" \
  "all three cosign verify/verify-attestation invocations consume the single shared identity regexp"

assert_not_contains "$RELEASE_CONTENT" "promote-stable:" \
  "release.yml no longer performs event-specific floating-tag promotion"
assert_contains "$RECONCILE_CONTENT" "workflows: [Release]" \
  "successful exact release completion triggers complete-state reconciliation"
assert_contains "$RECONCILE_CONTENT" "types: [reconcile-release-tags]" \
  "manual reconciliation uses only the narrow repository-dispatch event type"
assert_not_contains "$RECONCILE_CONTENT" "workflow_dispatch:" \
  "manual reconciliation cannot execute a branch-selected workflow definition"
assert_contains "$RECONCILE_CONTENT" 'ref: ${{ github.event.repository.default_branch }}' \
  "registry reconciliation executes reviewed default-branch code"
assert_contains "$RECONCILE_CONTENT" "EXPECTED_WORKFLOW_REF" \
  "registry reconciliation validates the default-branch workflow ref before login"
assert_contains "$RECONCILE_CONTENT" "group: ferrite-release-tag-reconciliation" \
  "floating-tag reconciliation is globally serialized"
assert_contains "$RECONCILE_CONTENT" "cancel-in-progress: false" \
  "the active complete-state reconciliation is never cancelled"
assert_contains "$RECONCILE_CONTENT" "gh api --paginate --slurp" \
  "reconciliation enumerates every GHCR package-version page"
assert_contains "$RECONCILE_CONTENT" "scripts/reconcile-release-tags.py" \
  "reconciliation uses the pure desired-state helper"
assert_contains "$RECONCILE_CONTENT" "scripts/release-ordering.sh" \
  "the desired-state helper consumes the shared strict SemVer comparator"
assert_contains "$RECONCILE_CONTENT" "cosign verify" \
  "reconciliation verifies exact source signatures before planning"
assert_contains "$RECONCILE_CONTENT" "docker buildx imagetools create" \
  "GHCR floating tags are moved to selected signed digests without rebuilding"
assert_contains "$RECONCILE_CONTENT" "crane copy" \
  "eligible Docker Hub exact and floating tags are copied cross-registry from GHCR"
assert_contains "$RECONCILE_CONTENT" 'kind: "exact"' \
  "Docker Hub reconciliation includes every verified exact stable tag"
assert_not_contains "$RELEASE_CONTENT" 'type=raw,value=${{ inputs.tag }}' \
  "workflow_dispatch does not publish an unnormalized raw v-prefixed tag"
assert_contains "$RELEASE_CONTENT" "latest=false" \
  "release.yml disables docker/metadata-action's implicit latest tag"
assert_contains "$RELEASE_CONTENT" "group: ferrite-release-" \
  "release.yml serializes runs for the same version with a per-version concurrency group"
assert_contains "$RELEASE_CONTENT" "id: check_existing" \
  "release.yml checks for an existing exact GHCR tag before building anything"
assert_contains "$RELEASE_CONTENT" "candidate-\${RUN_ID}-\${RUN_ATTEMPT}" \
  "release.yml derives a unique candidate tag from the run id and attempt"
assert_contains "$RELEASE_CONTENT" "LABELS_SCRIPT: scripts/verify-exact-image-labels.sh" \
  "release.yml wires in the shared exact-tag label verification helper"
assert_contains "$RELEASE_CONTENT" 'bash "$LABELS_SCRIPT" exact "$VERSION" "$SHA256"' \
  "release.yml verifies an existing exact tag's labels via the shared helper in 'exact' mode"
assert_contains "$LABELS_SCRIPT_CONTENT" "dev.ferritelabs.image.source-sha256" \
  "the shared label-verification helper checks the baked source-checksum label of an existing exact tag"
assert_contains "$RELEASE_CONTENT" "release-transaction:" \
  "release.yml defines one exact release transaction job"
assert_not_contains "$RELEASE_CONTENT" "promote-exact:" \
  "release.yml has no separate exact-promotion job that could create a lock gap"
assert_not_contains "$RELEASE_CONTENT" "build-and-push:" \
  "release.yml has no separate build job that releases the version lock before promotion"
assert_contains "$RELEASE_CONTENT" "Refusing to overwrite an existing exact version tag" \
  "release.yml refuses to overwrite an existing exact tag that points at a different digest"

# --- Docker Hub is optional; GHCR is always published -----------------------
assert_contains "$RELEASE_CONTENT" "id: dockerhub" \
  "release.yml computes Docker Hub publishing eligibility before login and metadata generation"
assert_contains "$RELEASE_CONTENT" 'DOCKERHUB_ENABLED: ${{ vars.DOCKERHUB_ENABLED }}' \
  "release.yml includes the explicit DOCKERHUB_ENABLED repository variable in Docker Hub eligibility"
assert_contains "$RELEASE_CONTENT" 'DOCKERHUB_USERNAME: ${{ secrets.DOCKERHUB_USERNAME }}' \
  "release.yml includes Docker Hub username presence in publishing eligibility"
assert_contains "$RELEASE_CONTENT" 'DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}' \
  "release.yml includes Docker Hub token presence in publishing eligibility"
assert_contains "$RELEASE_CONTENT" "id: meta_dockerhub" \
  "release.yml extracts Docker Hub metadata as its own gated step"
assert_contains "$RELEASE_CONTENT" "if: steps.dockerhub.outputs.enabled == 'true'" \
  "release.yml gates Docker Hub login on enabled plus configured credentials"
assert_contains "$RELEASE_CONTENT" "if: steps.check_existing.outputs.idempotent != 'true' && steps.dockerhub.outputs.enabled == 'true'" \
  "release.yml gates Docker Hub metadata on BOTH the idempotent check and publishing eligibility"
assert_not_contains "$RELEASE_CONTENT" "if: vars.DOCKERHUB_ENABLED == 'true'" \
  "release.yml does not generate Docker Hub metadata based on the variable alone"
assert_not_contains "$RELEASE_CONTENT" '            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
            ${{ env.DOCKERHUB_IMAGE }}' \
  "release.yml no longer bundles GHCR and Docker Hub into a single unconditional metadata-action images list"
assert_contains "$RELEASE_CONTENT" "images: \${{ env.REGISTRY }}/\${{ env.IMAGE_NAME }}" \
  "release.yml's GHCR metadata step targets only the GHCR image"
assert_contains "$RELEASE_CONTENT" "images: \${{ env.DOCKERHUB_IMAGE }}" \
  "release.yml's Docker Hub metadata step targets only the Docker Hub image"
assert_contains "$RELEASE_CONTENT" "tags: \${{ steps.meta_combined.outputs.tags }}" \
  "release.yml pushes the combined GHCR + optional Docker Hub tag set"
assert_not_contains "$RELEASE_CONTENT" "tags: \${{ steps.meta.outputs.tags }}" \
  "release.yml's build-push step no longer uses the raw GHCR-only meta step output directly"
assert_not_contains "$RELEASE_CONTENT" "bump-chart" \
  "release.yml no longer runs its own competing chart-only bump job"
assert_not_contains "$RELEASE_CONTENT" "charts/ferrite" \
  "release.yml does not touch chart files; version-sync.yml is the single workflow that does"
assert_not_contains "$ORCHESTRATION_CONTENT" "charts/ferrite" \
  "release-orchestration.yml leaves every ferrite-ops version pin to version-sync.yml"
assert_not_contains "$ORCHESTRATION_CONTENT" "update-ops:" \
  "release-orchestration.yml no longer opens a competing ferrite-ops version PR"

# --- Static checks: version-sync.yml ----------------------------------------
for dockerfile in Dockerfile Dockerfile.moonshot Dockerfile.playground; do
  assert_contains "$VERSION_SYNC_CONTENT" "$dockerfile" \
    "version-sync.yml includes ${dockerfile} in the atomic Dockerfile update"
done
assert_contains "$VERSION_SYNC_CONTENT" "DOCKERFILES=(" \
  "version-sync.yml updates all Dockerfile defaults as one validated group"
assert_contains "$VERSION_SYNC_CONTENT" "active-release.env" \
  "version-sync.yml updates canonical active release metadata"
assert_contains "$VERSION_SYNC_CONTENT" "Synchronize active release metadata and pins" \
  "version-sync.yml stages every active release pin as one update group"
assert_contains "$VERSION_SYNC_CONTENT" "ARG FERRITE_SOURCE_SHA256=" \
  "version-sync.yml updates each Dockerfile's FERRITE_SOURCE_SHA256 default"
assert_contains "$VERSION_SYNC_CONTENT" "ARG FERRITE_VERSION=" \
  "version-sync.yml updates each Dockerfile's FERRITE_VERSION default"
assert_contains "$VERSION_SYNC_CONTENT" 'grep -qE' \
  "version-sync.yml validates the version against a semver pattern"
assert_contains "$VERSION_SYNC_CONTENT" "CHECKSUM_SCRIPT: scripts/compute-source-checksum.sh" \
  "version-sync.yml wires in the shared canonical-checksum helper"
assert_contains "$VERSION_SYNC_CONTENT" 'bash "$CHECKSUM_SCRIPT" "$REPOSITORY_OWNER" "$VERSION" "$INPUT_SHA256"' \
  "version-sync.yml always computes the canonical checksum via the shared helper, passing any supplied value only for comparison"
assert_contains "$VERSION_SYNC_CONTENT" "charts/ferrite-sidecar/Chart.yaml" \
  "version-sync.yml keeps the sidecar appVersion synchronized"
assert_contains "$VERSION_SYNC_CONTENT" "ferrite-ops-v\${VERSION}" \
  "version-sync.yml advances production GitOps sources to the immutable ops tag"
assert_contains "$VERSION_SYNC_CONTENT" "repository: ghcr.io/ferritelabs/ferrite" \
  "version-sync.yml validates the Flux production GHCR repository"
assert_contains "$VERSION_SYNC_CONTENT" "Skipping RPM spec update for prerelease" \
  "version-sync.yml explicitly skips RPM spec edits for prereleases"
assert_contains "$VERSION_SYNC_CONTENT" "Release:        1%{?dist}" \
  "version-sync.yml resets RPM Release for stable releases"
assert_contains "$VERSION_SYNC_CONTENT" "types: [ferrite-release, version-sync]" \
  "version-sync.yml triggers on the real ferrite-release dispatch core emits, keeping version-sync for backward compatibility"
for active_target in \
  docker-compose.quickstart.yml \
  docker-compose.yml \
  docker-compose.moonshot.yml \
  gitops/argocd/overlays/production.yaml \
  gitops/flux/overlays/production.yaml \
  gitops/kustomize/base/statefulset.yaml \
  terraform/common/variables.tf \
  terraform/aws-ecs/main.tf \
  terraform/aws-eks/main.tf \
  terraform/README.md \
  .github/workflows/release.yml; do
  assert_contains "$VERSION_SYNC_CONTENT" "$active_target" \
    "version-sync.yml includes ${active_target} in the release transaction"
done
assert_contains "$ORCHESTRATION_CONTENT" "CHECKSUM_SCRIPT: scripts/compute-source-checksum.sh" \
  "release-orchestration.yml wires in the shared canonical-checksum helper"
assert_contains "$ORCHESTRATION_CONTENT" 'bash "$CHECKSUM_SCRIPT" "$REPOSITORY_OWNER" "$VERSION" "$INPUT_SHA256"' \
  "release-orchestration.yml always computes the canonical checksum via the shared helper, passing any supplied value only for comparison"
assert_eq "5" "$(grep -c 'bash "\$ORDER_SCRIPT" validate' "$ORCHESTRATION_YML")" \
  "release-orchestration.yml's prepare job and all four downstream jobs call the shared strict-SemVer validator"
assert_not_contains "$ORCHESTRATION_CONTENT" \
  'grep -qE '"'"'^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'"'"'' \
  "release-orchestration.yml no longer duplicates the inline SemVer regex anywhere"

# No GitHub expression is allowed inside a run script in these privileged
# release workflows. Untrusted values enter scripts only through step env.
if command -v python3 >/dev/null 2>&1 &&
  python3 -c "import yaml" >/dev/null 2>&1 &&
  python3 - "$RELEASE_YML" "$RECONCILE_YML" "$VERSION_SYNC_YML" "$ORCHESTRATION_YML" <<'PYEOF'
import sys
import yaml

for path in sys.argv[1:]:
    with open(path) as workflow_file:
        workflow = yaml.safe_load(workflow_file)
    for job_name, job in workflow.get("jobs", {}).items():
        for index, step in enumerate(job.get("steps", [])):
            script = step.get("run")
            if script and "${{" in script:
                name = step.get("name", f"step {index}")
                raise SystemExit(
                    f"{path}: {job_name}/{name} interpolates a GitHub expression in run"
                )
PYEOF
then
  harness_ok "release workflow run scripts contain no direct GitHub expression interpolation"
else
  harness_fail "release workflow run scripts must receive GitHub expressions through step env"
fi

# version-sync.yml must be the workflow that reacts to the real
# `ferrite-release` dispatch core emits (kept alongside `version-sync` only
# for backward compatibility), and no other release workflow may run a
# competing job that partially updates chart files.
if command -v python3 >/dev/null 2>&1 &&
  python3 -c "import yaml" >/dev/null 2>&1 &&
  python3 - "$VERSION_SYNC_YML" "$RELEASE_YML" "$ORCHESTRATION_YML" <<'TRIGGERCHECK'
import sys
import yaml

version_sync_path, release_path, orchestration_path = sys.argv[1:]

with open(version_sync_path) as f:
    version_sync_doc = yaml.safe_load(f)
sync_types = version_sync_doc.get(True, {}).get("repository_dispatch", {}).get("types", [])
if "ferrite-release" not in sync_types:
    raise SystemExit(
        "version-sync.yml must trigger on the real ferrite-release dispatch event core emits"
    )
if "version-sync" not in sync_types:
    raise SystemExit(
        "version-sync.yml should keep version-sync as a backward-compatible trigger"
    )

with open(release_path) as f:
    release_doc = yaml.safe_load(f)
if "bump-chart" in release_doc.get("jobs", {}):
    raise SystemExit(
        "release.yml must not define its own competing chart-only bump job"
    )

with open(orchestration_path) as f:
    orchestration_doc = yaml.safe_load(f)
if "update-ops" in orchestration_doc.get("jobs", {}):
    raise SystemExit(
        "release-orchestration.yml must not define a competing ferrite-ops update job"
    )
orchestration_text = open(orchestration_path).read()
if "charts/ferrite" in orchestration_text:
    raise SystemExit(
        "release-orchestration.yml must leave chart updates to version-sync.yml"
    )
TRIGGERCHECK
then
  harness_ok "version-sync.yml is the sole ferrite-release chart/Dockerfile/pin sync workflow"
else
  harness_fail "release workflows disagree on which workflow owns the ferrite-release sync"
fi

# --- Static checks: ordinary CI/scan workflows retain pinned defaults -------
for wf in ci.yml docker-scan.yml sbom.yml; do
  wf_path="${REPO_ROOT}/.github/workflows/${wf}"
  if [[ -f "$wf_path" ]]; then
    assert_not_contains "$(cat "$wf_path")" "FERRITE_SOURCE_SHA256" \
      "${wf} does not override FERRITE_SOURCE_SHA256 (keeps the Dockerfile's pinned default)"
    assert_not_contains "$(cat "$wf_path")" "build-arg FERRITE_VERSION" \
      "${wf} does not override FERRITE_VERSION (keeps the Dockerfile's pinned default)"
  fi
done

# --- Functional replay of release.yml's version/checksum derivation --------
if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip: python3 not available; skipping functional replay of release.yml logic."
  harness_summary
  exit $?
fi

if ! curl -fsSL --max-time 5 -o /dev/null "https://github.com" 2>/dev/null; then
  echo "  skip: no network access to github.com; skipping functional replay of release.yml logic."
  harness_summary
  exit $?
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  skip: python3's PyYAML module is not available; skipping functional replay of release.yml logic."
  harness_summary
  exit $?
fi

EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXTRACT_DIR"' EXIT

EXTRACT_LOG="${EXTRACT_DIR}/extract.log"
if ! python3 - "$RELEASE_YML" "$VERSION_SYNC_YML" "$ORCHESTRATION_YML" \
  "$EXTRACT_DIR/release_meta.sh" "$EXTRACT_DIR/version_sync_meta.sh" \
  "$EXTRACT_DIR/orchestration_meta.sh" "$EXTRACT_DIR/update_dockerfiles.sh" \
  "$EXTRACT_DIR/version_sync_chart.sh" "$EXTRACT_DIR/metadata_tags.txt" \
  "$EXTRACT_DIR/combine_tags.sh" "$EXTRACT_DIR/dockerhub_eligibility.sh" \
  "$EXTRACT_DIR/update_rpm.sh" \
  >"${EXTRACT_DIR}/extract.stdout" 2>"${EXTRACT_DIR}/extract.log" << 'PYEOF'
import sys
import yaml

(
    release_yml_path,
    version_sync_yml_path,
    orchestration_yml_path,
    release_out_path,
    version_sync_meta_out_path,
    orchestration_meta_out_path,
    sync_out_path,
    version_sync_chart_out_path,
    metadata_tags_out_path,
    combine_tags_out_path,
    dockerhub_eligibility_out_path,
    update_rpm_out_path,
) = sys.argv[1:]
with open(release_yml_path) as f:
    doc = yaml.safe_load(f)

# "Determine release version and source checksum" now runs in the
# dedicated, trusted `prepare` job — BEFORE any build/scan/registry job —
# so the complete release-transaction can key one job-level concurrency lock
# on prepare's normalized `version` output.
prepare_steps = doc["jobs"]["prepare"]["steps"]
script = next(s["run"] for s in prepare_steps if s.get("name") == "Determine release version and source checksum")
transaction = doc["jobs"]["release-transaction"]
if transaction.get("needs") != "prepare":
    raise SystemExit("release-transaction must depend on the prepare job")
transaction_concurrency = transaction.get("concurrency", {})
if "needs.prepare.outputs.version" not in transaction_concurrency.get("group", ""):
    raise SystemExit("release-transaction must key its one job-level concurrency lock on prepare's normalized version")
if transaction_concurrency.get("cancel-in-progress") is not False:
    raise SystemExit("release-transaction must queue (not cancel) an in-flight run for the same version")

steps = transaction["steps"]
metadata_index = next(i for i, s in enumerate(steps) if s.get("id") == "meta")
if metadata_index < 0:
    raise SystemExit("docker/metadata-action step not found")

for forbidden_job in ("build-and-push", "verify", "smoke-test", "promote-exact"):
    if forbidden_job in doc["jobs"]:
        raise SystemExit(f"{forbidden_job} must be consolidated into release-transaction")

required_order = [
    "Build and push candidate (amd64 + arm64)",
    "Scan candidate image with Trivy",
    "Sign container image with Cosign (keyless OIDC)",
    "Attest SBOM with Cosign (keyless OIDC)",
    "Verify container signature",
    "Verify SBOM attestation",
    "Smoke test verified image",
    "Promote the verified digest to the exact immutable version tag",
]
indices = [
    next(i for i, step in enumerate(steps) if step.get("name") == name)
    for name in required_order
]
if indices != sorted(indices):
    raise SystemExit("release-transaction steps are not ordered build -> sign/attest -> verify -> smoke -> exact promotion")

metadata_tags = next(s["with"]["tags"] for s in steps if s.get("id") == "meta")
required_tags = [
    "type=raw,value=${{ needs.prepare.outputs.candidate_tag }}",
]
missing_tags = [tag for tag in required_tags if tag not in metadata_tags]
if missing_tags:
    raise SystemExit(f"metadata tags are missing normalized outputs: {missing_tags}")
if "type=raw,value=${{ needs.prepare.outputs.version }}" in metadata_tags:
    raise SystemExit("metadata tags must never bake the exact version tag directly")

metadata_flavor = next(
    (s["with"].get("flavor", "") for s in steps if s.get("id") == "meta"), ""
)
if "latest=false" not in metadata_flavor:
    raise SystemExit("docker/metadata-action must disable its implicit latest tag")

with open(metadata_tags_out_path, "w") as f:
    f.write(metadata_tags)

# Docker Hub metadata extraction and login must use one eligibility result
# that requires both DOCKERHUB_ENABLED=true and configured credentials.
dockerhub_eligibility_step = next(s for s in steps if s.get("id") == "dockerhub")
with open(dockerhub_eligibility_out_path, "w") as f:
    f.write(dockerhub_eligibility_step["run"])

dockerhub_step = next(s for s in steps if s.get("id") == "meta_dockerhub")
dockerhub_login_step = next(s for s in steps if s.get("name") == "Log in to Docker Hub")
dockerhub_condition = "steps.dockerhub.outputs.enabled == 'true'"
dockerhub_metadata_condition = "steps.check_existing.outputs.idempotent != 'true' && steps.dockerhub.outputs.enabled == 'true'"
if dockerhub_step.get("if") != dockerhub_metadata_condition:
    raise SystemExit("meta_dockerhub step must be gated on BOTH the idempotent check and Docker Hub publishing eligibility")
if dockerhub_login_step.get("if") != dockerhub_condition:
    raise SystemExit("Docker Hub login must use the publishing eligibility gate")
if dockerhub_step["with"]["images"] != "${{ env.DOCKERHUB_IMAGE }}":
    raise SystemExit("meta_dockerhub step must target only the Docker Hub image")
dockerhub_tags = dockerhub_step["with"]["tags"]
missing_dockerhub_tags = [tag for tag in required_tags if tag not in dockerhub_tags]
if missing_dockerhub_tags:
    raise SystemExit(f"Docker Hub metadata tags are missing normalized outputs: {missing_dockerhub_tags}")

ghcr_step = next(s for s in steps if s.get("id") == "meta")
if ghcr_step["with"]["images"] != "${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}":
    raise SystemExit("meta step must target only the GHCR image")

combine_step = next(s for s in steps if s.get("id") == "meta_combined")
with open(combine_tags_out_path, "w") as f:
    f.write(combine_step["run"])

build_step = next(s for s in steps if s.get("id") == "build")
if build_step["with"]["tags"] != "${{ steps.meta_combined.outputs.tags }}":
    raise SystemExit("release-transaction build step must use the combined tag list, not the raw GHCR-only meta output")

with open(release_out_path, "w") as f:
    f.write(script)

# release.yml intentionally no longer defines a chart-bumping job of its
# own; version-sync.yml (extracted below) is the sole place that updates
# chart files, as part of the same comprehensive active-release transaction.
if "bump-chart" in doc["jobs"]:
    raise SystemExit(
        "release.yml must not reintroduce its own competing chart-only bump job"
    )

with open(version_sync_yml_path) as f:
    sync_doc = yaml.safe_load(f)

sync_steps = sync_doc["jobs"]["sync"]["steps"]
version_sync_meta_script = next(
    s["run"] for s in sync_steps if s.get("name") == "Extract version and source checksum"
)
with open(version_sync_meta_out_path, "w") as f:
    f.write(version_sync_meta_script)

sync_script = next(
    s["run"]
    for s in sync_steps
    if s.get("name") == "Synchronize active release metadata and pins"
)
with open(sync_out_path, "w") as f:
    f.write(sync_script)

# The active-pin synchronizer now owns chart updates as part of the same
# transaction; retain this extracted path for the common extraction fixture.
version_sync_chart_script = sync_script
with open(version_sync_chart_out_path, "w") as f:
    f.write(version_sync_chart_script)

rpm_script = next(
    s["run"] for s in sync_steps if s.get("name") == "Update RPM spec"
)
with open(update_rpm_out_path, "w") as f:
    f.write(rpm_script)

with open(orchestration_yml_path) as f:
    orchestration_doc = yaml.safe_load(f)
orchestration_meta_script = next(
    s["run"]
    for s in orchestration_doc["jobs"]["prepare"]["steps"]
    if s.get("name") == "Compute release metadata"
)
with open(orchestration_meta_out_path, "w") as f:
    f.write(orchestration_meta_script)
PYEOF
then
  harness_fail "release workflow extraction failed: $(cat "$EXTRACT_LOG")"
  harness_summary
  exit $?
fi

# Exercise the full active-release transaction against isolated copies. Every
# pin must change together, and structural drift must fail before any edit.
SYNC_VERSION="9.8.7"
SYNC_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SYNC_SCRIPT="$(cat "${EXTRACT_DIR}/update_dockerfiles.sh")"
SYNC_TARGETS=(
  active-release.env
  Dockerfile
  Dockerfile.moonshot
  Dockerfile.playground
  charts/ferrite/Chart.yaml
  charts/ferrite-sidecar/Chart.yaml
  docker-compose.quickstart.yml
  docker-compose.yml
  docker-compose.moonshot.yml
  gitops/argocd/overlays/production.yaml
  gitops/flux/overlays/production.yaml
  gitops/kustomize/base/statefulset.yaml
  terraform/common/variables.tf
  terraform/aws-ecs/main.tf
  terraform/aws-eks/main.tf
  terraform/README.md
  .github/workflows/release.yml
)

copy_sync_targets() {
  local destination="$1" target
  for target in "${SYNC_TARGETS[@]}"; do
    mkdir -p "${destination}/$(dirname "$target")"
    cp "${REPO_ROOT}/${target}" "${destination}/${target}"
  done
}

SYNC_DIR="${EXTRACT_DIR}/sync-success"
mkdir -p "$SYNC_DIR"
copy_sync_targets "$SYNC_DIR"
if (cd "$SYNC_DIR" && VERSION="$SYNC_VERSION" SHA256="$SYNC_SHA256" bash -c "$SYNC_SCRIPT"); then
  for dockerfile in Dockerfile Dockerfile.moonshot Dockerfile.playground; do
    assert_contains "$(cat "${SYNC_DIR}/${dockerfile}")" "ARG FERRITE_VERSION=${SYNC_VERSION}" \
      "version-sync functional replay updates ${dockerfile}'s version"
    assert_contains "$(cat "${SYNC_DIR}/${dockerfile}")" "ARG FERRITE_SOURCE_SHA256=${SYNC_SHA256}" \
      "version-sync functional replay updates ${dockerfile}'s checksum"
  done
  assert_contains "$(cat "${SYNC_DIR}/active-release.env")" "FERRITE_VERSION=${SYNC_VERSION}" \
    "version-sync functional replay updates canonical release version"
  assert_contains "$(cat "${SYNC_DIR}/active-release.env")" "FERRITE_SOURCE_SHA256=${SYNC_SHA256}" \
    "version-sync functional replay updates canonical release checksum"
  assert_contains "$(cat "${SYNC_DIR}/charts/ferrite/Chart.yaml")" "appVersion: \"${SYNC_VERSION}\"" \
    "version-sync functional replay updates the primary chart appVersion"
  assert_contains "$(cat "${SYNC_DIR}/charts/ferrite-sidecar/Chart.yaml")" "appVersion: \"${SYNC_VERSION}\"" \
    "version-sync functional replay updates the sidecar chart appVersion"
  assert_contains "$(cat "${SYNC_DIR}/docker-compose.quickstart.yml")" \
    "ferrite:${SYNC_VERSION}" "version-sync functional replay updates quickstart"
  assert_contains "$(cat "${SYNC_DIR}/docker-compose.yml")" \
    "FERRITE_VERSION:-${SYNC_VERSION}" "version-sync functional replay updates default Compose"
  assert_eq "2" "$(grep -c "FERRITE_VERSION:-${SYNC_VERSION}" "${SYNC_DIR}/docker-compose.moonshot.yml")" \
    "version-sync functional replay updates both Moonshot version defaults"
  assert_eq "2" "$(grep -c "FERRITE_SOURCE_SHA256:-${SYNC_SHA256}" "${SYNC_DIR}/docker-compose.moonshot.yml")" \
    "version-sync functional replay updates both Moonshot checksum defaults"
  assert_contains "$(cat "${SYNC_DIR}/gitops/argocd/overlays/production.yaml")" \
    "targetRevision: ferrite-ops-v${SYNC_VERSION}" \
    "version-sync functional replay updates Argo CD to the immutable ops tag"
  assert_contains "$(cat "${SYNC_DIR}/gitops/flux/overlays/production.yaml")" \
    "tag: ferrite-ops-v${SYNC_VERSION}" \
    "version-sync functional replay updates Flux to the immutable ops tag"
  assert_contains "$(cat "${SYNC_DIR}/gitops/flux/overlays/production.yaml")" \
    "repository: ghcr.io/ferritelabs/ferrite" \
    "version-sync functional replay preserves the Flux production GHCR repository"
  assert_contains "$(cat "${SYNC_DIR}/gitops/kustomize/base/statefulset.yaml")" \
    "image: ghcr.io/ferritelabs/ferrite:${SYNC_VERSION}" \
    "version-sync functional replay updates the Kustomize base StatefulSet image tag while preserving its GHCR repository"
  for terraform_file in terraform/common/variables.tf terraform/aws-ecs/main.tf terraform/aws-eks/main.tf; do
    assert_contains "$(grep -A5 '^variable "ferrite_version"' "${SYNC_DIR}/${terraform_file}")" \
      "default     = \"${SYNC_VERSION}\"" \
      "version-sync functional replay updates ${terraform_file}"
  done
  assert_eq "2" \
    "$(grep -c "ferrite_version[[:space:]]*= \"${SYNC_VERSION}\"" "${SYNC_DIR}/terraform/README.md")" \
    "version-sync functional replay updates Terraform examples"
  assert_contains "$(cat "${SYNC_DIR}/.github/workflows/release.yml")" \
    "default: 'v${SYNC_VERSION}'" \
    "version-sync functional replay updates the release workflow dispatch default"
else
  harness_fail "version-sync functional replay unexpectedly failed"
fi

# Stable releases update both RPM Version and Release. Prereleases leave the
# entire spec byte-for-byte unchanged so a hyphenated SemVer is never written
# into RPM Version.
RPM_SCRIPT="$(cat "${EXTRACT_DIR}/update_rpm.sh")"
RPM_STABLE_DIR="${EXTRACT_DIR}/rpm-stable"
mkdir -p "${RPM_STABLE_DIR}/packaging/rpm"
cp "${REPO_ROOT}/packaging/rpm/ferrite.spec" "${RPM_STABLE_DIR}/packaging/rpm/ferrite.spec"
sed -i.bak 's/^Release:.*/Release:        7%{?dist}/' \
  "${RPM_STABLE_DIR}/packaging/rpm/ferrite.spec"
rm -f "${RPM_STABLE_DIR}/packaging/rpm/ferrite.spec.bak"
if (cd "$RPM_STABLE_DIR" && VERSION="$SYNC_VERSION" bash -c "$RPM_SCRIPT"); then
  assert_contains "$(cat "${RPM_STABLE_DIR}/packaging/rpm/ferrite.spec")" \
    "Version:        ${SYNC_VERSION}" \
    "stable version-sync replay updates RPM Version"
  assert_contains "$(cat "${RPM_STABLE_DIR}/packaging/rpm/ferrite.spec")" \
    'Release:        1%{?dist}' \
    "stable version-sync replay resets RPM Release"
else
  harness_fail "stable RPM version-sync replay unexpectedly failed"
fi

RPM_PRERELEASE_DIR="${EXTRACT_DIR}/rpm-prerelease"
mkdir -p "${RPM_PRERELEASE_DIR}/packaging/rpm"
cp "${REPO_ROOT}/packaging/rpm/ferrite.spec" \
  "${RPM_PRERELEASE_DIR}/packaging/rpm/ferrite.spec"
RPM_BEFORE="$(shasum -a 256 "${RPM_PRERELEASE_DIR}/packaging/rpm/ferrite.spec" | awk '{print $1}')"
if (cd "$RPM_PRERELEASE_DIR" && VERSION="0.5.0-rc.1" bash -c "$RPM_SCRIPT" \
  >"${EXTRACT_DIR}/rpm-prerelease.log" 2>&1); then
  RPM_AFTER="$(shasum -a 256 "${RPM_PRERELEASE_DIR}/packaging/rpm/ferrite.spec" | awk '{print $1}')"
  assert_eq "$RPM_BEFORE" "$RPM_AFTER" \
    "0.5.0-rc.1 version-sync replay leaves the RPM spec unchanged"
  assert_contains "$(cat "${EXTRACT_DIR}/rpm-prerelease.log")" \
    "Skipping RPM spec update for prerelease 0.5.0-rc.1" \
    "prerelease RPM skip is explicit"
  assert_not_contains "$(cat "${RPM_PRERELEASE_DIR}/packaging/rpm/ferrite.spec")" \
    "Version:        0.5.0-rc.1" \
    "prerelease SemVer is never written into RPM Version"
else
  harness_fail "prerelease RPM version-sync replay unexpectedly failed"
fi

DRIFT_DIR="${EXTRACT_DIR}/sync-drift"
mkdir -p "$DRIFT_DIR"
copy_sync_targets "$DRIFT_DIR"
sed '/^ARG FERRITE_SOURCE_SHA256=/d' "${DRIFT_DIR}/Dockerfile.playground" \
  > "${DRIFT_DIR}/Dockerfile.playground.tmp"
mv "${DRIFT_DIR}/Dockerfile.playground.tmp" "${DRIFT_DIR}/Dockerfile.playground"
if (cd "$DRIFT_DIR" && VERSION="$SYNC_VERSION" SHA256="$SYNC_SHA256" bash -c "$SYNC_SCRIPT"); then
  harness_fail "version-sync unexpectedly accepted a structurally drifted auxiliary Dockerfile"
else
  UNCHANGED_COUNT="$(grep -l "^ARG FERRITE_VERSION=${EXPECTED_VERSION}$" \
    "${DRIFT_DIR}/Dockerfile" "${DRIFT_DIR}/Dockerfile.moonshot" \
    "${DRIFT_DIR}/Dockerfile.playground" | wc -l | tr -d ' ')"
  assert_eq "3" "$UNCHANGED_COUNT" \
    "version-sync validates every target before making any release-default edit"
  assert_contains "$(cat "${DRIFT_DIR}/active-release.env")" \
    "FERRITE_VERSION=${EXPECTED_VERSION}" \
    "structural drift leaves canonical metadata unchanged"
fi

# Resolve docker/metadata-action's tag template against the outputs a given
# trigger actually produced, so the *effective* published tag set is asserted
# rather than only the template text.
effective_tags() {
  local output_file="$1"
  local version major major_minor stable candidate_tag line value enable

  version="$(grep -E '^version=' "$output_file" | head -1 | cut -d= -f2-)"
  major="$(grep -E '^major=' "$output_file" | head -1 | cut -d= -f2-)"
  major_minor="$(grep -E '^major_minor=' "$output_file" | head -1 | cut -d= -f2-)"
  stable="$(grep -E '^stable=' "$output_file" | head -1 | cut -d= -f2-)"
  candidate_tag="$(grep -E '^candidate_tag=' "$output_file" | head -1 | cut -d= -f2-)"

  while IFS= read -r line; do
    [[ -z "${line// /}" ]] && continue
    line="${line//\$\{\{ needs.prepare.outputs.candidate_tag \}\}/${candidate_tag}}"
    line="${line//\$\{\{ needs.prepare.outputs.version \}\}/${version}}"
    line="${line//\$\{\{ needs.prepare.outputs.major_minor \}\}/${major_minor}}"
    line="${line//\$\{\{ needs.prepare.outputs.major \}\}/${major}}"
    line="${line//\$\{\{ needs.prepare.outputs.stable == \'true\' \}\}/${stable}}"

    enable="true"
    if [[ "$line" == *",enable="* ]]; then
      enable="${line##*,enable=}"
      line="${line%%,enable=*}"
    fi
    value="${line#type=raw,value=}"
    [[ "$enable" == "true" ]] && printf '%s\n' "$value"
  done < "${EXTRACT_DIR}/metadata_tags.txt"
}

assert_tag_set() {
  local case_name="$1" expected="$2"
  local actual
  actual="$(effective_tags "${EXTRACT_DIR}/output_${case_name}.txt" | sort | tr '\n' ' ')"
  actual="${actual% }"
  assert_eq "$expected" "$actual" "${case_name} publishes exactly the normalized tag set"
  assert_not_contains "$actual" "v0." "${case_name} never publishes an unnormalized v-prefixed tag"
}

run_case() {
  local name="$1" event_name="$2" client_payload_version="$3" input_tag="$4"
  local ref_name="${5:-}" workflow_ref="${6:-refs/heads/main}" default_branch="${7:-main}"

  local out_file="${EXTRACT_DIR}/output_${name}.txt"
  : > "$out_file"
  (
    export GITHUB_REF_NAME="$ref_name"
    export GITHUB_OUTPUT="$out_file"
    export EVENT_NAME="$event_name"
    export WORKFLOW_REF="$workflow_ref"
    export DISPATCH_VERSION="$client_payload_version"
    export WORKFLOW_TAG="$input_tag"
    export REPOSITORY="FerriteLabs/ferrite-ops"
    export DEFAULT_BRANCH="$default_branch"
    export RUN_ID="$EXPECTED_RUN_ID"
    export RUN_ATTEMPT="$EXPECTED_RUN_ATTEMPT"
    export ORDER_SCRIPT="${REPO_ROOT}/scripts/release-ordering.sh"
    export CHECKSUM_SCRIPT="${REPO_ROOT}/scripts/compute-source-checksum.sh"
    bash "${EXTRACT_DIR}/release_meta.sh"
  )
}

if run_case "push_tag" push "" "" "v${EXPECTED_VERSION}" "refs/tags/v${EXPECTED_VERSION}" \
  >"${EXTRACT_DIR}/log_push_tag.txt" 2>&1; then
  OUT="$(cat "${EXTRACT_DIR}/output_push_tag.txt")"
  assert_contains "$OUT" "version=${EXPECTED_VERSION}" "push-tag case derives active version from GITHUB_REF_NAME"
  assert_contains "$OUT" "major_minor=${EXPECTED_MAJOR_MINOR}" "push-tag case derives normalized major.minor tag"
  assert_contains "$OUT" "major=${EXPECTED_MAJOR}" "push-tag case derives normalized major tag"
  assert_contains "$OUT" "stable=true" "push-tag stable release enables rolling semver/latest tags"
  assert_contains "$OUT" "FERRITE_VERSION=${EXPECTED_VERSION}" "push-tag case emits FERRITE_VERSION build-arg"
  assert_contains "$OUT" "FERRITE_SOURCE_SHA256=${EXPECTED_SHA256}" \
    "push-tag case computes the active release source SHA256"
  IDENTITY_REGEXP="$(sed -n 's/^certificate_identity_regexp=//p' "${EXTRACT_DIR}/output_push_tag.txt")"
  assert_true "$(echo "https://github.com/FerriteLabs/ferrite-ops/.github/workflows/release.yml@refs/tags/v${EXPECTED_VERSION}" | grep -qE "$IDENTITY_REGEXP"; echo $?)" \
    "the derived identity regexp matches the exact normalized push tag"
  assert_true "$(echo "https://github.com/FerriteLabs/ferrite-ops/.github/workflows/release.yml@refs/heads/main" | grep -qE "$IDENTITY_REGEXP"; echo $?)" \
    "the derived identity regexp matches trusted dispatches on main"
  for untrusted in \
    "https://github.com/FerriteLabs/ferrite-ops/.github/workflows/release.yml@refs/tags/v9.9.9" \
    "https://github.com/FerriteLabs/ferrite-ops/.github/workflows/release.yml@refs/heads/feature-x" \
    "https://github.com/FerriteLabs/ferrite-ops/.github/workflows/ci.yml@refs/tags/v${EXPECTED_VERSION}" \
    "https://github.com/other/ferrite-ops/.github/workflows/release.yml@refs/tags/v${EXPECTED_VERSION}"; do
    if echo "$untrusted" | grep -qE "$IDENTITY_REGEXP"; then
      harness_fail "the derived identity regexp incorrectly matched an untrusted identity: ${untrusted}"
    else
      harness_ok "the derived identity regexp rejects an untrusted identity: ${untrusted}"
    fi
  done
  assert_tag_set push_tag "$EXPECTED_CANDIDATE_TAG"
else
  harness_fail "push-tag case unexpectedly failed: $(cat "${EXTRACT_DIR}/log_push_tag.txt")"
fi

if run_case "workflow_dispatch" workflow_dispatch "" "v${EXPECTED_VERSION}" >"${EXTRACT_DIR}/log_workflow_dispatch.txt" 2>&1; then
  OUT="$(cat "${EXTRACT_DIR}/output_workflow_dispatch.txt")"
  assert_contains "$OUT" "version=${EXPECTED_VERSION}" \
    "workflow_dispatch derives the active version from its version tag input"
  assert_contains "$OUT" "FERRITE_VERSION=${EXPECTED_VERSION}" \
    "workflow_dispatch emits an explicit FERRITE_VERSION build-arg"
  assert_contains "$OUT" "FERRITE_SOURCE_SHA256=${EXPECTED_SHA256}" \
    "workflow_dispatch computes and emits the active source checksum"
  assert_tag_set workflow_dispatch "$EXPECTED_CANDIDATE_TAG"
else
  harness_fail "workflow_dispatch case unexpectedly failed: $(cat "${EXTRACT_DIR}/log_workflow_dispatch.txt")"
fi

if run_case "workflow_dispatch_default_branch" workflow_dispatch "" "v${EXPECTED_VERSION}" \
  "" "refs/heads/trunk" "trunk" >"${EXTRACT_DIR}/log_workflow_dispatch_default_branch.txt" 2>&1; then
  DEFAULT_IDENTITY_REGEXP="$(
    sed -n 's/^certificate_identity_regexp=//p' \
      "${EXTRACT_DIR}/output_workflow_dispatch_default_branch.txt"
  )"
  assert_true "$(echo "https://github.com/FerriteLabs/ferrite-ops/.github/workflows/release.yml@refs/heads/trunk" | grep -qE "$DEFAULT_IDENTITY_REGEXP"; echo $?)" \
    "dispatch accepts the exact configured non-main default branch and includes it in Cosign identity trust"
else
  harness_fail "workflow_dispatch unexpectedly rejected the exact configured non-main default branch: $(cat "${EXTRACT_DIR}/log_workflow_dispatch_default_branch.txt")"
fi

TAG_DISPATCH_CURL_MARKER="${EXTRACT_DIR}/tag_dispatch_curl_called"
export TAG_DISPATCH_CURL_MARKER
if (
  curl() {
    touch "$TAG_DISPATCH_CURL_MARKER"
    return 1
  }
  export -f curl
  run_case "workflow_dispatch_tag_ref" workflow_dispatch "" "v${EXPECTED_VERSION}" \
    "v${EXPECTED_VERSION}" "refs/tags/v${EXPECTED_VERSION}"
) >"${EXTRACT_DIR}/log_workflow_dispatch_tag_ref.txt" 2>&1; then
  harness_fail "workflow_dispatch unexpectedly accepted a historical tag ref"
else
  assert_contains "$(cat "${EXTRACT_DIR}/log_workflow_dispatch_tag_ref.txt")" \
    "Dispatch releases must run on refs/heads/main or the configured default branch" \
    "manual dispatch on a tag is rejected with a clear trust error"
fi
if [ -e "$TAG_DISPATCH_CURL_MARKER" ]; then
  harness_fail "manual dispatch on a tag reached checksum retrieval before being rejected"
else
  harness_ok "manual dispatch on a tag is rejected before checksum retrieval or registry-capable jobs"
fi

if run_case "push_ref_mismatch" push "" "" "v${EXPECTED_VERSION}" \
  "refs/tags/v9.9.9" >"${EXTRACT_DIR}/log_push_ref_mismatch.txt" 2>&1; then
  harness_fail "push release unexpectedly accepted a tag ref that did not match the candidate"
else
  assert_contains "$(cat "${EXTRACT_DIR}/log_push_ref_mismatch.txt")" \
    "Push releases must run on the exact candidate tag" \
    "push release rejects a ref/candidate mismatch"
fi

# --- Normalized concurrency (item 3): a "v"-prefixed input and its bare
# equivalent MUST normalize to the exact same version, since the complete
# release-transaction keys its job-level concurrency group directly on this
# output -- if "v1.2.3" and "1.2.3" produced different `version=` values,
# the two spellings would never serialize against each other and could race
# the same release transaction concurrently.
if run_case "workflow_dispatch_bare" workflow_dispatch "" "${EXPECTED_VERSION}" \
  >"${EXTRACT_DIR}/log_workflow_dispatch_bare.txt" 2>&1; then
  VERSION_V="$(grep -E '^version=' "${EXTRACT_DIR}/output_workflow_dispatch.txt" | head -1)"
  VERSION_BARE="$(grep -E '^version=' "${EXTRACT_DIR}/output_workflow_dispatch_bare.txt" | head -1)"
  assert_eq "$VERSION_V" "$VERSION_BARE" \
    "a 'v${EXPECTED_VERSION}' input and a bare '${EXPECTED_VERSION}' input normalize to the IDENTICAL version -- and therefore the identical job-level concurrency group -- so they can never race each other"
else
  harness_fail "bare-version workflow_dispatch case unexpectedly failed: $(cat "${EXTRACT_DIR}/log_workflow_dispatch_bare.txt")"
fi

if run_case "repository_dispatch" repository_dispatch "v${EXPECTED_VERSION}" "" \
  >"${EXTRACT_DIR}/log_repository_dispatch.txt" 2>&1; then
  OUT="$(cat "${EXTRACT_DIR}/output_repository_dispatch.txt")"
  assert_contains "$OUT" "version=${EXPECTED_VERSION}" \
    "repository_dispatch normalizes the active version to the exact tag"
  assert_contains "$OUT" "major_minor=${EXPECTED_MAJOR_MINOR}" \
    "repository_dispatch emits the active major.minor rolling tag"
  assert_contains "$OUT" "major=${EXPECTED_MAJOR}" \
    "repository_dispatch emits the active major rolling tag"
  assert_contains "$OUT" "stable=true" \
    "repository_dispatch stable release enables latest"
  assert_tag_set repository_dispatch "$EXPECTED_CANDIDATE_TAG"
else
  harness_fail "repository_dispatch case unexpectedly failed: $(cat "${EXTRACT_DIR}/log_repository_dispatch.txt")"
fi

if (
  curl() { printf 'prerelease-source-fixture'; }
  export -f curl
  run_case "prerelease" workflow_dispatch "" "v0.5.0-rc.1"
) >"${EXTRACT_DIR}/log_prerelease.txt" 2>&1; then
  OUT="$(cat "${EXTRACT_DIR}/output_prerelease.txt")"
  assert_contains "$OUT" "version=0.5.0-rc.1" \
    "prerelease keeps its normalized exact semver tag"
  assert_contains "$OUT" "stable=false" \
    "prerelease disables major, major.minor, and latest rolling tags"
  assert_tag_set prerelease "$EXPECTED_CANDIDATE_TAG"
else
  harness_fail "prerelease case unexpectedly failed: $(cat "${EXTRACT_DIR}/log_prerelease.txt")"
fi

if run_case "bad_semver" push "" "" "not-a-version" "refs/tags/vnot-a-version" \
  >"${EXTRACT_DIR}/log_bad_semver.txt" 2>&1; then
  harness_fail "push-tag case with an invalid semver unexpectedly succeeded"
else
  assert_contains "$(cat "${EXTRACT_DIR}/log_bad_semver.txt")" "Invalid semver" \
    "an invalid semver version fails release.yml's derivation step with a clear error"
fi

# Functional replay of Docker Hub publishing eligibility. Docker Hub tags
# may be generated only when the repository variable is exactly true and
# both credentials needed by docker/login-action are non-empty.
DOCKERHUB_ELIGIBILITY_SCRIPT="$(cat "${EXTRACT_DIR}/dockerhub_eligibility.sh")"

run_dockerhub_eligibility() {
  local enabled="$1" username="$2" token="$3" output="$4"
  (
    export DOCKERHUB_ENABLED="$enabled"
    export DOCKERHUB_USERNAME="$username"
    export DOCKERHUB_TOKEN="$token"
    export GITHUB_OUTPUT="$output"
    bash -c "$DOCKERHUB_ELIGIBILITY_SCRIPT"
  )
}

assert_dockerhub_eligibility() {
  local case_name="$1" enabled="$2" username="$3" token="$4" expected="$5"
  local output="${EXTRACT_DIR}/dockerhub_${case_name}.out"
  : > "$output"
  if run_dockerhub_eligibility "$enabled" "$username" "$token" "$output" \
    >"${EXTRACT_DIR}/log_dockerhub_${case_name}.txt" 2>&1; then
    assert_contains "$(cat "$output")" "enabled=${expected}" \
      "Docker Hub eligibility ${case_name} resolves to enabled=${expected}"
  else
    harness_fail "Docker Hub eligibility ${case_name} unexpectedly failed: $(cat "${EXTRACT_DIR}/log_dockerhub_${case_name}.txt")"
  fi
}

assert_dockerhub_eligibility "disabled" "false" "user" "token" "false"
assert_dockerhub_eligibility "missing_variable" "" "user" "token" "false"
assert_dockerhub_eligibility "missing_username" "true" "" "token" "false"
assert_dockerhub_eligibility "missing_token" "true" "user" "" "false"
assert_dockerhub_eligibility "configured" "true" "user" "token" "true"

# Functional replay of the "Combine registry tags and labels" step: prove
# that an empty DOCKERHUB_TAGS (meta_dockerhub did not run, i.e.
# DOCKERHUB_ENABLED is unset/false or credentials are missing) yields a
# combined tag list containing only the GHCR tags, and that a non-empty
# DOCKERHUB_TAGS (enabled and fully configured) appends Docker Hub tags.
COMBINE_SCRIPT="$(cat "${EXTRACT_DIR}/combine_tags.sh")"
GHCR_SAMPLE_TAGS="$(printf 'ghcr.io/ferritelabs/ferrite:%s\nghcr.io/ferritelabs/ferrite:latest' "$EXPECTED_VERSION")"
GHCR_SAMPLE_LABELS="org.opencontainers.image.version=${EXPECTED_VERSION}"
DOCKERHUB_SAMPLE_TAGS="$(printf 'ferritelabs/ferrite:%s\nferritelabs/ferrite:latest' "$EXPECTED_VERSION")"

run_combine() {
  local dockerhub_tags="$1" output="$2"
  (
    export GHCR_TAGS="$GHCR_SAMPLE_TAGS"
    export GHCR_LABELS="$GHCR_SAMPLE_LABELS"
    export DOCKERHUB_TAGS="$dockerhub_tags"
    export GITHUB_OUTPUT="$output"
    bash -c "$COMBINE_SCRIPT"
  )
}

DISABLED_OUT="${EXTRACT_DIR}/combine_disabled.out"
: > "$DISABLED_OUT"
if run_combine "" "$DISABLED_OUT" >"${EXTRACT_DIR}/log_combine_disabled.txt" 2>&1; then
  DISABLED_CONTENT="$(cat "$DISABLED_OUT")"
  assert_contains "$DISABLED_CONTENT" "$GHCR_SAMPLE_TAGS" \
    "disabled Docker Hub: combined tags still contain every GHCR tag"
  if printf '%s\n' "$DISABLED_CONTENT" | grep -qx "ferritelabs/ferrite:${EXPECTED_VERSION}"; then
    harness_fail "disabled/missing DOCKERHUB_ENABLED: combined tags unexpectedly contain a Docker Hub tag"
  else
    harness_ok "disabled/missing DOCKERHUB_ENABLED: combined tags contain no Docker Hub tag"
  fi
else
  harness_fail "combine-tags step unexpectedly failed with empty DOCKERHUB_TAGS: $(cat "${EXTRACT_DIR}/log_combine_disabled.txt")"
fi

ENABLED_OUT="${EXTRACT_DIR}/combine_enabled.out"
: > "$ENABLED_OUT"
if run_combine "$DOCKERHUB_SAMPLE_TAGS" "$ENABLED_OUT" >"${EXTRACT_DIR}/log_combine_enabled.txt" 2>&1; then
  ENABLED_CONTENT="$(cat "$ENABLED_OUT")"
  assert_contains "$ENABLED_CONTENT" "$GHCR_SAMPLE_TAGS" \
    "enabled Docker Hub: combined tags still contain every GHCR tag"
  assert_contains "$ENABLED_CONTENT" "$DOCKERHUB_SAMPLE_TAGS" \
    "DOCKERHUB_ENABLED=true: combined tags include the Docker Hub tags produced by meta_dockerhub"
else
  harness_fail "combine-tags step unexpectedly failed with non-empty DOCKERHUB_TAGS: $(cat "${EXTRACT_DIR}/log_combine_enabled.txt")"
fi

# Exercise every payload-consuming metadata script with shell-substitution
# strings. They must reject the value as invalid data without executing it.
MALICIOUS_MARKER="${EXTRACT_DIR}/payload-executed"
MALICIOUS_VERSION="${EXPECTED_VERSION}\$(touch ${MALICIOUS_MARKER})"
MALICIOUS_SHA256="\$(touch ${MALICIOUS_MARKER})"

if run_case "malicious_release" repository_dispatch "$MALICIOUS_VERSION" "" \
  >"${EXTRACT_DIR}/log_malicious_release.txt" 2>&1; then
  harness_fail "release.yml unexpectedly accepted a malicious dispatch version"
else
  harness_ok "release.yml rejects malicious dispatch versions"
fi
if [[ ! -e "$MALICIOUS_MARKER" ]]; then
  harness_ok "release.yml treats command substitutions as inert input data"
else
  harness_fail "release.yml executed a command substitution from input data"
fi

run_version_sync_meta() {
  local version="$1" checksum="$2" output="$3"
  (
    export EVENT_NAME="repository_dispatch"
    export DISPATCH_VERSION="$version"
    export WORKFLOW_VERSION=""
    export INPUT_SHA256="$checksum"
    export REPOSITORY_OWNER="FerriteLabs"
    export GITHUB_OUTPUT="$output"
    export CHECKSUM_SCRIPT="${REPO_ROOT}/scripts/compute-source-checksum.sh"
    bash "${EXTRACT_DIR}/version_sync_meta.sh"
  )
}

if run_version_sync_meta "$MALICIOUS_VERSION" "$SYNC_SHA256" \
  "${EXTRACT_DIR}/malicious_sync_version.out" >/dev/null 2>&1; then
  harness_fail "version-sync.yml unexpectedly accepted a malicious dispatch version"
else
  harness_ok "version-sync.yml rejects malicious dispatch versions"
fi
if run_version_sync_meta "$EXPECTED_VERSION" "$MALICIOUS_SHA256" \
  "${EXTRACT_DIR}/malicious_sync_checksum.out" >/dev/null 2>&1; then
  harness_fail "version-sync.yml unexpectedly accepted a malicious checksum"
else
  harness_ok "version-sync.yml rejects malicious supplied checksums"
fi
if [[ ! -e "$MALICIOUS_MARKER" ]]; then
  harness_ok "version-sync.yml treats command substitutions as inert input data"
else
  harness_fail "version-sync.yml executed a command substitution from input data"
fi

# Functional replay of an actual `ferrite-release` payload end to end. Core's
# release workflow dispatches event_type "ferrite-release" with
# client_payload {version, sha256} (see
# ferrite/.github/workflows/release.yml and release-full.yml). GitHub
# Actions exposes client_payload the same way regardless of the dispatch's
# custom event_type name, so this proves version-sync.yml both parses that
# real payload shape and applies the full active-release transaction from
# it — the scenario core actually triggers on every release.
FERRITE_RELEASE_VERSION="9.9.9"
# The shared checksum helper now ALWAYS downloads and computes the canonical
# source archive checksum itself (see compute-source-checksum.sh), so this
# fake, non-existent tag's payload checksum must match a fake but
# deterministic "download" rather than an arbitrary literal: fake `curl` to
# return fixed content and use ITS real SHA256 as the payload's supplied
# (and expected canonical) checksum.
FERRITE_RELEASE_CONTENT="ferrite-release-dispatch-fixture"
FERRITE_RELEASE_SHA256="$(printf '%s' "$FERRITE_RELEASE_CONTENT" | shasum -a 256 | awk '{print $1}')"
if (
  curl() { printf '%s' "$FERRITE_RELEASE_CONTENT"; }
  export -f curl
  export FERRITE_RELEASE_CONTENT
  run_version_sync_meta "$FERRITE_RELEASE_VERSION" "$FERRITE_RELEASE_SHA256" \
    "${EXTRACT_DIR}/ferrite_release_meta.out"
) >"${EXTRACT_DIR}/log_ferrite_release_meta.txt" 2>&1; then
  META_OUT="$(cat "${EXTRACT_DIR}/ferrite_release_meta.out")"
  assert_contains "$META_OUT" "version=${FERRITE_RELEASE_VERSION}" \
    "version-sync.yml extracts the version from a ferrite-release dispatch payload"
  assert_contains "$META_OUT" "sha256=${FERRITE_RELEASE_SHA256}" \
    "version-sync.yml extracts the sha256 from a ferrite-release dispatch payload"

  FERRITE_RELEASE_DIR="${EXTRACT_DIR}/ferrite-release-sync"
  mkdir -p "$FERRITE_RELEASE_DIR"
  copy_sync_targets "$FERRITE_RELEASE_DIR"
  if (cd "$FERRITE_RELEASE_DIR" &&
    VERSION="$FERRITE_RELEASE_VERSION" SHA256="$FERRITE_RELEASE_SHA256" bash -c "$SYNC_SCRIPT"); then
    assert_contains "$(cat "${FERRITE_RELEASE_DIR}/active-release.env")" \
      "FERRITE_VERSION=${FERRITE_RELEASE_VERSION}" \
      "a ferrite-release dispatch payload updates canonical release version end to end"
    assert_contains "$(cat "${FERRITE_RELEASE_DIR}/active-release.env")" \
      "FERRITE_SOURCE_SHA256=${FERRITE_RELEASE_SHA256}" \
      "a ferrite-release dispatch payload updates the canonical release checksum end to end"
    assert_contains "$(cat "${FERRITE_RELEASE_DIR}/charts/ferrite/Chart.yaml")" \
      "appVersion: \"${FERRITE_RELEASE_VERSION}\"" \
      "a ferrite-release dispatch payload updates the primary chart end to end"
    assert_contains "$(cat "${FERRITE_RELEASE_DIR}/charts/ferrite-sidecar/Chart.yaml")" \
      "appVersion: \"${FERRITE_RELEASE_VERSION}\"" \
      "a ferrite-release dispatch payload updates the sidecar chart appVersion end to end"
    assert_contains "$(cat "${FERRITE_RELEASE_DIR}/gitops/kustomize/base/statefulset.yaml")" \
      "image: ghcr.io/ferritelabs/ferrite:${FERRITE_RELEASE_VERSION}" \
      "a ferrite-release dispatch payload updates the Kustomize base StatefulSet image tag end to end, preserving its GHCR repository"
    for dockerfile in Dockerfile Dockerfile.moonshot Dockerfile.playground; do
      assert_contains "$(cat "${FERRITE_RELEASE_DIR}/${dockerfile}")" \
        "ARG FERRITE_VERSION=${FERRITE_RELEASE_VERSION}" \
        "a ferrite-release dispatch payload updates ${dockerfile} end to end"
    done
  else
    harness_fail "ferrite-release payload functional replay of the active-release transaction unexpectedly failed"
  fi
else
  harness_fail "version-sync.yml unexpectedly rejected a valid ferrite-release dispatch payload: $(cat "${EXTRACT_DIR}/log_ferrite_release_meta.txt")"
fi

run_orchestration_meta() {
  local version="$1" checksum="$2" output="$3"
  (
    export INPUT_VERSION="$version"
    export INPUT_SHA256="$checksum"
    export REPOSITORY_OWNER="FerriteLabs"
    export GITHUB_OUTPUT="$output"
    export ORDER_SCRIPT="${REPO_ROOT}/scripts/release-ordering.sh"
    export CHECKSUM_SCRIPT="${REPO_ROOT}/scripts/compute-source-checksum.sh"
    bash "${EXTRACT_DIR}/orchestration_meta.sh"
  )
}

if run_orchestration_meta "$MALICIOUS_VERSION" "$SYNC_SHA256" \
  "${EXTRACT_DIR}/malicious_orchestration_version.out" >/dev/null 2>&1; then
  harness_fail "release-orchestration.yml unexpectedly accepted a malicious version"
else
  harness_ok "release-orchestration.yml rejects malicious versions"
fi
if run_orchestration_meta "$EXPECTED_VERSION" "$MALICIOUS_SHA256" \
  "${EXTRACT_DIR}/malicious_orchestration_checksum.out" >/dev/null 2>&1; then
  harness_fail "release-orchestration.yml unexpectedly accepted a malicious checksum"
else
  harness_ok "release-orchestration.yml rejects malicious supplied checksums"
fi
if [[ ! -e "$MALICIOUS_MARKER" ]]; then
  harness_ok "release-orchestration.yml treats command substitutions as inert input data"
else
  harness_fail "release-orchestration.yml executed a command substitution from input data"
fi

# Strict SemVer: the shared validator, not a locally duplicated regex, must
# reject a leading zero in either the core or a numeric pre-release
# identifier -- something the OLD locally duplicated regex silently accepted.
if run_orchestration_meta "1.2.3-01" "$SYNC_SHA256" \
  "${EXTRACT_DIR}/leading_zero_orchestration.out" >/dev/null 2>&1; then
  harness_fail "release-orchestration.yml unexpectedly accepted a leading-zero pre-release identifier"
else
  harness_ok "release-orchestration.yml rejects a leading-zero numeric pre-release identifier via the shared validator"
fi
if run_orchestration_meta "01.2.3" "$SYNC_SHA256" \
  "${EXTRACT_DIR}/leading_zero_core_orchestration.out" >/dev/null 2>&1; then
  harness_fail "release-orchestration.yml unexpectedly accepted a leading-zero version core"
else
  harness_ok "release-orchestration.yml rejects a leading-zero version core via the shared validator"
fi

# Uppercase supplied checksums are normalized before being emitted, and a
# valid uppercase value that matches the canonical computed checksum
# (case-insensitively) is accepted rather than rejected as a mismatch.
NORMALIZATION_CONTENT="ferrite-checksum-normalization-fixture"
NORMALIZATION_SHA256="$(printf '%s' "$NORMALIZATION_CONTENT" | shasum -a 256 | awk '{print $1}')"
UPPER_SHA256="$(printf '%s' "$NORMALIZATION_SHA256" | tr 'a-f' 'A-F')"
if (
  curl() { printf '%s' "$NORMALIZATION_CONTENT"; }
  export -f curl
  export NORMALIZATION_CONTENT
  run_version_sync_meta "v9.8.7" "$UPPER_SHA256" \
    "${EXTRACT_DIR}/normalized_sync.out"
) >/dev/null 2>&1; then
  assert_contains "$(cat "${EXTRACT_DIR}/normalized_sync.out")" "sha256=${NORMALIZATION_SHA256}" \
    "version-sync.yml normalizes a valid supplied checksum to lowercase"
else
  harness_fail "version-sync.yml rejected a valid uppercase checksum matching the canonical computed source"
fi

# A syntactically valid but WRONG supplied checksum (right shape, does not
# match the canonical computed source) must be rejected outright rather than
# silently trusted or silently replaced.
MISMATCH_SHA256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
if (
  curl() { printf '%s' "$NORMALIZATION_CONTENT"; }
  export -f curl
  export NORMALIZATION_CONTENT
  run_version_sync_meta "v9.8.7" "$MISMATCH_SHA256" \
    "${EXTRACT_DIR}/mismatch_sync.out"
) >"${EXTRACT_DIR}/log_mismatch_sync.txt" 2>&1; then
  harness_fail "version-sync.yml unexpectedly accepted a syntactically valid but mismatched supplied checksum"
else
  assert_contains "$(cat "${EXTRACT_DIR}/log_mismatch_sync.txt")" "does not match the canonical computed checksum" \
    "version-sync.yml rejects a syntactically valid supplied checksum that does not match the canonical download"
fi

# No supplied checksum at all: the canonical value is downloaded and
# computed from scratch.
if (
  curl() { printf '%s' "$NORMALIZATION_CONTENT"; }
  export -f curl
  export NORMALIZATION_CONTENT
  run_version_sync_meta "v9.8.7" "" \
    "${EXTRACT_DIR}/no_supplied_sync.out"
) >"${EXTRACT_DIR}/log_no_supplied_sync.txt" 2>&1; then
  assert_contains "$(cat "${EXTRACT_DIR}/no_supplied_sync.out")" "sha256=${NORMALIZATION_SHA256}" \
    "version-sync.yml computes the canonical checksum end to end when none is supplied"
else
  harness_fail "version-sync.yml unexpectedly failed with no supplied checksum: $(cat "${EXTRACT_DIR}/log_no_supplied_sync.txt")"
fi

# A download failure (network error, missing tag, ...) must fail the sync
# rather than silently proceeding without a canonical checksum.
if (
  curl() { return 22; }
  export -f curl
  run_version_sync_meta "v9.8.7" "" \
    "${EXTRACT_DIR}/download_failure_sync.out"
) >"${EXTRACT_DIR}/log_download_failure_sync.txt" 2>&1; then
  harness_fail "version-sync.yml unexpectedly succeeded despite a canonical source download failure"
else
  assert_contains "$(cat "${EXTRACT_DIR}/log_download_failure_sync.txt")" "failed to download or hash the canonical source archive" \
    "version-sync.yml fails closed when the canonical source archive cannot be downloaded"
fi

if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$RELEASE_YML" "$RECONCILE_YML" "$VERSION_SYNC_YML" "$ORCHESTRATION_YML"; then
    harness_ok "actionlint accepts hardened release workflows"
  else
    harness_fail "actionlint rejected hardened release workflows"
  fi
else
  echo "  skip: actionlint not available; workflow YAML was parsed and structurally checked with PyYAML."
fi

harness_summary
