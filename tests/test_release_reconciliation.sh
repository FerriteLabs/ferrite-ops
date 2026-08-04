#!/usr/bin/env bash
# Static, pure-helper, and functional coverage for complete floating-tag
# reconciliation from signed immutable exact GHCR tags.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

RELEASE_YML="${REPO_ROOT}/.github/workflows/release.yml"
RECONCILE_YML="${REPO_ROOT}/.github/workflows/reconcile-release-tags.yml"
HELPER="${REPO_ROOT}/scripts/reconcile-release-tags.py"
ORDER="${REPO_ROOT}/scripts/release-ordering.sh"
FIXTURE="${HERE}/fixtures/release-reconciliation/ghcr-pages.json"
RELEASE_CONTENT="$(cat "$RELEASE_YML")"
RECONCILE_CONTENT="$(cat "$RECONCILE_YML")"

# --- Workflow architecture --------------------------------------------------
assert_not_contains "$RELEASE_CONTENT" "promote-stable:" \
  "release.yml no longer performs event-specific floating promotion"
assert_contains "$RELEASE_CONTENT" "reconcile-release-tags.yml runs after this workflow succeeds" \
  "release.yml documents complete-state reconciliation after exact publication"
assert_contains "$RECONCILE_CONTENT" "workflows: [Release]" \
  "successful Release workflow completion triggers reconciliation"
assert_contains "$RECONCILE_CONTENT" 'ref: ${{ github.event.repository.default_branch }}' \
  "registry-writing reconciliation always checks out reviewed default-branch code"
assert_contains "$RECONCILE_CONTENT" "github.event.workflow_run.conclusion == 'success'" \
  "failed exact release workflows cannot trigger reconciliation"
assert_contains "$RECONCILE_CONTENT" "workflow_dispatch:" \
  "operators can manually repair floating tags"
assert_contains "$RECONCILE_CONTENT" "schedule:" \
  "a conservative scheduled repair trigger is configured"
assert_contains "$RECONCILE_CONTENT" "group: ferrite-release-tag-reconciliation" \
  "one fixed concurrency group serializes all reconciliation runs"
assert_contains "$RECONCILE_CONTENT" "cancel-in-progress: false" \
  "an in-progress complete-state reconciliation is never cancelled"
assert_contains "$RECONCILE_CONTENT" "gh api --paginate --slurp" \
  "GHCR package enumeration follows every pagination link"
assert_contains "$RECONCILE_CONTENT" "per_page=100" \
  "GHCR enumeration requests the maximum page size"
assert_contains "$RECONCILE_CONTENT" "cosign verify" \
  "every exact source digest is signature-verified"
assert_contains "$RECONCILE_CONTENT" "org.opencontainers.image.version" \
  "exact source version metadata is verified"
assert_contains "$RECONCILE_CONTENT" "dev.ferritelabs.image.source-sha256" \
  "exact source checksum metadata is verified"
assert_contains "$RECONCILE_CONTENT" "unique | length" \
  "multi-platform exact sources require one consistent source checksum"
assert_contains "$RECONCILE_CONTENT" "SOURCE_DIGEST" \
  "exact sources are re-read before applying the plan"
assert_eq "3" "$(grep -c 'cosign verify \\' "$RECONCILE_YML")" \
  "sources are signature-verified during planning and immediately before each registry apply phase"
assert_contains "$RECONCILE_CONTENT" "DESTINATION_DIGEST" \
  "both registry destinations are digest-verified after mutation"
assert_contains "$RECONCILE_CONTENT" "crane copy" \
  "eligible Docker Hub reconciliation performs a real cross-registry copy"
assert_contains "$RECONCILE_CONTENT" "steps.dockerhub.outputs.enabled == 'true'" \
  "Docker Hub login, tooling, and writes share the eligibility gate"
assert_not_contains "$RECONCILE_CONTENT" "github.event.client_payload.version" \
  "reconciliation never derives desired state from a release event payload"

if [[ ! -x "$HELPER" ]]; then
  harness_fail "pure reconciliation helper is not executable"
else
  harness_ok "pure reconciliation helper is executable"
fi

if ! command -v python3 >/dev/null 2>&1 ||
  ! python3 -c "import yaml" >/dev/null 2>&1 ||
  ! command -v jq >/dev/null 2>&1; then
  echo "  skip: python3/PyYAML/jq unavailable; skipping reconciliation functional replay."
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Pure helper: discovery and complete desired state ---------------------
DISCOVERED="${TMP}/discovered.json"
if python3 "$HELPER" --ordering-script "$ORDER" discover --input "$FIXTURE" >"$DISCOVERED"; then
  harness_ok "helper discovers exact tags from paginated GHCR fixtures"
else
  harness_fail "helper could not discover exact tags from paginated GHCR fixtures"
fi

assert_eq "6" "$(jq 'length' "$DISCOVERED")" \
  "only six exact stable SemVer tags are accepted as sources"
assert_eq "0" "$(jq '[.[] | select(.version | contains("-"))] | length' "$DISCOVERED")" \
  "prereleases are rejected as reconciliation sources"
assert_eq "0" "$(jq '[.[] | select(.version == "latest" or .version == "2" or .version == "2.0")] | length' "$DISCOVERED")" \
  "floating tags are rejected as reconciliation sources"
assert_eq "0" "$(jq '[.[] | select(.version == "candidate-400-1" or .version == "v2.0.3" or .version == "01.2.3")] | length' "$DISCOVERED")" \
  "candidate, v-prefixed, and invalid non-exact tags are rejected as sources"

PLAN="${TMP}/plan.json"
if python3 "$HELPER" --ordering-script "$ORDER" plan --input "$DISCOVERED" >"$PLAN"; then
  harness_ok "helper computes one complete floating-tag plan"
else
  harness_fail "helper could not compute the floating-tag plan"
fi

plan_version() {
  local tag="$1"
  jq -r --arg tag "$tag" '.[] | select(.tag == $tag) | .version' "$PLAN"
}

assert_eq "2.0.2" "$(plan_version latest)" \
  "three rapid 2.0.0/2.0.1/2.0.2 releases converge latest on 2.0.2"
assert_eq "2.0.2" "$(plan_version 2)" \
  "major 2 converges on the newest rapid release"
assert_eq "2.0.2" "$(plan_version 2.0)" \
  "major.minor 2.0 converges on the newest rapid release"
assert_eq "1.9.2" "$(plan_version 1)" \
  "a late 1.9.2 backport independently advances major 1"
assert_eq "1.9.2" "$(plan_version 1.9)" \
  "a late 1.9.2 backport independently advances series 1.9"
assert_eq "1.8.4" "$(plan_version 1.8)" \
  "a missing older series is included in complete desired state"
assert_eq "6" "$(jq 'length' "$PLAN")" \
  "the plan includes latest and every discovered major/major.minor series"

IDENTITY="$(python3 "$HELPER" --ordering-script "$ORDER" identity \
  --repository ferritelabs/ferrite-ops \
  --version 2.0.2 \
  --default-branch release-main)"
assert_eq \
  '^https://github\.com/ferritelabs/ferrite\-ops/\.github/workflows/release\.yml@refs/(tags/v2\.0\.2|heads/main|heads/release\-main)$' \
  "$IDENTITY" \
  "helper derives the exact release workflow identity from validated inputs"

cat >"${TMP}/conflict.json" <<'JSON'
[
  [
    {
      "name": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "metadata": {"container": {"tags": ["1.2.3"]}}
    }
  ],
  [
    {
      "name": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "metadata": {"container": {"tags": ["1.2.3"]}}
    }
  ]
]
JSON
if python3 "$HELPER" --ordering-script "$ORDER" discover \
  --input "${TMP}/conflict.json" >/dev/null 2>&1; then
  harness_fail "helper accepted one exact tag on conflicting digests"
else
  harness_ok "helper fails closed when one exact tag appears on conflicting digests"
fi

cat >"${TMP}/prerelease-plan.json" <<'JSON'
[
  {
    "version": "3.0.0-rc.1",
    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
]
JSON
if python3 "$HELPER" --ordering-script "$ORDER" plan \
  --input "${TMP}/prerelease-plan.json" >/dev/null 2>&1; then
  harness_fail "plan accepted a prerelease as an already-verified source"
else
  harness_ok "plan defensively rejects prereleases even after discovery"
fi

# --- Extract the real verification/apply workflow scripts -----------------
VERIFY_SCRIPT="${TMP}/verify.sh"
GHCR_APPLY_SCRIPT="${TMP}/apply-ghcr.sh"
DOCKERHUB_APPLY_SCRIPT="${TMP}/apply-dockerhub.sh"
if python3 - "$RECONCILE_YML" "$VERIFY_SCRIPT" "$GHCR_APPLY_SCRIPT" "$DOCKERHUB_APPLY_SCRIPT" <<'PYEOF'
import sys
import yaml

workflow_path, verify_path, ghcr_path, dockerhub_path = sys.argv[1:]
with open(workflow_path) as workflow_file:
    workflow = yaml.safe_load(workflow_file)
steps = workflow["jobs"]["reconcile"]["steps"]
names = {
    "Verify every exact stable GHCR source": verify_path,
    "Apply and verify GHCR floating tags": ghcr_path,
    "Copy and verify Docker Hub floating tags": dockerhub_path,
}
for name, output_path in names.items():
    script = next(step["run"] for step in steps if step.get("name") == name)
    with open(output_path, "w") as output_file:
        output_file.write(script)
PYEOF
then
  harness_ok "extracted the real verify and registry-apply workflow steps"
else
  harness_fail "could not extract reconciliation workflow steps"
  harness_summary
  exit $?
fi

# --- Stateful fake registries ----------------------------------------------
REGISTRY_STATE="${TMP}/registry-state.txt"
SIGNED_DIGESTS="${TMP}/signed-digests.txt"
COPY_LOG="${TMP}/copy.log"
FAKE_BIN="${TMP}/bin"
mkdir -p "$FAKE_BIN"
: >"$REGISTRY_STATE"
: >"$SIGNED_DIGESTS"
: >"$COPY_LOG"

cat >"${FAKE_BIN}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] && [ "${3:-}" = "inspect" ]; then
  REF="$4"
  LINE="$(awk -v ref="$REF" '$1 == ref {print}' "$REGISTRY_STATE" | tail -1)"
  if [ -z "$LINE" ]; then
    echo "manifest unknown: not found" >&2
    exit 1
  fi
  DIGEST="$(printf '%s\n' "$LINE" | awk '{print $2}')"
  VERSION="$(printf '%s\n' "$LINE" | awk '{print $3}')"
  SOURCE_SHA="$(printf '%s\n' "$LINE" | awk '{print $4}')"
  if [ "${6:-}" = '{{json .Manifest}}' ]; then
    printf '{"digest":"%s"}\n' "$DIGEST"
  else
    printf '{"config":{"Labels":{"org.opencontainers.image.version":"%s","dev.ferritelabs.image.source-sha256":"%s"}}}\n' \
      "$VERSION" "$SOURCE_SHA"
  fi
  exit 0
fi

if [ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] && [ "${3:-}" = "create" ]; then
  shift 3
  DEST=""
  SOURCE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag) DEST="$2"; shift 2 ;;
      *) SOURCE="$1"; shift ;;
    esac
  done
  DIGEST="${SOURCE##*@}"
  if [ "${DOCKER_CORRUPT_TAG:-}" = "${DEST##*:}" ]; then
    DIGEST="sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  fi
  awk -v ref="$DEST" '$1 != ref' "$REGISTRY_STATE" >"${REGISTRY_STATE}.tmp" || true
  mv "${REGISTRY_STATE}.tmp" "$REGISTRY_STATE"
  printf '%s %s reconciled reconciled\n' "$DEST" "$DIGEST" >>"$REGISTRY_STATE"
  exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
SH
chmod +x "${FAKE_BIN}/docker"

cat >"${FAKE_BIN}/cosign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "verify" ]; then
  REF="${*: -1}"
  DIGEST="${REF##*@}"
  grep -qxF "$DIGEST" "$SIGNED_DIGESTS"
  exit
fi
echo "unexpected cosign invocation: $*" >&2
exit 1
SH
chmod +x "${FAKE_BIN}/cosign"

cat >"${FAKE_BIN}/crane" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  copy)
    SOURCE="$2"
    DEST="$3"
    DIGEST="${SOURCE##*@}"
    if [ "${CRANE_CORRUPT_TAG:-}" = "${DEST##*:}" ]; then
      DIGEST="sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    fi
    awk -v ref="$DEST" '$1 != ref' "$REGISTRY_STATE" >"${REGISTRY_STATE}.tmp" || true
    mv "${REGISTRY_STATE}.tmp" "$REGISTRY_STATE"
    printf '%s %s copied copied\n' "$DEST" "$DIGEST" >>"$REGISTRY_STATE"
    printf '%s -> %s\n' "$SOURCE" "$DEST" >>"$COPY_LOG"
    ;;
  digest)
    awk -v ref="$2" '$1 == ref {print $2}' "$REGISTRY_STATE" | tail -1
    ;;
  *)
    echo "unexpected crane invocation: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "${FAKE_BIN}/crane"

GHCR_IMAGE="ghcr.io/ferritelabs/ferrite"
DOCKERHUB_IMAGE="ferritelabs/ferrite"
SOURCE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

state_set() {
  local ref="$1" digest="$2" version="${3:-state}" source_sha="${4:-state}"
  awk -v ref="$ref" '$1 != ref' "$REGISTRY_STATE" >"${REGISTRY_STATE}.tmp" || true
  mv "${REGISTRY_STATE}.tmp" "$REGISTRY_STATE"
  printf '%s %s %s %s\n' "$ref" "$digest" "$version" "$source_sha" >>"$REGISTRY_STATE"
}

state_digest() {
  awk -v ref="$1" '$1 == ref {print $2}' "$REGISTRY_STATE" | tail -1
}

# Seed all exact tags only after all rapid releases/backports have "happened".
# No intermediate reconciliation event is replayed: this models coalesced or
# dropped events and proves one final run derives and repairs complete state.
while IFS=$'\t' read -r VERSION DIGEST; do
  state_set "${GHCR_IMAGE}:${VERSION}" "$DIGEST" "$VERSION" "$SOURCE_SHA"
  printf '%s\n' "$DIGEST" >>"$SIGNED_DIGESTS"
done < <(jq -r '.[] | [.version, .digest] | @tsv' "$DISCOVERED")

cp "$DISCOVERED" "${TMP}/exact-tag-candidates.json"
if (
  cd "$TMP" || exit 1
  export PATH="${FAKE_BIN}:${PATH}"
  export REGISTRY_STATE SIGNED_DIGESTS
  export GHCR_IMAGE REPOSITORY="ferritelabs/ferrite-ops" DEFAULT_BRANCH="main"
  export HELPER ORDER_SCRIPT="$ORDER"
  bash "$VERIFY_SCRIPT"
) >"${TMP}/verify.log" 2>&1; then
  harness_ok "all discovered exact sources pass digest, metadata, and signature verification"
else
  harness_fail "verified exact sources were rejected: $(cat "${TMP}/verify.log")"
fi
assert_eq "6" "$(jq 'length' "${TMP}/verified-exact-tags.json")" \
  "verification preserves every trusted exact stable source"

# One unsigned exact source makes the complete snapshot untrustworthy and
# fails closed before any floating tag can be changed.
grep -vxF "sha256:7777777777777777777777777777777777777777777777777777777777777777" \
  "$SIGNED_DIGESTS" >"${SIGNED_DIGESTS}.tmp"
mv "${SIGNED_DIGESTS}.tmp" "$SIGNED_DIGESTS"
if (
  cd "$TMP" || exit 1
  export PATH="${FAKE_BIN}:${PATH}"
  export REGISTRY_STATE SIGNED_DIGESTS
  export GHCR_IMAGE REPOSITORY="ferritelabs/ferrite-ops" DEFAULT_BRANCH="main"
  export HELPER ORDER_SCRIPT="$ORDER"
  bash "$VERIFY_SCRIPT"
) >"${TMP}/unsigned.log" 2>&1; then
  harness_fail "verification accepted an unsigned exact stable source"
else
  harness_ok "verification fails closed on an unsigned exact stable source"
fi
printf '%s\n' "sha256:7777777777777777777777777777777777777777777777777777777777777777" \
  >>"$SIGNED_DIGESTS"

# Exact-looking tags with inconsistent immutable metadata or API/registry
# digest disagreement fail the entire snapshot before any floating write.
state_set "${GHCR_IMAGE}:2.0.1" \
  "sha256:6666666666666666666666666666666666666666666666666666666666666666" \
  "2.0.0" "$SOURCE_SHA"
if (
  cd "$TMP" || exit 1
  export PATH="${FAKE_BIN}:${PATH}"
  export REGISTRY_STATE SIGNED_DIGESTS
  export GHCR_IMAGE REPOSITORY="ferritelabs/ferrite-ops" DEFAULT_BRANCH="main"
  export HELPER ORDER_SCRIPT="$ORDER"
  bash "$VERIFY_SCRIPT"
) >"${TMP}/metadata-mismatch.log" 2>&1; then
  harness_fail "verification accepted an exact tag with mismatched version metadata"
else
  harness_ok "verification fails closed on mismatched exact-tag metadata"
fi
state_set "${GHCR_IMAGE}:2.0.1" \
  "sha256:6666666666666666666666666666666666666666666666666666666666666666" \
  "2.0.1" "$SOURCE_SHA"

state_set "${GHCR_IMAGE}:1.9.0" \
  "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "1.9.0" "$SOURCE_SHA"
if (
  cd "$TMP" || exit 1
  export PATH="${FAKE_BIN}:${PATH}"
  export REGISTRY_STATE SIGNED_DIGESTS
  export GHCR_IMAGE REPOSITORY="ferritelabs/ferrite-ops" DEFAULT_BRANCH="main"
  export HELPER ORDER_SCRIPT="$ORDER"
  bash "$VERIFY_SCRIPT"
) >"${TMP}/digest-mismatch.log" 2>&1; then
  harness_fail "verification accepted GHCR API and registry digest disagreement"
else
  harness_ok "verification fails closed on GHCR API and registry digest disagreement"
fi
state_set "${GHCR_IMAGE}:1.9.0" \
  "sha256:1111111111111111111111111111111111111111111111111111111111111111" \
  "1.9.0" "$SOURCE_SHA"

# Stale and missing GHCR floating tags before the single final repair.
state_set "${GHCR_IMAGE}:latest" \
  "sha256:1111111111111111111111111111111111111111111111111111111111111111"
state_set "${GHCR_IMAGE}:1" \
  "sha256:8888888888888888888888888888888888888888888888888888888888888888"
state_set "${GHCR_IMAGE}:1.9" \
  "sha256:1111111111111111111111111111111111111111111111111111111111111111"
state_set "${GHCR_IMAGE}:2.0" \
  "sha256:2222222222222222222222222222222222222222222222222222222222222222"
# 1.8 and 2 are deliberately missing.

cp "$PLAN" "${TMP}/floating-tag-plan.json"

# A signature removed after planning but before mutation is detected by the
# apply phase itself, closing the signature-artifact TOCTOU window.
grep -vxF "sha256:7777777777777777777777777777777777777777777777777777777777777777" \
  "$SIGNED_DIGESTS" >"${SIGNED_DIGESTS}.tmp"
mv "${SIGNED_DIGESTS}.tmp" "$SIGNED_DIGESTS"
if (
  cd "$TMP" || exit 1
  export PATH="${FAKE_BIN}:${PATH}"
  export REGISTRY_STATE SIGNED_DIGESTS GHCR_IMAGE
  export REPOSITORY="ferritelabs/ferrite-ops" DEFAULT_BRANCH="main"
  export HELPER ORDER_SCRIPT="$ORDER"
  bash "$GHCR_APPLY_SCRIPT"
) >"${TMP}/apply-unsigned.log" 2>&1; then
  harness_fail "GHCR apply accepted a source whose signature disappeared after planning"
else
  harness_ok "GHCR apply re-verifies signatures immediately before mutation"
fi
printf '%s\n' "sha256:7777777777777777777777777777777777777777777777777777777777777777" \
  >>"$SIGNED_DIGESTS"

if (
  cd "$TMP" || exit 1
  export PATH="${FAKE_BIN}:${PATH}"
  export REGISTRY_STATE SIGNED_DIGESTS GHCR_IMAGE
  export REPOSITORY="ferritelabs/ferrite-ops" DEFAULT_BRANCH="main"
  export HELPER ORDER_SCRIPT="$ORDER"
  bash "$GHCR_APPLY_SCRIPT"
) >"${TMP}/apply-ghcr.log" 2>&1; then
  harness_ok "one final GHCR reconciliation repairs stale and missing floating tags"
else
  harness_fail "GHCR reconciliation failed: $(cat "${TMP}/apply-ghcr.log")"
fi

while IFS=$'\t' read -r TAG _VERSION DIGEST; do
  assert_eq "$DIGEST" "$(state_digest "${GHCR_IMAGE}:${TAG}")" \
    "GHCR ${TAG} matches the complete exact-tag maximum after one run"
done < <(jq -r '.[] | [.tag, .version, .digest] | @tsv' "$PLAN")

# Docker Hub begins independently stale/missing and is repaired only from
# selected verified GHCR digests via real cross-registry copies.
state_set "${DOCKERHUB_IMAGE}:latest" \
  "sha256:1111111111111111111111111111111111111111111111111111111111111111"
: >"$COPY_LOG"

grep -vxF "sha256:7777777777777777777777777777777777777777777777777777777777777777" \
  "$SIGNED_DIGESTS" >"${SIGNED_DIGESTS}.tmp"
mv "${SIGNED_DIGESTS}.tmp" "$SIGNED_DIGESTS"
if (
  cd "$TMP" || exit 1
  export PATH="${FAKE_BIN}:${PATH}"
  export REGISTRY_STATE SIGNED_DIGESTS COPY_LOG GHCR_IMAGE DOCKERHUB_IMAGE
  export REPOSITORY="ferritelabs/ferrite-ops" DEFAULT_BRANCH="main"
  export HELPER ORDER_SCRIPT="$ORDER"
  bash "$DOCKERHUB_APPLY_SCRIPT"
) >"${TMP}/dockerhub-unsigned.log" 2>&1; then
  harness_fail "Docker Hub apply accepted a source whose signature disappeared after GHCR apply"
else
  harness_ok "Docker Hub apply re-verifies signatures immediately before cross-registry copy"
fi
printf '%s\n' "sha256:7777777777777777777777777777777777777777777777777777777777777777" \
  >>"$SIGNED_DIGESTS"

if (
  cd "$TMP" || exit 1
  export PATH="${FAKE_BIN}:${PATH}"
  export REGISTRY_STATE SIGNED_DIGESTS COPY_LOG GHCR_IMAGE DOCKERHUB_IMAGE
  export REPOSITORY="ferritelabs/ferrite-ops" DEFAULT_BRANCH="main"
  export HELPER ORDER_SCRIPT="$ORDER"
  bash "$DOCKERHUB_APPLY_SCRIPT"
) >"${TMP}/apply-dockerhub.log" 2>&1; then
  harness_ok "eligible Docker Hub reconciliation copies the complete GHCR plan"
else
  harness_fail "Docker Hub reconciliation failed: $(cat "${TMP}/apply-dockerhub.log")"
fi
assert_eq "6" "$(wc -l <"$COPY_LOG" | tr -d ' ')" \
  "Docker Hub receives one verified cross-registry copy per desired floating tag"
while IFS=$'\t' read -r TAG _VERSION DIGEST; do
  assert_eq "$DIGEST" "$(state_digest "${DOCKERHUB_IMAGE}:${TAG}")" \
    "Docker Hub ${TAG} digest is verified against its GHCR source"
done < <(jq -r '.[] | [.tag, .version, .digest] | @tsv' "$PLAN")

if (
  cd "$TMP" || exit 1
  export PATH="${FAKE_BIN}:${PATH}"
  export REGISTRY_STATE SIGNED_DIGESTS COPY_LOG GHCR_IMAGE DOCKERHUB_IMAGE
  export REPOSITORY="ferritelabs/ferrite-ops" DEFAULT_BRANCH="main"
  export HELPER ORDER_SCRIPT="$ORDER"
  export CRANE_CORRUPT_TAG="latest"
  bash "$DOCKERHUB_APPLY_SCRIPT"
) >"${TMP}/corrupt-dockerhub.log" 2>&1; then
  harness_fail "Docker Hub reconciliation accepted a mismatched destination digest"
else
  harness_ok "Docker Hub reconciliation rejects a mismatched destination digest"
fi

if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$RELEASE_YML" "$RECONCILE_YML"; then
    harness_ok "actionlint accepts release and reconciliation workflows"
  else
    harness_fail "actionlint rejected release or reconciliation workflow"
  fi
fi

harness_summary
