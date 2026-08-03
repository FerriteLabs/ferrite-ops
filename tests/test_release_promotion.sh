#!/usr/bin/env bash
# Static and functional coverage for release.yml's serialized floating-tag
# promotion. The functional replay extracts the real "Promote floating tags"
# run script and exercises it against a fake `docker` and the real
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
DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"

# --- Static architecture checks --------------------------------------------
assert_contains "$CONTENT" "promote-stable:" \
  "release.yml defines a dedicated floating-tag promotion job"
assert_contains "$CONTENT" "if: needs.build-and-push.outputs.stable == 'true'" \
  "promotion runs only for stable releases; prereleases stay exact-only"
assert_contains "$CONTENT" "group: ferrite-floating-tag-promotion" \
  "promotion is serialized by a fixed concurrency group"
assert_contains "$CONTENT" "cancel-in-progress: false" \
  "serialized promotions queue instead of cancelling each other"
assert_contains "$CONTENT" "docker buildx imagetools create" \
  "promotion advances floating tags on the signed digest via imagetools"
assert_not_contains "$CONTENT" 'type=raw,value=latest' \
  "the exact-version build never bakes a floating latest tag"
assert_contains "$CONTENT" "Resolve current promoted stable version" \
  "promotion resolves the current promoted version from registry metadata"
assert_not_contains "$CONTENT" "client_payload.*promoted" \
  "promotion never trusts workflow input for the current promoted version"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  skip: python3/PyYAML unavailable; skipping promotion functional replay."
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROMOTE_SCRIPT="${TMP}/promote.sh"
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
  harness_fail "could not extract the promotion step from release.yml"
  harness_summary
  exit $?
fi
harness_ok "extracted the floating-tag promotion step from release.yml"

# Fake docker: record every imagetools invocation instead of contacting a
# registry. Anything other than `buildx imagetools create` is a no-op.
FAKE_BIN="${TMP}/bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG}"
exit 0
FAKE
chmod +x "${FAKE_BIN}/docker"

# Run the promotion step for one candidate against a given current-promoted
# version. Echoes the resulting "registry latest" version so callers can chain
# serialized promotions. DOCKER_LOG accumulates every imagetools create call.
run_promotion() {
  local candidate="$1" current="$2" dockerhub_enabled="${3:-false}"
  : > "${TMP}/docker.log"
  (
    export PATH="${FAKE_BIN}:${PATH}"
    export DOCKER_LOG="${TMP}/docker.log"
    export CANDIDATE="$candidate"
    export CURRENT_PROMOTED="$current"
    export MAJOR="${candidate%%.*}"
    export MAJOR_MINOR="${candidate%.*}"
    export DIGEST="$DIGEST"
    export GHCR_IMAGE="ghcr.io/ferritelabs/ferrite"
    export DOCKERHUB_IMAGE="ferritelabs/ferrite"
    export DOCKERHUB_ENABLED="$dockerhub_enabled"
    export ORDER_SCRIPT="$ORDER"
    bash "$PROMOTE_SCRIPT" >"${TMP}/promote.out" 2>&1
  )
}

promoted_latest() {
  # Grep the fake docker log for the most recently promoted digest tag set.
  grep -c -- "--tag ghcr.io/ferritelabs/ferrite:latest" "${TMP}/docker.log"
}

# First-ever promotion (no current): floating tags advance to the candidate.
if run_promotion "0.4.1" ""; then
  assert_eq "1" "$(promoted_latest)" \
    "first promotion advances latest to 0.4.1"
  assert_contains "$(cat "${TMP}/docker.log")" "ghcr.io/ferritelabs/ferrite:0.4" \
    "first promotion advances the major.minor floating tag"
  assert_contains "$(cat "${TMP}/docker.log")" "ghcr.io/ferritelabs/ferrite@${DIGEST}" \
    "promotion references the already-built, already-signed digest"
else
  harness_fail "first promotion unexpectedly failed: $(cat "${TMP}/promote.out")"
fi

# 0.4.1 already promoted; a late/out-of-order 0.4.0 must NOT regress latest.
if run_promotion "0.4.0" "0.4.1"; then
  assert_eq "0" "$(promoted_latest)" \
    "a late 0.4.0 does not overwrite the newer promoted 0.4.1 floating tags"
  assert_contains "$(cat "${TMP}/promote.out")" "Skipping floating-tag promotion" \
    "a late 0.4.0 promotion is explicitly skipped"
else
  harness_fail "late 0.4.0 promotion unexpectedly errored: $(cat "${TMP}/promote.out")"
fi

# Newer stable over an older current: promotes.
if run_promotion "0.4.1" "0.4.0"; then
  assert_eq "1" "$(promoted_latest)" "0.4.1 promotes over an older promoted 0.4.0"
else
  harness_fail "0.4.1-over-0.4.0 promotion unexpectedly failed: $(cat "${TMP}/promote.out")"
fi

# Equal retry (same version re-released): promotion is idempotently allowed.
if run_promotion "0.4.1" "0.4.1"; then
  assert_eq "1" "$(promoted_latest)" "an equal retry re-promotes the same version safely"
else
  harness_fail "equal-retry promotion unexpectedly failed: $(cat "${TMP}/promote.out")"
fi

# Concurrent candidates 0.4.0 and 0.4.1: the concurrency group serializes the
# two promotions. Whatever the interleaving, once 0.4.1 has promoted, 0.4.0's
# serialized promotion reads current=0.4.1 and skips — latest never regresses.
CURRENT=""
# 0.4.1's promotion runs first and wins.
run_promotion "0.4.1" "$CURRENT" >/dev/null
if [ "$(promoted_latest)" = "1" ]; then CURRENT="0.4.1"; fi
# 0.4.0's promotion runs next against the now-current 0.4.1.
run_promotion "0.4.0" "$CURRENT" >/dev/null
assert_eq "0" "$(promoted_latest)" \
  "serialized concurrent candidates leave latest pinned to the newest (0.4.1)"
assert_eq "0.4.1" "$CURRENT" \
  "the newest concurrent candidate remains the promoted stable version"

# Docker Hub enabled: floating tags advance on both registries.
if run_promotion "0.5.0" "0.4.1" "true"; then
  assert_contains "$(cat "${TMP}/docker.log")" "ghcr.io/ferritelabs/ferrite:latest" \
    "enabled Docker Hub still promotes the GHCR floating tags"
  assert_contains "$(cat "${TMP}/docker.log")" "ferritelabs/ferrite:latest" \
    "enabled Docker Hub also promotes the Docker Hub floating tags"
else
  harness_fail "dual-registry promotion unexpectedly failed: $(cat "${TMP}/promote.out")"
fi

# A non-stable candidate reaching the step is defensively rejected.
if run_promotion "0.5.0-rc.1" "0.4.1"; then
  harness_fail "promotion step unexpectedly accepted a prerelease candidate"
else
  assert_contains "$(cat "${TMP}/promote.out")" "non-stable candidate" \
    "promotion step defensively rejects a non-stable candidate"
fi

if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$RELEASE_YML"; then
    harness_ok "actionlint accepts the split build/promote release workflow"
  else
    harness_fail "actionlint rejected the split build/promote release workflow"
  fi
else
  echo "  skip: actionlint not available; static and functional checks completed."
fi

harness_summary
