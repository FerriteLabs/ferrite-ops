#!/usr/bin/env bash
# Static and functional coverage for release.yml's serialized, INDEPENDENT
# per-tag floating-tag promotion. The functional replay extracts the real
# "Resolve current per-tag promoted versions" and "Promote floating tags to
# this digest" steps and exercises them against a small stateful fake
# `docker` (backed by a flat-file fake registry) and the real
# scripts/release-ordering.sh, so no registry, Docker daemon, or network is
# touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

RELEASE_YML="${REPO_ROOT}/.github/workflows/release.yml"
ORDER="${REPO_ROOT}/scripts/release-ordering.sh"
CONTENT="$(cat "$RELEASE_YML")"

# --- Static architecture checks --------------------------------------------
assert_contains "$CONTENT" "promote-stable:" \
  "release.yml defines a dedicated floating-tag promotion job"
assert_contains "$CONTENT" "if: needs.release-transaction.outputs.stable == 'true'" \
  "promotion runs only for stable releases; prereleases stay exact-only"
assert_contains "$CONTENT" "group: ferrite-floating-tag-promotion" \
  "promotion is serialized by a fixed concurrency group"
assert_contains "$CONTENT" "cancel-in-progress: false" \
  "serialized promotions queue instead of cancelling each other"
assert_contains "$CONTENT" "docker buildx imagetools create" \
  "promotion advances floating tags on the signed digest via imagetools"
assert_not_contains "$CONTENT" 'type=raw,value=latest' \
  "the exact-version build never bakes a floating latest tag"
assert_contains "$CONTENT" "Resolve current per-tag promoted versions" \
  "promotion independently resolves each floating tag's own currently promoted version"
assert_not_contains "$CONTENT" "client_payload.*promoted" \
  "promotion never trusts workflow input for the current promoted version"
assert_contains "$CONTENT" "needs: release-transaction" \
  "floating-tag promotion runs only after the locked exact release transaction succeeds"
assert_contains "$CONTENT" "should_promote()" \
  "promotion gates each floating tag independently"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  skip: python3/PyYAML unavailable; skipping promotion functional replay."
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RESOLVE_SCRIPT="${TMP}/resolve.sh"
PROMOTE_SCRIPT="${TMP}/promote.sh"
if ! python3 - "$RELEASE_YML" "$RESOLVE_SCRIPT" <<'PYEOF'
import sys, yaml
release_path, out_path = sys.argv[1:]
with open(release_path) as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["promote-stable"]["steps"]
run = next(s["run"] for s in steps if s.get("name") == "Resolve current per-tag promoted versions")
with open(out_path, "w") as f:
    f.write(run)
PYEOF
then
  harness_fail "could not extract the per-tag resolve step from release.yml"
  harness_summary
  exit $?
fi
harness_ok "extracted the per-tag resolve step from release.yml"

if ! python3 - "$RELEASE_YML" "$PROMOTE_SCRIPT" <<'PYEOF'
import sys, yaml
release_path, out_path = sys.argv[1:]
with open(release_path) as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["promote-stable"]["steps"]
run = next(s["run"] for s in steps if s.get("name") == "Promote floating tags to this digest")
with open(out_path, "w") as f:
    f.write(run)
PYEOF
then
  harness_fail "could not extract the floating-tag promotion step from release.yml"
  harness_summary
  exit $?
fi
harness_ok "extracted the floating-tag promotion step from release.yml"

# --- Stateful fake registry --------------------------------------------------
# REGISTRY_STATE: one "<full-ref-tag> <version>" line per currently-existing
# tag, e.g. "ghcr.io/ferritelabs/ferrite:latest 2.0.0". DIGEST_MAP: one
# "<digest> <version>" line per candidate this test will promote from,
# standing in for "the image at this digest was built with this baked
# org.opencontainers.image.version label".
REGISTRY_STATE="${TMP}/registry_state.txt"
DIGEST_MAP="${TMP}/digest_map.txt"
: > "$REGISTRY_STATE"
: > "$DIGEST_MAP"

digest_for() {
  # Deterministic, version-specific fake digest.
  local version="$1" hex
  hex="$(printf '%s' "$version" | shasum -a 256 | cut -d' ' -f1)"
  printf 'sha256:%s' "$hex"
}

seed_registry_tag() {
  local full_ref="$1" version="$2"
  awk -v r="$full_ref" '$1!=r' "$REGISTRY_STATE" > "${REGISTRY_STATE}.tmp" 2>/dev/null || true
  mv "${REGISTRY_STATE}.tmp" "$REGISTRY_STATE"
  printf '%s %s\n' "$full_ref" "$version" >> "$REGISTRY_STATE"
}

seed_digest() {
  local version="$1" digest
  digest="$(digest_for "$version")"
  awk -v d="$digest" '$1!=d' "$DIGEST_MAP" > "${DIGEST_MAP}.tmp" 2>/dev/null || true
  mv "${DIGEST_MAP}.tmp" "$DIGEST_MAP"
  printf '%s %s\n' "$digest" "$version" >> "$DIGEST_MAP"
}

registry_version_of() {
  local full_ref="$1"
  awk -v r="$full_ref" '$1==r{print $2}' "$REGISTRY_STATE" | tail -1
}

FAKE_BIN="${TMP}/bin"
mkdir -p "$FAKE_BIN"
python3 - "$FAKE_BIN/docker" <<'PYEOF'
import sys, os, stat
path = sys.argv[1]
script = r"""#!/usr/bin/env bash
# Minimal stateful fake `docker buildx imagetools inspect|create`, backed by
# flat-file REGISTRY_STATE ("<image:tag> <version>" lines) and DIGEST_MAP
# ("<digest> <version>" lines). Anything else is a hard failure.
set -euo pipefail

if [ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] && [ "${3:-}" = "inspect" ]; then
  REF="$4"
  VERSION="$(awk -v r="$REF" '$1==r{print $2}' "$REGISTRY_STATE" | tail -1)"
  if [ -z "$VERSION" ]; then
    echo "manifest unknown: not found" >&2
    exit 1
  fi
  FORMAT="${6:-}"
  if [ "$FORMAT" = '{{json .Manifest}}' ]; then
    HEX="$(printf '%s' "$VERSION" | shasum -a 256 | cut -d' ' -f1)"
    printf '{"digest":"sha256:%s"}\n' "$HEX"
  else
    printf '{"config":{"Labels":{"org.opencontainers.image.version":"%s"}}}\n' "$VERSION"
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
  VERSION="$(awk -v d="$DIGEST" '$1==d{print $2}' "$DIGEST_MAP" | tail -1)"
  if [ -z "$VERSION" ]; then
    echo "unknown digest in test fixture: ${DIGEST}" >&2
    exit 1
  fi
  for full_tag in "${TAGS[@]}"; do
    awk -v r="$full_tag" '$1!=r' "$REGISTRY_STATE" > "${REGISTRY_STATE}.tmp" 2>/dev/null || true
    mv "${REGISTRY_STATE}.tmp" "$REGISTRY_STATE"
    printf '%s %s\n' "$full_tag" "$VERSION" >> "$REGISTRY_STATE"
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

GHCR_IMAGE="ghcr.io/ferritelabs/ferrite"
DOCKERHUB_IMAGE="ferritelabs/ferrite"

# Runs resolve+promote for one candidate release. Returns the promote step's
# exit status; DOCKER_LOG and REGISTRY_STATE reflect the outcome.
run_release() {
  local candidate="$1" dockerhub_enabled="${2:-false}"
  local major="${candidate%%.*}" major_minor="${candidate%.*}"
  seed_digest "$candidate"
  : > "${TMP}/docker.log"
  local current_out="${TMP}/current.out"
  : > "$current_out"
  (
    export PATH="${FAKE_BIN}:${PATH}"
    export REGISTRY_STATE
    export DIGEST_MAP
    export GHCR_IMAGE
    export MAJOR="$major"
    export MAJOR_MINOR="$major_minor"
    export GITHUB_OUTPUT="$current_out"
    bash "$RESOLVE_SCRIPT"
  ) >"${TMP}/resolve.out" 2>&1 || { harness_fail "resolve step unexpectedly failed for ${candidate}: $(cat "${TMP}/resolve.out")"; return 1; }

  local latest_current major_current major_minor_current
  latest_current="$(grep -E '^latest=' "$current_out" | head -1 | cut -d= -f2-)"
  major_current="$(grep -E '^major=' "$current_out" | head -1 | cut -d= -f2-)"
  major_minor_current="$(grep -E '^major_minor=' "$current_out" | head -1 | cut -d= -f2-)"

  (
    export PATH="${FAKE_BIN}:${PATH}"
    export REGISTRY_STATE
    export DIGEST_MAP
    export CANDIDATE="$candidate"
    export MAJOR="$major"
    export MAJOR_MINOR="$major_minor"
    export LATEST_CURRENT="$latest_current"
    export MAJOR_CURRENT="$major_current"
    export MAJOR_MINOR_CURRENT="$major_minor_current"
    local candidate_digest
    candidate_digest="$(digest_for "$candidate")"
    export DIGEST="$candidate_digest"
    export GHCR_IMAGE
    export DOCKERHUB_IMAGE
    export DOCKERHUB_ENABLED="$dockerhub_enabled"
    export ORDER_SCRIPT="$ORDER"
    export DOCKER_LOG="${TMP}/docker.log"
    bash "$PROMOTE_SCRIPT"
  ) >"${TMP}/promote.out" 2>&1
}

promoted_tag_count() {
  local tag="$1"
  grep -c -- "--tag ${GHCR_IMAGE}:${tag} " "${TMP}/docker.log" 2>/dev/null || true
}

# --- First-ever promotion: no tags exist yet; everything advances ----------
if run_release "0.4.1"; then
  assert_eq "0.4.1" "$(registry_version_of "${GHCR_IMAGE}:latest")" \
    "first promotion advances latest to 0.4.1"
  assert_eq "0.4.1" "$(registry_version_of "${GHCR_IMAGE}:0")" \
    "first promotion advances the major tag to 0.4.1"
  assert_eq "0.4.1" "$(registry_version_of "${GHCR_IMAGE}:0.4")" \
    "first promotion advances the major.minor tag to 0.4.1"
else
  harness_fail "first promotion unexpectedly failed: $(cat "${TMP}/promote.out")"
fi

# --- A late/out-of-order 0.4.0 must NOT regress any of the three tags ------
if run_release "0.4.0"; then
  assert_eq "0.4.1" "$(registry_version_of "${GHCR_IMAGE}:latest")" \
    "a late 0.4.0 does not regress latest"
  assert_eq "0.4.1" "$(registry_version_of "${GHCR_IMAGE}:0")" \
    "a late 0.4.0 does not regress the major tag"
  assert_eq "0.4.1" "$(registry_version_of "${GHCR_IMAGE}:0.4")" \
    "a late 0.4.0 does not regress the major.minor tag"
  assert_contains "$(cat "${TMP}/promote.out")" "nothing to promote" \
    "a late 0.4.0 promotion has nothing to promote and says so"
else
  harness_fail "late 0.4.0 promotion unexpectedly errored: $(cat "${TMP}/promote.out")"
fi

# --- Equal retry is a safe, idempotent no-op re-promotion -------------------
if run_release "0.4.1"; then
  assert_eq "0.4.1" "$(registry_version_of "${GHCR_IMAGE}:latest")" \
    "an equal retry re-promotes the same version safely"
else
  harness_fail "equal-retry promotion unexpectedly failed: $(cat "${TMP}/promote.out")"
fi

# --- THE independent backport scenario (item 6) -----------------------------
# 2.0.0 is released and promotes latest/2/2.0. A 1.9.0 -> 1.9.1 backport is
# then released for the OLDER 1.x series: it must skip 'latest' (1.9.1 is
# older than the promoted 2.0.0) but still independently advance '1' and
# '1.9' because 1.9.1 is newer than whatever THEY currently point at.
: > "$REGISTRY_STATE"
: > "$DIGEST_MAP"
: > "${TMP}/docker.log"
if run_release "2.0.0"; then
  assert_eq "2.0.0" "$(registry_version_of "${GHCR_IMAGE}:latest")" \
    "backport setup: 2.0.0 promotes latest"
  assert_eq "2.0.0" "$(registry_version_of "${GHCR_IMAGE}:2")" \
    "backport setup: 2.0.0 promotes the major tag 2"
  assert_eq "2.0.0" "$(registry_version_of "${GHCR_IMAGE}:2.0")" \
    "backport setup: 2.0.0 promotes the major.minor tag 2.0"
else
  harness_fail "backport setup (2.0.0) unexpectedly failed: $(cat "${TMP}/promote.out")"
fi
# Seed the OLDER 1.x series tags as already existing at 1.9.0 (as if
# released before 2.0.0 existed).
seed_registry_tag "${GHCR_IMAGE}:1" "1.9.0"
seed_registry_tag "${GHCR_IMAGE}:1.9" "1.9.0"

if run_release "1.9.1"; then
  assert_eq "2.0.0" "$(registry_version_of "${GHCR_IMAGE}:latest")" \
    "backport 1.9.1 after 2.0.0 does NOT regress latest (stays at 2.0.0)"
  assert_eq "1.9.1" "$(registry_version_of "${GHCR_IMAGE}:1")" \
    "backport 1.9.1 after 2.0.0 STILL advances the major tag 1 (1.9.0 -> 1.9.1)"
  assert_eq "1.9.1" "$(registry_version_of "${GHCR_IMAGE}:1.9")" \
    "backport 1.9.1 after 2.0.0 STILL advances the major.minor tag 1.9 (1.9.0 -> 1.9.1)"
  assert_contains "$(cat "${TMP}/promote.out")" "Skipping 'latest'" \
    "the backport promotion explicitly explains why latest was skipped"
  assert_eq "0" "$(promoted_tag_count latest)" \
    "the backport promotion's imagetools call never includes --tag latest"
else
  harness_fail "backport promotion (1.9.1) unexpectedly failed: $(cat "${TMP}/promote.out")"
fi

# --- Dual-registry promotion: Docker Hub mirrors the same independent gates -
: > "$REGISTRY_STATE"
: > "$DIGEST_MAP"
: > "${TMP}/docker.log"
if run_release "0.5.0" "true"; then
  assert_eq "0.5.0" "$(registry_version_of "${DOCKERHUB_IMAGE}:latest")" \
    "enabled Docker Hub is promoted alongside GHCR"
  assert_eq "0.5.0" "$(registry_version_of "${GHCR_IMAGE}:latest")" \
    "GHCR is still promoted when Docker Hub is also enabled"
else
  harness_fail "dual-registry promotion unexpectedly failed: $(cat "${TMP}/promote.out")"
fi

# --- A non-stable candidate reaching the step is defensively rejected ------
: > "$REGISTRY_STATE"
: > "$DIGEST_MAP"
seed_digest "0.5.0-rc.1"
if (
  export PATH="${FAKE_BIN}:${PATH}"
  export REGISTRY_STATE
  export DIGEST_MAP
  export CANDIDATE="0.5.0-rc.1"
  export MAJOR="0"
  export MAJOR_MINOR="0.5"
  export LATEST_CURRENT=""
  export MAJOR_CURRENT=""
  export MAJOR_MINOR_CURRENT=""
  PRERELEASE_DIGEST="$(digest_for "0.5.0-rc.1")"
  export DIGEST="$PRERELEASE_DIGEST"
  export GHCR_IMAGE
  export DOCKERHUB_IMAGE
  export DOCKERHUB_ENABLED="false"
  export ORDER_SCRIPT="$ORDER"
  export DOCKER_LOG="${TMP}/docker.log"
  bash "$PROMOTE_SCRIPT"
) >"${TMP}/prerelease.out" 2>&1; then
  harness_fail "promotion step unexpectedly accepted a prerelease candidate"
else
  assert_contains "$(cat "${TMP}/prerelease.out")" "non-stable candidate" \
    "promotion step defensively rejects a non-stable candidate"
fi

if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$RELEASE_YML"; then
    harness_ok "actionlint accepts the independent per-tag promotion workflow"
  else
    harness_fail "actionlint rejected the independent per-tag promotion workflow"
  fi
else
  echo "  skip: actionlint not available; static and functional checks completed."
fi

harness_summary
