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

for f in "$RELEASE_YML" "$VERSION_SYNC_YML"; do
  if [[ ! -f "$f" ]]; then
    echo "  FAIL: ${f} not found" >&2
    exit 1
  fi
done

RELEASE_CONTENT="$(cat "$RELEASE_YML")"
VERSION_SYNC_CONTENT="$(cat "$VERSION_SYNC_YML")"

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
assert_contains "$RELEASE_CONTENT" "default: 'v0.3.0'" \
  "release.yml's workflow_dispatch default is a concrete semver release"

# --- Static checks: version-sync.yml ----------------------------------------
assert_contains "$VERSION_SYNC_CONTENT" "ARG FERRITE_SOURCE_SHA256=" \
  "version-sync.yml updates the Dockerfile's FERRITE_SOURCE_SHA256 default"
assert_contains "$VERSION_SYNC_CONTENT" "ARG FERRITE_VERSION=" \
  "version-sync.yml updates the Dockerfile's FERRITE_VERSION default"
assert_contains "$VERSION_SYNC_CONTENT" 'grep -qE' \
  "version-sync.yml validates the version against a semver pattern"
assert_contains "$VERSION_SYNC_CONTENT" "shasum -a 256" \
  "version-sync.yml computes the source checksum when not explicitly provided"

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

python3 - "$RELEASE_YML" "$EXTRACT_DIR/release_meta.sh" << 'PYEOF'
import sys
import yaml

release_yml_path, out_path = sys.argv[1], sys.argv[2]
with open(release_yml_path) as f:
    doc = yaml.safe_load(f)

steps = doc["jobs"]["build-and-push"]["steps"]
script = next(s["run"] for s in steps if s.get("name") == "Determine release version and source checksum")
with open(out_path, "w") as f:
    f.write(script)
PYEOF

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

if run_case "push_tag" push "" "" "v0.3.0" >"${EXTRACT_DIR}/log_push_tag.txt" 2>&1; then
  OUT="$(cat "${EXTRACT_DIR}/output_push_tag.txt")"
  assert_contains "$OUT" "version=0.3.0" "push-tag case derives version=0.3.0 from GITHUB_REF_NAME"
  assert_contains "$OUT" "FERRITE_VERSION=0.3.0" "push-tag case emits FERRITE_VERSION build-arg"
  assert_contains "$OUT" "FERRITE_SOURCE_SHA256=42cc9cd06b85fac0a09d6e1770d3eda61375324211be168dfb6dc7eab5825979" \
    "push-tag case computes the correct real SHA256 for the v0.3.0 tarball"
else
  harness_fail "push-tag case unexpectedly failed: $(cat "${EXTRACT_DIR}/log_push_tag.txt")"
fi

if run_case "workflow_dispatch" workflow_dispatch "" "v0.3.0" >"${EXTRACT_DIR}/log_workflow_dispatch.txt" 2>&1; then
  OUT="$(cat "${EXTRACT_DIR}/output_workflow_dispatch.txt")"
  assert_contains "$OUT" "version=0.3.0" \
    "workflow_dispatch derives version=0.3.0 from its version tag input"
  assert_contains "$OUT" "FERRITE_VERSION=0.3.0" \
    "workflow_dispatch emits an explicit FERRITE_VERSION build-arg"
  assert_contains "$OUT" "FERRITE_SOURCE_SHA256=42cc9cd06b85fac0a09d6e1770d3eda61375324211be168dfb6dc7eab5825979" \
    "workflow_dispatch computes and emits the matching source checksum"
else
  harness_fail "workflow_dispatch case unexpectedly failed: $(cat "${EXTRACT_DIR}/log_workflow_dispatch.txt")"
fi

if run_case "bad_semver" push "" "" "not-a-version" >"${EXTRACT_DIR}/log_bad_semver.txt" 2>&1; then
  harness_fail "push-tag case with an invalid semver unexpectedly succeeded"
else
  assert_contains "$(cat "${EXTRACT_DIR}/log_bad_semver.txt")" "Invalid semver" \
    "an invalid semver version fails release.yml's derivation step with a clear error"
fi

harness_summary
