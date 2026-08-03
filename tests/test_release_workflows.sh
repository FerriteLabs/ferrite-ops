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
VERSION_SYNC_YML="${REPO_ROOT}/.github/workflows/version-sync.yml"
ORCHESTRATION_YML="${REPO_ROOT}/.github/workflows/release-orchestration.yml"
ACTIVE_RELEASE="${REPO_ROOT}/active-release.env"

for f in "$RELEASE_YML" "$VERSION_SYNC_YML" "$ORCHESTRATION_YML" "$ACTIVE_RELEASE"; do
  if [[ ! -f "$f" ]]; then
    echo "  FAIL: ${f} not found" >&2
    exit 1
  fi
done

EXPECTED_VERSION="$(sed -n 's/^FERRITE_VERSION=//p' "$ACTIVE_RELEASE")"
EXPECTED_SHA256="$(sed -n 's/^FERRITE_SOURCE_SHA256=//p' "$ACTIVE_RELEASE")"
EXPECTED_MAJOR="${EXPECTED_VERSION%%.*}"
EXPECTED_MAJOR_MINOR="${EXPECTED_VERSION%.*}"
EXPECTED_TAG_SET="${EXPECTED_MAJOR} ${EXPECTED_MAJOR_MINOR} ${EXPECTED_VERSION} latest"
RELEASE_CONTENT="$(cat "$RELEASE_YML")"
VERSION_SYNC_CONTENT="$(cat "$VERSION_SYNC_YML")"
ORCHESTRATION_CONTENT="$(cat "$ORCHESTRATION_YML")"

# --- Static checks: release.yml ---------------------------------------------
assert_contains "$RELEASE_CONTENT" "FERRITE_SOURCE_SHA256" \
  "release.yml derives a FERRITE_SOURCE_SHA256 for the image it publishes"
assert_contains "$RELEASE_CONTENT" "build-args: \${{ steps.release_meta.outputs.build_args }}" \
  "release.yml passes the derived FERRITE_VERSION/FERRITE_SOURCE_SHA256 to docker/build-push-action"
assert_contains "$RELEASE_CONTENT" 'grep -qE' \
  "release.yml validates the derived version against a semver pattern"
assert_contains "$RELEASE_CONTENT" "'^[0-9a-f]{64}$'" \
  "release.yml validates computed source checksums as exactly 64 hexadecimal characters"
assert_contains "$RELEASE_CONTENT" "shasum -a 256" \
  "release.yml computes the source archive checksum"
assert_contains "$RELEASE_CONTENT" "GITHUB_REF_NAME" \
  "release.yml derives the version from the push-tag ref for tag pushes"
assert_contains "$RELEASE_CONTENT" "github.event.client_payload.version" \
  "release.yml derives the version from repository_dispatch client_payload.version"
assert_contains "$RELEASE_CONTENT" "inputs.tag" \
  "release.yml derives the version from the workflow_dispatch input"
assert_contains "$RELEASE_CONTENT" "default: 'v${EXPECTED_VERSION}'" \
  "release.yml's workflow_dispatch default matches active-release.env"
assert_contains "$RELEASE_CONTENT" 'type=raw,value=${{ steps.release_meta.outputs.version }}' \
  "release.yml tags every trigger with the normalized exact semver"
assert_contains "$RELEASE_CONTENT" 'type=raw,value=${{ steps.release_meta.outputs.major_minor }}' \
  "release.yml derives the normalized major.minor tag from release_meta"
assert_contains "$RELEASE_CONTENT" 'type=raw,value=${{ steps.release_meta.outputs.major }}' \
  "release.yml derives the normalized major tag from release_meta"
assert_contains "$RELEASE_CONTENT" 'type=raw,value=latest,enable=${{ steps.release_meta.outputs.stable == '\''true'\'' }}' \
  "release.yml publishes latest only for stable semver releases"
assert_not_contains "$RELEASE_CONTENT" 'type=raw,value=${{ inputs.tag }}' \
  "workflow_dispatch does not publish an unnormalized raw v-prefixed tag"
assert_contains "$RELEASE_CONTENT" "latest=false" \
  "release.yml disables docker/metadata-action's implicit latest tag"
assert_not_contains "$RELEASE_CONTENT" "bump-chart" \
  "release.yml no longer runs its own competing chart-only bump job"
assert_not_contains "$RELEASE_CONTENT" "charts/ferrite" \
  "release.yml does not touch chart files; version-sync.yml is the single workflow that does"
assert_contains "$ORCHESTRATION_CONTENT" "charts/ferrite-sidecar/Chart.yaml" \
  "release-orchestration.yml updates the sidecar chart appVersion"

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
assert_contains "$VERSION_SYNC_CONTENT" "'^[0-9a-f]{64}$'" \
  "version-sync.yml validates supplied and computed source checksums"
assert_contains "$VERSION_SYNC_CONTENT" "shasum -a 256" \
  "version-sync.yml computes the source checksum when not explicitly provided"
assert_contains "$VERSION_SYNC_CONTENT" "charts/ferrite-sidecar/Chart.yaml" \
  "version-sync.yml keeps the sidecar appVersion synchronized"
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
assert_contains "$ORCHESTRATION_CONTENT" "'^[0-9a-f]{64}$'" \
  "release-orchestration.yml validates supplied and computed source checksums"

# No GitHub expression is allowed inside a run script in these privileged
# release workflows. Untrusted values enter scripts only through step env.
if command -v python3 >/dev/null 2>&1 &&
  python3 -c "import yaml" >/dev/null 2>&1 &&
  python3 - "$RELEASE_YML" "$VERSION_SYNC_YML" "$ORCHESTRATION_YML" <<'PYEOF'
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
# for backward compatibility), and release.yml must no longer run a
# competing job of its own that partially updates chart files.
if command -v python3 >/dev/null 2>&1 &&
  python3 -c "import yaml" >/dev/null 2>&1 &&
  python3 - "$VERSION_SYNC_YML" "$RELEASE_YML" <<'TRIGGERCHECK'
import sys
import yaml

version_sync_path, release_path = sys.argv[1:]

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
TRIGGERCHECK
then
  harness_ok "version-sync.yml is the sole ferrite-release chart/Dockerfile/pin sync workflow"
else
  harness_fail "release.yml and version-sync.yml disagree on which workflow owns the ferrite-release sync"
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
  "$EXTRACT_DIR/version_sync_chart.sh" \
  "$EXTRACT_DIR/orchestration_chart.sh" "$EXTRACT_DIR/metadata_tags.txt" \
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
    orchestration_chart_out_path,
    metadata_tags_out_path,
) = sys.argv[1:]
with open(release_yml_path) as f:
    doc = yaml.safe_load(f)

steps = doc["jobs"]["build-and-push"]["steps"]
script = next(s["run"] for s in steps if s.get("name") == "Determine release version and source checksum")
release_index = next(i for i, s in enumerate(steps) if s.get("id") == "release_meta")
metadata_index = next(i for i, s in enumerate(steps) if s.get("id") == "meta")
if release_index >= metadata_index:
    raise SystemExit("release_meta must run before docker/metadata-action")

metadata_tags = next(s["with"]["tags"] for s in steps if s.get("id") == "meta")
required_tags = [
    "type=raw,value=${{ steps.release_meta.outputs.version }}",
    "type=raw,value=${{ steps.release_meta.outputs.major_minor }}",
    "type=raw,value=${{ steps.release_meta.outputs.major }}",
    "type=raw,value=latest,enable=${{ steps.release_meta.outputs.stable == 'true' }}",
]
missing_tags = [tag for tag in required_tags if tag not in metadata_tags]
if missing_tags:
    raise SystemExit(f"metadata tags are missing normalized outputs: {missing_tags}")

metadata_flavor = next(
    (s["with"].get("flavor", "") for s in steps if s.get("id") == "meta"), ""
)
if "latest=false" not in metadata_flavor:
    raise SystemExit("docker/metadata-action must disable its implicit latest tag")

with open(metadata_tags_out_path, "w") as f:
    f.write(metadata_tags)

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

with open(orchestration_yml_path) as f:
    orchestration_doc = yaml.safe_load(f)
orchestration_meta_script = next(
    s["run"]
    for s in orchestration_doc["jobs"]["prepare"]["steps"]
    if s.get("name") == "Compute release metadata"
)
with open(orchestration_meta_out_path, "w") as f:
    f.write(orchestration_meta_script)

orchestration_chart_script = next(
    s["run"]
    for s in orchestration_doc["jobs"]["update-ops"]["steps"]
    if s.get("name") == "Update Helm Chart version"
)
with open(orchestration_chart_out_path, "w") as f:
    f.write(orchestration_chart_script)
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
    "targetRevision: v${SYNC_VERSION}" "version-sync functional replay updates Argo CD"
  assert_contains "$(cat "${SYNC_DIR}/gitops/flux/overlays/production.yaml")" \
    "tag: v${SYNC_VERSION}" "version-sync functional replay updates Flux"
  assert_contains "$(cat "${SYNC_DIR}/gitops/kustomize/base/statefulset.yaml")" \
    "image: ferritelabs/ferrite:${SYNC_VERSION}" \
    "version-sync functional replay updates the Kustomize base StatefulSet image"
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

# Replay the remaining chart release path. version-sync.yml's comprehensive
# active-release transaction (exercised above via SYNC_SCRIPT) is the sole
# path that bumps the primary chart's package version; release-orchestration.yml
# separately updates chart appVersions when manually dispatched, and the
# primary package follows the core release while the sidecar package version
# remains independently versioned.
# shellcheck disable=SC2043  # single-element on purpose: release_chart was
# removed when release.yml's competing chart-only bump job was removed; kept
# as a loop so a future additional chart-update path is easy to add back.
for chart_path in orchestration_chart; do
  CHART_DIR="${EXTRACT_DIR}/${chart_path}"
  mkdir -p "${CHART_DIR}/charts/ferrite" "${CHART_DIR}/charts/ferrite-sidecar"
  cp "${REPO_ROOT}/charts/ferrite/Chart.yaml" "${CHART_DIR}/charts/ferrite/Chart.yaml"
  cp "${REPO_ROOT}/charts/ferrite-sidecar/Chart.yaml" \
    "${CHART_DIR}/charts/ferrite-sidecar/Chart.yaml"

  CHART_SCRIPT="$(cat "${EXTRACT_DIR}/${chart_path}.sh")"
  if (cd "$CHART_DIR" && VERSION="9.8.7" bash -c "$CHART_SCRIPT"); then
    assert_contains "$(cat "${CHART_DIR}/charts/ferrite/Chart.yaml")" "version: 9.8.7" \
      "${chart_path} updates the primary chart package version"
    assert_contains "$(cat "${CHART_DIR}/charts/ferrite/Chart.yaml")" 'appVersion: "9.8.7"' \
      "${chart_path} updates the primary chart appVersion"
    assert_contains "$(cat "${CHART_DIR}/charts/ferrite-sidecar/Chart.yaml")" 'appVersion: "9.8.7"' \
      "${chart_path} updates the sidecar chart appVersion"
    assert_contains "$(cat "${CHART_DIR}/charts/ferrite-sidecar/Chart.yaml")" "version: 0.2.0" \
      "${chart_path} preserves the sidecar chart's independent package version"
  else
    harness_fail "${chart_path} chart update functional replay unexpectedly failed"
  fi
done

# Resolve docker/metadata-action's tag template against the outputs a given
# trigger actually produced, so the *effective* published tag set is asserted
# rather than only the template text.
effective_tags() {
  local output_file="$1"
  local version major major_minor stable line value enable

  version="$(grep -E '^version=' "$output_file" | head -1 | cut -d= -f2-)"
  major="$(grep -E '^major=' "$output_file" | head -1 | cut -d= -f2-)"
  major_minor="$(grep -E '^major_minor=' "$output_file" | head -1 | cut -d= -f2-)"
  stable="$(grep -E '^stable=' "$output_file" | head -1 | cut -d= -f2-)"

  while IFS= read -r line; do
    [[ -z "${line// /}" ]] && continue
    line="${line//\$\{\{ steps.release_meta.outputs.version \}\}/${version}}"
    line="${line//\$\{\{ steps.release_meta.outputs.major_minor \}\}/${major_minor}}"
    line="${line//\$\{\{ steps.release_meta.outputs.major \}\}/${major}}"
    line="${line//\$\{\{ steps.release_meta.outputs.stable == \'true\' \}\}/${stable}}"

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
  local name="$1" event_name="$2" client_payload_version="$3" input_tag="$4" ref_name="${5:-}"

  local out_file="${EXTRACT_DIR}/output_${name}.txt"
  : > "$out_file"
  (
    export GITHUB_REF_NAME="$ref_name"
    export GITHUB_OUTPUT="$out_file"
    export EVENT_NAME="$event_name"
    export DISPATCH_VERSION="$client_payload_version"
    export WORKFLOW_TAG="$input_tag"
    export REPOSITORY_OWNER="FerriteLabs"
    bash "${EXTRACT_DIR}/release_meta.sh"
  )
}

if run_case "push_tag" push "" "" "v${EXPECTED_VERSION}" >"${EXTRACT_DIR}/log_push_tag.txt" 2>&1; then
  OUT="$(cat "${EXTRACT_DIR}/output_push_tag.txt")"
  assert_contains "$OUT" "version=${EXPECTED_VERSION}" "push-tag case derives active version from GITHUB_REF_NAME"
  assert_contains "$OUT" "major_minor=${EXPECTED_MAJOR_MINOR}" "push-tag case derives normalized major.minor tag"
  assert_contains "$OUT" "major=${EXPECTED_MAJOR}" "push-tag case derives normalized major tag"
  assert_contains "$OUT" "stable=true" "push-tag stable release enables rolling semver/latest tags"
  assert_contains "$OUT" "FERRITE_VERSION=${EXPECTED_VERSION}" "push-tag case emits FERRITE_VERSION build-arg"
  assert_contains "$OUT" "FERRITE_SOURCE_SHA256=${EXPECTED_SHA256}" \
    "push-tag case computes the active release source SHA256"
  assert_tag_set push_tag "$EXPECTED_TAG_SET"
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
  assert_tag_set workflow_dispatch "$EXPECTED_TAG_SET"
else
  harness_fail "workflow_dispatch case unexpectedly failed: $(cat "${EXTRACT_DIR}/log_workflow_dispatch.txt")"
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
  assert_tag_set repository_dispatch "$EXPECTED_TAG_SET"
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
  assert_tag_set prerelease "0.5.0-rc.1"
else
  harness_fail "prerelease case unexpectedly failed: $(cat "${EXTRACT_DIR}/log_prerelease.txt")"
fi

if run_case "bad_semver" push "" "" "not-a-version" >"${EXTRACT_DIR}/log_bad_semver.txt" 2>&1; then
  harness_fail "push-tag case with an invalid semver unexpectedly succeeded"
else
  assert_contains "$(cat "${EXTRACT_DIR}/log_bad_semver.txt")" "Invalid semver" \
    "an invalid semver version fails release.yml's derivation step with a clear error"
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
FERRITE_RELEASE_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
if run_version_sync_meta "$FERRITE_RELEASE_VERSION" "$FERRITE_RELEASE_SHA256" \
  "${EXTRACT_DIR}/ferrite_release_meta.out" \
  >"${EXTRACT_DIR}/log_ferrite_release_meta.txt" 2>&1; then
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
      "image: ferritelabs/ferrite:${FERRITE_RELEASE_VERSION}" \
      "a ferrite-release dispatch payload updates the Kustomize base StatefulSet image end to end"
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

# Uppercase supplied checksums are normalized before being emitted.
UPPER_SHA256="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
if run_version_sync_meta "v9.8.7" "$UPPER_SHA256" \
  "${EXTRACT_DIR}/normalized_sync.out" >/dev/null 2>&1; then
  assert_contains "$(cat "${EXTRACT_DIR}/normalized_sync.out")" "sha256=${SYNC_SHA256}" \
    "version-sync.yml normalizes a valid supplied checksum to lowercase"
else
  harness_fail "version-sync.yml rejected a valid uppercase checksum"
fi

if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$RELEASE_YML" "$VERSION_SYNC_YML" "$ORCHESTRATION_YML"; then
    harness_ok "actionlint accepts hardened release workflows"
  else
    harness_fail "actionlint rejected hardened release workflows"
  fi
else
  echo "  skip: actionlint not available; workflow YAML was parsed and structurally checked with PyYAML."
fi

harness_summary
