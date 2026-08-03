#!/usr/bin/env bash
# Static and functional coverage for release.yml's exact-image-immutability
# pipeline: per-version workflow concurrency, a unique throwaway candidate
# ref that is scanned/signed/attested BEFORE anything is promoted, a
# pre-build check of any existing exact GHCR tag (idempotent match vs. a
# hard-fail on mismatch/unsigned), and a final promotion step that never
# overwrites an existing exact tag pointing at a different digest on either
# registry. The functional replay uses fake `docker`/`cosign` binaries and
# the real scripts/release-ordering.sh; no registry, Docker daemon, or
# network is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

RELEASE_YML="${REPO_ROOT}/.github/workflows/release.yml"
DOCKERFILE="${REPO_ROOT}/Dockerfile"
CONTENT="$(cat "$RELEASE_YML")"
DOCKERFILE_CONTENT="$(cat "$DOCKERFILE")"

# --- Static checks -----------------------------------------------------------
assert_contains "$CONTENT" "concurrency:" \
  "release.yml defines workflow-level concurrency"
assert_contains "$CONTENT" "group: ferrite-release-\${{ github.event_name == 'push'" \
  "release.yml's concurrency group is keyed on the release version from the raw triggering event"
assert_contains "$CONTENT" "cancel-in-progress: false" \
  "release.yml never cancels an in-flight release run for the same version"
assert_contains "$CONTENT" 'candidate_tag: ${{ steps.release_meta.outputs.candidate_tag }}' \
  "build-and-push exposes the unique candidate tag as a job output"
assert_contains "$CONTENT" 'CANDIDATE_TAG="candidate-${RUN_ID}-${RUN_ATTEMPT}"' \
  "the candidate tag is unique per run id AND retry attempt"
assert_contains "$CONTENT" "id: check_existing" \
  "build-and-push checks for an existing exact GHCR tag before building anything"
assert_contains "$CONTENT" 'if: steps.check_existing.outputs.idempotent != '"'"'true'"'"'' \
  "the build/scan/sign/attest steps are skipped entirely when idempotent"
assert_contains "$CONTENT" "Scan candidate image with Trivy" \
  "the candidate is scanned with Trivy before signing/attesting"
assert_contains "$CONTENT" "promote-exact:" \
  "release.yml defines a dedicated exact-tag promotion job"
assert_contains "$CONTENT" "needs: [build-and-push, verify, smoke-test]" \
  "the exact tag is promoted only after build, verify, AND smoke-test all succeed"
assert_contains "$CONTENT" "Refusing to overwrite an existing exact version tag" \
  "promote-exact refuses to overwrite an existing exact tag pointing at a different digest"
assert_contains "$CONTENT" "already points at \${DIGEST}; nothing to promote (idempotent)" \
  "promote-exact treats a matching existing exact tag as an idempotent no-op"
assert_contains "$CONTENT" "dev.ferritelabs.image.source-sha256" \
  "release.yml verifies the baked source-checksum label of an existing exact tag"
assert_contains "$CONTENT" "cosign verify" \
  "release.yml verifies the signature of an existing exact tag before treating it as safe"
assert_not_contains "$CONTENT" 'type=raw,value=${{ steps.release_meta.outputs.version }}' \
  "the exact version tag is never baked directly into the candidate build"

assert_contains "$DOCKERFILE_CONTENT" 'LABEL dev.ferritelabs.image.source-sha256="${FERRITE_SOURCE_SHA256}"' \
  "the Dockerfile bakes the source-checksum label release.yml verifies"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  skip: python3/PyYAML unavailable; skipping exact-image-immutability functional replay."
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CHECK_SCRIPT="${TMP}/check_existing.sh"
PROMOTE_SCRIPT="${TMP}/promote_exact.sh"

if ! python3 - "$RELEASE_YML" "$CHECK_SCRIPT" <<'PYEOF'
import sys, yaml
release_path, out_path = sys.argv[1:]
with open(release_path) as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["build-and-push"]["steps"]
run = next(s["run"] for s in steps if s.get("name") == "Check existing exact GHCR tag")
with open(out_path, "w") as f:
    f.write(run)
PYEOF
then
  harness_fail "could not extract the check_existing step from release.yml"
  harness_summary
  exit $?
fi
harness_ok "extracted the 'Check existing exact GHCR tag' step from release.yml"

if ! python3 - "$RELEASE_YML" "$PROMOTE_SCRIPT" <<'PYEOF'
import sys, yaml
release_path, out_path = sys.argv[1:]
with open(release_path) as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["promote-exact"]["steps"]
run = next(s["run"] for s in steps if s.get("name") == "Promote the verified digest to the exact immutable version tag")
with open(out_path, "w") as f:
    f.write(run)
PYEOF
then
  harness_fail "could not extract the promote-exact step from release.yml"
  harness_summary
  exit $?
fi
harness_ok "extracted the exact-tag promotion step from release.yml"

# --- Fake docker + cosign, backed by a stateful fake registry ---------------
# REGISTRY_MANIFEST: one "<full-ref> <digest> <version-label> <sha256-label>"
# line per existing tag. SIGNED_DIGESTS: one digest per line that `cosign
# verify` will accept; any digest not listed fails verification (unsigned).
REGISTRY_MANIFEST="${TMP}/registry_manifest.txt"
SIGNED_DIGESTS="${TMP}/signed_digests.txt"
DOCKER_LOG="${TMP}/docker.log"
: > "$REGISTRY_MANIFEST"
: > "$SIGNED_DIGESTS"
: > "$DOCKER_LOG"

FAKE_BIN="${TMP}/bin"
mkdir -p "$FAKE_BIN"

python3 - "$FAKE_BIN/docker" <<'PYEOF'
import sys, os, stat
path = sys.argv[1]
script = r"""#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] && [ "${3:-}" = "inspect" ]; then
  REF="$4"
  LINE="$(awk -v r="$REF" '$1==r{print}' "$REGISTRY_MANIFEST" | tail -1)"
  if [ -z "$LINE" ]; then
    echo "manifest unknown: not found" >&2
    exit 1
  fi
  DIGEST="$(printf '%s' "$LINE" | awk '{print $2}')"
  VERSION_LABEL="$(printf '%s' "$LINE" | awk '{print $3}')"
  SHA_LABEL="$(printf '%s' "$LINE" | awk '{print $4}')"
  FORMAT="${6:-}"
  if [ "$FORMAT" = '{{json .Manifest}}' ]; then
    printf '{"digest":"%s"}\n' "$DIGEST"
  else
    printf '{"config":{"Labels":{"org.opencontainers.image.version":"%s","dev.ferritelabs.image.source-sha256":"%s"}}}\n' \
      "$VERSION_LABEL" "$SHA_LABEL"
  fi
  exit 0
fi

if [ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] && [ "${3:-}" = "create" ]; then
  shift 3
  TAGS=()
  SOURCE_REF=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag) TAGS+=("$2"); shift 2 ;;
      *) SOURCE_REF="$1"; shift ;;
    esac
  done
  DIGEST="${SOURCE_REF##*@}"
  for full_tag in "${TAGS[@]}"; do
    awk -v r="$full_tag" '$1!=r' "$REGISTRY_MANIFEST" > "${REGISTRY_MANIFEST}.tmp" 2>/dev/null || true
    mv "${REGISTRY_MANIFEST}.tmp" "$REGISTRY_MANIFEST"
    printf '%s %s created created\n' "$full_tag" "$DIGEST" >> "$REGISTRY_MANIFEST"
  done
  printf '%s\n' "$*" >> "$DOCKER_LOG"
  exit 0
fi

echo "unexpected docker invocation: $*" >&2
exit 1
"""
with open(path, "w") as f:
    f.write(script)
os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
PYEOF

python3 - "$FAKE_BIN/cosign" <<'PYEOF'
import sys, os, stat
path = sys.argv[1]
script = r"""#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "verify" ]; then
  # Last argument is the "<image>@<digest>" reference.
  REF="${*: -1}"
  DIGEST="${REF##*@}"
  if grep -qxF "$DIGEST" "$SIGNED_DIGESTS" 2>/dev/null; then
    exit 0
  fi
  echo "Error: no matching signatures for ${REF}" >&2
  exit 1
fi
echo "unexpected cosign invocation: $*" >&2
exit 1
"""
with open(path, "w") as f:
    f.write(script)
os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
PYEOF

GHCR_IMAGE="ghcr.io/ferritelabs/ferrite"
DOCKERHUB_IMAGE="ferritelabs/ferrite"

manifest_set() {
  local full_ref="$1" digest="$2" version="$3" sha="$4"
  awk -v r="$full_ref" '$1!=r' "$REGISTRY_MANIFEST" > "${REGISTRY_MANIFEST}.tmp" 2>/dev/null || true
  mv "${REGISTRY_MANIFEST}.tmp" "$REGISTRY_MANIFEST"
  printf '%s %s %s %s\n' "$full_ref" "$digest" "$version" "$sha" >> "$REGISTRY_MANIFEST"
}

manifest_digest_of() {
  local full_ref="$1"
  awk -v r="$full_ref" '$1==r{print $2}' "$REGISTRY_MANIFEST" | tail -1
}

sign_digest() {
  printf '%s\n' "$1" >> "$SIGNED_DIGESTS"
}

run_check_existing() {
  local version="$1" sha256="$2" out="$3"
  : > "$out"
  (
    export PATH="${FAKE_BIN}:${PATH}"
    export REGISTRY_MANIFEST
    export SIGNED_DIGESTS
    export GHCR_IMAGE="$GHCR_IMAGE"
    export VERSION="$version"
    export SHA256="$sha256"
    export CERTIFICATE_IDENTITY_REGEXP='^https://github\.com/ferritelabs/'
    export GITHUB_OUTPUT="$out"
    bash "$CHECK_SCRIPT"
  ) >"${out}.log" 2>&1
}

ZERO="0000000000000000000000000000000000000000000000000000000000000000"
ONES="1111111111111111111111111111111111111111111111111111111111111111"

# --- check_existing: first publish (no existing tag) -----------------------
if run_check_existing "0.5.0" "$ZERO" "${TMP}/first.out"; then
  assert_contains "$(cat "${TMP}/first.out")" "idempotent=false" \
    "check_existing reports idempotent=false when the exact tag does not exist yet"
else
  harness_fail "check_existing unexpectedly failed for a first publish: $(cat "${TMP}/first.out")"
fi

# --- check_existing: existing tag matches exactly and is signed ------------
manifest_set "${GHCR_IMAGE}:0.5.0" "sha256:${ONES}" "0.5.0" "$ZERO"
sign_digest "sha256:${ONES}"
if run_check_existing "0.5.0" "$ZERO" "${TMP}/match.out"; then
  assert_contains "$(cat "${TMP}/match.out")" "idempotent=true" \
    "check_existing reports idempotent=true when the existing tag matches exactly and is signed"
  assert_contains "$(cat "${TMP}/match.out")" "existing_digest=sha256:${ONES}" \
    "check_existing reports the existing digest for an idempotent match"
else
  harness_fail "check_existing unexpectedly failed for a verified matching tag: $(cat "${TMP}/match.out")"
fi

# --- check_existing: existing tag has a DIFFERENT version label (corrupt) --
manifest_set "${GHCR_IMAGE}:0.5.1" "sha256:${ONES}" "0.5.0-WRONG" "$ZERO"
sign_digest "sha256:${ONES}"
if run_check_existing "0.5.1" "$ZERO" "${TMP}/mismatch_version.out"; then
  harness_fail "check_existing unexpectedly accepted a mismatched version label"
else
  assert_contains "$(cat "${TMP}/mismatch_version.out.log")" "does not match this release" \
    "check_existing fails when the existing tag's version label does not match"
fi

# --- check_existing: existing tag has a DIFFERENT source-sha256 label ------
manifest_set "${GHCR_IMAGE}:0.5.2" "sha256:${ONES}" "0.5.2" "$ZERO"
sign_digest "sha256:${ONES}"
if run_check_existing "0.5.2" "$ONES" "${TMP}/mismatch_sha.out"; then
  harness_fail "check_existing unexpectedly accepted a mismatched source-sha256 label"
else
  assert_contains "$(cat "${TMP}/mismatch_sha.out.log")" "does not match this release" \
    "check_existing fails when the existing tag's source-sha256 label does not match"
fi

# --- check_existing: existing tag matches labels but is UNSIGNED -----------
manifest_set "${GHCR_IMAGE}:0.5.3" "sha256:${ZERO}" "0.5.3" "$ONES"
# Deliberately do NOT sign sha256:${ZERO}.
if run_check_existing "0.5.3" "$ONES" "${TMP}/unsigned.out"; then
  harness_fail "check_existing unexpectedly accepted an unsigned existing exact tag"
else
  assert_contains "$(cat "${TMP}/unsigned.out.log")" "could not be verified" \
    "check_existing fails when an existing, metadata-matching exact tag cannot be verified"
fi

# === promote-exact ===========================================================
run_promote_exact() {
  local version="$1" digest="$2" dockerhub_enabled="${3:-false}" out="$4"
  : > "$out"
  : > "$DOCKER_LOG"
  (
    export PATH="${FAKE_BIN}:${PATH}"
    export REGISTRY_MANIFEST
    export DOCKER_LOG
    export VERSION="$version"
    export DIGEST="$digest"
    export GHCR_IMAGE="$GHCR_IMAGE"
    export DOCKERHUB_IMAGE="$DOCKERHUB_IMAGE"
    export DOCKERHUB_ENABLED="$dockerhub_enabled"
    bash "$PROMOTE_SCRIPT"
  ) >"$out" 2>&1
}

: > "$REGISTRY_MANIFEST"

# --- First publish: exact tag does not exist yet; imagetools create runs ---
if run_promote_exact "0.6.0" "sha256:${ONES}" "false" "${TMP}/promote_first.out"; then
  assert_eq "sha256:${ONES}" "$(manifest_digest_of "${GHCR_IMAGE}:0.6.0")" \
    "promote-exact creates the exact tag pointing at the verified digest on first publish"
  assert_contains "$(cat "${TMP}/promote_first.out")" "Promoting ${GHCR_IMAGE}:0.6.0" \
    "promote-exact logs the first-publish promotion"
else
  harness_fail "promote-exact unexpectedly failed on first publish: $(cat "${TMP}/promote_first.out")"
fi

# --- Idempotent retry: exact tag already points at the SAME digest ---------
if run_promote_exact "0.6.0" "sha256:${ONES}" "false" "${TMP}/promote_retry.out"; then
  assert_contains "$(cat "${TMP}/promote_retry.out")" "nothing to promote (idempotent)" \
    "promote-exact treats a retry with a matching existing digest as a no-op"
  assert_eq "0" "$(grep -c -- "buildx imagetools create" "$DOCKER_LOG" 2>/dev/null || true)" \
    "an idempotent retry never calls imagetools create again"
else
  harness_fail "promote-exact unexpectedly failed on an idempotent retry: $(cat "${TMP}/promote_retry.out")"
fi

# --- Concurrent same-version runs: the second sees the first's result -----
# Simulates two runs of this workflow for the SAME version (the scenario the
# per-version concurrency group serializes): whichever runs second always
# observes the exact tag the first one already created, and treats it as an
# idempotent no-op rather than attempting to re-create or replace it.
if run_promote_exact "0.6.0" "sha256:${ONES}" "false" "${TMP}/promote_concurrent.out"; then
  assert_contains "$(cat "${TMP}/promote_concurrent.out")" "nothing to promote (idempotent)" \
    "a second, concurrent-same-version run safely no-ops against the first run's result"
else
  harness_fail "concurrent-same-version replay unexpectedly failed: $(cat "${TMP}/promote_concurrent.out")"
fi

# --- Mismatch: exact tag exists but points at a DIFFERENT digest -----------
if run_promote_exact "0.6.0" "sha256:${ZERO}" "false" "${TMP}/promote_mismatch.out"; then
  harness_fail "promote-exact unexpectedly overwrote an existing exact tag with a different digest"
else
  assert_contains "$(cat "${TMP}/promote_mismatch.out")" "Refusing to overwrite an existing exact version tag" \
    "promote-exact refuses to overwrite an existing exact tag with a different digest"
fi
assert_eq "sha256:${ONES}" "$(manifest_digest_of "${GHCR_IMAGE}:0.6.0")" \
  "a refused mismatch leaves the existing exact tag's digest completely untouched"

# --- Docker Hub: eligible exact tag never overwrites a different digest ---
: > "$REGISTRY_MANIFEST"
manifest_set "${DOCKERHUB_IMAGE}:0.7.0" "sha256:${ZERO}" "" ""
if run_promote_exact "0.7.0" "sha256:${ONES}" "true" "${TMP}/dockerhub_mismatch.out"; then
  harness_fail "promote-exact unexpectedly overwrote a Docker Hub exact tag with a different digest"
else
  assert_contains "$(cat "${TMP}/dockerhub_mismatch.out")" "Refusing to overwrite an existing exact version tag" \
    "promote-exact refuses to overwrite a Docker Hub exact tag with a different digest"
fi
assert_eq "sha256:${ZERO}" "$(manifest_digest_of "${DOCKERHUB_IMAGE}:0.7.0")" \
  "the Docker Hub exact tag's original digest is left completely untouched"

# --- Docker Hub: matching digest is a safe no-op, GHCR still promotes -----
: > "$REGISTRY_MANIFEST"
manifest_set "${DOCKERHUB_IMAGE}:0.7.1" "sha256:${ONES}" "" ""
if run_promote_exact "0.7.1" "sha256:${ONES}" "true" "${TMP}/dockerhub_match.out"; then
  assert_eq "sha256:${ONES}" "$(manifest_digest_of "${GHCR_IMAGE}:0.7.1")" \
    "GHCR is still promoted when Docker Hub already matches"
  assert_eq "sha256:${ONES}" "$(manifest_digest_of "${DOCKERHUB_IMAGE}:0.7.1")" \
    "a matching Docker Hub exact tag remains untouched (idempotent)"
else
  harness_fail "promote-exact unexpectedly failed with a matching Docker Hub tag: $(cat "${TMP}/dockerhub_match.out")"
fi

# --- Invalid inputs are rejected defensively --------------------------------
if run_promote_exact "not-a-version" "sha256:${ONES}" "false" "${TMP}/bad_version.out"; then
  harness_fail "promote-exact unexpectedly accepted an invalid version"
else
  assert_contains "$(cat "${TMP}/bad_version.out")" "Refusing to promote an invalid exact version" \
    "promote-exact rejects an invalid exact version"
fi
if run_promote_exact "0.6.0" "not-a-digest" "false" "${TMP}/bad_digest.out"; then
  harness_fail "promote-exact unexpectedly accepted an invalid digest"
else
  assert_contains "$(cat "${TMP}/bad_digest.out")" "Refusing to promote an invalid digest" \
    "promote-exact rejects an invalid digest"
fi

if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$RELEASE_YML"; then
    harness_ok "actionlint accepts the exact-image-immutability release workflow"
  else
    harness_fail "actionlint rejected the exact-image-immutability release workflow"
  fi
else
  echo "  skip: actionlint not available; static and functional checks completed."
fi

harness_summary
