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

for f in "$RELEASE_YML" "$VERSION_SYNC_YML" "$ORCHESTRATION_YML"; do
  if [[ ! -f "$f" ]]; then
    echo "  FAIL: ${f} not found" >&2
    exit 1
  fi
done

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
assert_contains "$RELEASE_CONTENT" "shasum -a 256" \
  "release.yml computes the source archive checksum"
assert_contains "$RELEASE_CONTENT" "GITHUB_REF_NAME" \
  "release.yml derives the version from the push-tag ref for tag pushes"
assert_contains "$RELEASE_CONTENT" "github.event.client_payload.version" \
  "release.yml derives the version from repository_dispatch client_payload.version"
assert_contains "$RELEASE_CONTENT" "inputs.tag" \
  "release.yml derives the version from the workflow_dispatch input"
assert_contains "$RELEASE_CONTENT" "default: 'v0.4.0'" \
  "release.yml's workflow_dispatch default is a concrete semver release"
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
assert_contains "$RELEASE_CONTENT" "charts/ferrite-sidecar/Chart.yaml" \
  "release.yml updates the sidecar chart appVersion with the released Ferrite image"
assert_contains "$ORCHESTRATION_CONTENT" "charts/ferrite-sidecar/Chart.yaml" \
  "release-orchestration.yml updates the sidecar chart appVersion"

# --- Static checks: version-sync.yml ----------------------------------------
for dockerfile in Dockerfile Dockerfile.moonshot Dockerfile.playground; do
  assert_contains "$VERSION_SYNC_CONTENT" "$dockerfile" \
    "version-sync.yml includes ${dockerfile} in the atomic Dockerfile update"
done
assert_contains "$VERSION_SYNC_CONTENT" "DOCKERFILES=(" \
  "version-sync.yml updates all Dockerfile defaults as one validated group"
assert_contains "$VERSION_SYNC_CONTENT" "ARG FERRITE_SOURCE_SHA256=" \
  "version-sync.yml updates each Dockerfile's FERRITE_SOURCE_SHA256 default"
assert_contains "$VERSION_SYNC_CONTENT" "ARG FERRITE_VERSION=" \
  "version-sync.yml updates each Dockerfile's FERRITE_VERSION default"
assert_contains "$VERSION_SYNC_CONTENT" 'grep -qE' \
  "version-sync.yml validates the version against a semver pattern"
assert_contains "$VERSION_SYNC_CONTENT" "shasum -a 256" \
  "version-sync.yml computes the source checksum when not explicitly provided"
assert_contains "$VERSION_SYNC_CONTENT" "charts/ferrite-sidecar/Chart.yaml" \
  "version-sync.yml keeps the sidecar appVersion synchronized"

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
  "$EXTRACT_DIR/release_meta.sh" "$EXTRACT_DIR/update_dockerfiles.sh" \
  "$EXTRACT_DIR/release_chart.sh" "$EXTRACT_DIR/version_sync_chart.sh" \
  "$EXTRACT_DIR/orchestration_chart.sh" "$EXTRACT_DIR/metadata_tags.txt" \
  >"${EXTRACT_DIR}/extract.stdout" 2>"${EXTRACT_DIR}/extract.log" << 'PYEOF'
import sys
import yaml

(
    release_yml_path,
    version_sync_yml_path,
    orchestration_yml_path,
    release_out_path,
    sync_out_path,
    release_chart_out_path,
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

release_chart_script = next(
    s["run"]
    for s in doc["jobs"]["bump-chart"]["steps"]
    if s.get("name") == "Update Chart.yaml"
)
with open(release_chart_out_path, "w") as f:
    f.write(release_chart_script)

with open(version_sync_yml_path) as f:
    sync_doc = yaml.safe_load(f)

sync_steps = sync_doc["jobs"]["sync"]["steps"]
sync_script = next(s["run"] for s in sync_steps if s.get("name") == "Update Dockerfiles")
with open(sync_out_path, "w") as f:
    f.write(sync_script)

version_sync_chart_script = next(
    s["run"] for s in sync_steps if s.get("name") == "Update Helm chart"
)
with open(version_sync_chart_out_path, "w") as f:
    f.write(version_sync_chart_script)

with open(orchestration_yml_path) as f:
    orchestration_doc = yaml.safe_load(f)
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

# Exercise the version-sync Dockerfile step against isolated copies. All three
# files must change together, and structural drift must fail before any edit.
SYNC_VERSION="9.8.7"
SYNC_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SYNC_SCRIPT="$(cat "${EXTRACT_DIR}/update_dockerfiles.sh")"
SYNC_SCRIPT="${SYNC_SCRIPT//\$\{\{ steps.version.outputs.version \}\}/${SYNC_VERSION}}"
SYNC_SCRIPT="${SYNC_SCRIPT//\$\{\{ steps.version.outputs.sha256 \}\}/${SYNC_SHA256}}"

SYNC_DIR="${EXTRACT_DIR}/sync-success"
mkdir -p "$SYNC_DIR"
cp "${REPO_ROOT}/Dockerfile" "${REPO_ROOT}/Dockerfile.moonshot" \
  "${REPO_ROOT}/Dockerfile.playground" "$SYNC_DIR/"
if (cd "$SYNC_DIR" && bash -c "$SYNC_SCRIPT"); then
  for dockerfile in Dockerfile Dockerfile.moonshot Dockerfile.playground; do
    assert_contains "$(cat "${SYNC_DIR}/${dockerfile}")" "ARG FERRITE_VERSION=${SYNC_VERSION}" \
      "version-sync functional replay updates ${dockerfile}'s version"
    assert_contains "$(cat "${SYNC_DIR}/${dockerfile}")" "ARG FERRITE_SOURCE_SHA256=${SYNC_SHA256}" \
      "version-sync functional replay updates ${dockerfile}'s checksum"
  done
else
  harness_fail "version-sync functional replay unexpectedly failed"
fi

DRIFT_DIR="${EXTRACT_DIR}/sync-drift"
mkdir -p "$DRIFT_DIR"
cp "${REPO_ROOT}/Dockerfile" "${REPO_ROOT}/Dockerfile.moonshot" \
  "${REPO_ROOT}/Dockerfile.playground" "$DRIFT_DIR/"
sed '/^ARG FERRITE_SOURCE_SHA256=/d' "${DRIFT_DIR}/Dockerfile.playground" \
  > "${DRIFT_DIR}/Dockerfile.playground.tmp"
mv "${DRIFT_DIR}/Dockerfile.playground.tmp" "${DRIFT_DIR}/Dockerfile.playground"
if (cd "$DRIFT_DIR" && bash -c "$SYNC_SCRIPT"); then
  harness_fail "version-sync unexpectedly accepted a structurally drifted auxiliary Dockerfile"
else
  UNCHANGED_COUNT="$(grep -l '^ARG FERRITE_VERSION=0.4.0$' \
    "${DRIFT_DIR}/Dockerfile" "${DRIFT_DIR}/Dockerfile.moonshot" \
    "${DRIFT_DIR}/Dockerfile.playground" | wc -l | tr -d ' ')"
  assert_eq "3" "$UNCHANGED_COUNT" \
    "version-sync validates every Dockerfile before making any release-default edit"
fi

# Replay every chart release path. The primary package follows the core
# release, while the sidecar package version remains independently versioned.
for chart_path in release_chart version_sync_chart orchestration_chart; do
  CHART_DIR="${EXTRACT_DIR}/${chart_path}"
  mkdir -p "${CHART_DIR}/charts/ferrite" "${CHART_DIR}/charts/ferrite-sidecar"
  cp "${REPO_ROOT}/charts/ferrite/Chart.yaml" "${CHART_DIR}/charts/ferrite/Chart.yaml"
  cp "${REPO_ROOT}/charts/ferrite-sidecar/Chart.yaml" \
    "${CHART_DIR}/charts/ferrite-sidecar/Chart.yaml"

  CHART_SCRIPT="$(cat "${EXTRACT_DIR}/${chart_path}.sh")"
  CHART_SCRIPT="${CHART_SCRIPT//\$\{\{ github.event.client_payload.version \}\}/v9.8.7}"
  CHART_SCRIPT="${CHART_SCRIPT//\$\{\{ steps.version.outputs.version \}\}/9.8.7}"
  CHART_SCRIPT="${CHART_SCRIPT//\$\{\{ needs.prepare.outputs.version \}\}/9.8.7}"

  if (cd "$CHART_DIR" && bash -c "$CHART_SCRIPT"); then
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
  local script
  script="$(cat "${EXTRACT_DIR}/release_meta.sh")"
  script="${script//\$\{\{ github.event_name \}\}/${event_name}}"
  script="${script//\$\{\{ github.event.client_payload.version \}\}/${client_payload_version}}"
  script="${script//\$\{\{ inputs.tag \}\}/${input_tag}}"
  script="${script//\$\{\{ github.repository_owner \}\}/FerriteLabs}"

  local out_file="${EXTRACT_DIR}/output_${name}.txt"
  : > "$out_file"
  (
    export GITHUB_REF_NAME="$ref_name"
    export GITHUB_OUTPUT="$out_file"
    bash -c "$script"
  )
}

if run_case "push_tag" push "" "" "v0.4.0" >"${EXTRACT_DIR}/log_push_tag.txt" 2>&1; then
  OUT="$(cat "${EXTRACT_DIR}/output_push_tag.txt")"
  assert_contains "$OUT" "version=0.4.0" "push-tag case derives version=0.4.0 from GITHUB_REF_NAME"
  assert_contains "$OUT" "major_minor=0.4" "push-tag case derives normalized major.minor tag"
  assert_contains "$OUT" "major=0" "push-tag case derives normalized major tag"
  assert_contains "$OUT" "stable=true" "push-tag stable release enables rolling semver/latest tags"
  assert_contains "$OUT" "FERRITE_VERSION=0.4.0" "push-tag case emits FERRITE_VERSION build-arg"
  assert_contains "$OUT" "FERRITE_SOURCE_SHA256=b4db8cc8eb0d3c2cef4a019a47d550c347df69fb8a4f77550c814fae463005cf" \
    "push-tag case computes the correct real SHA256 for the v0.4.0 tarball"
  assert_tag_set push_tag "0 0.4 0.4.0 latest"
else
  harness_fail "push-tag case unexpectedly failed: $(cat "${EXTRACT_DIR}/log_push_tag.txt")"
fi

if run_case "workflow_dispatch" workflow_dispatch "" "v0.4.0" >"${EXTRACT_DIR}/log_workflow_dispatch.txt" 2>&1; then
  OUT="$(cat "${EXTRACT_DIR}/output_workflow_dispatch.txt")"
  assert_contains "$OUT" "version=0.4.0" \
    "workflow_dispatch derives version=0.4.0 from its version tag input"
  assert_contains "$OUT" "FERRITE_VERSION=0.4.0" \
    "workflow_dispatch emits an explicit FERRITE_VERSION build-arg"
  assert_contains "$OUT" "FERRITE_SOURCE_SHA256=b4db8cc8eb0d3c2cef4a019a47d550c347df69fb8a4f77550c814fae463005cf" \
    "workflow_dispatch computes and emits the matching source checksum"
  assert_tag_set workflow_dispatch "0 0.4 0.4.0 latest"
else
  harness_fail "workflow_dispatch case unexpectedly failed: $(cat "${EXTRACT_DIR}/log_workflow_dispatch.txt")"
fi

if run_case "repository_dispatch" repository_dispatch "v0.4.0" "" \
  >"${EXTRACT_DIR}/log_repository_dispatch.txt" 2>&1; then
  OUT="$(cat "${EXTRACT_DIR}/output_repository_dispatch.txt")"
  assert_contains "$OUT" "version=0.4.0" \
    "repository_dispatch normalizes v0.4.0 to the exact 0.4.0 tag"
  assert_contains "$OUT" "major_minor=0.4" \
    "repository_dispatch emits the 0.4 rolling tag"
  assert_contains "$OUT" "major=0" \
    "repository_dispatch emits the 0 rolling tag"
  assert_contains "$OUT" "stable=true" \
    "repository_dispatch stable release enables latest"
  assert_tag_set repository_dispatch "0 0.4 0.4.0 latest"
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

harness_summary
