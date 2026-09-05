#!/usr/bin/env bash
# Proves exact-tag metadata is resolved once and every platform/config request
# after that resolution uses IMAGE@DIGEST, even if the mutable tag moves.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

SCRIPT="${REPO_ROOT}/scripts/inspect-exact-image-metadata.sh"
LABELS_SCRIPT="${REPO_ROOT}/scripts/verify-exact-image-labels.sh"
FIXTURE="${HERE}/fixtures/inspect-exact-image-metadata/moving-tag.json"
RELEASE_YML="${REPO_ROOT}/.github/workflows/release.yml"
RECONCILE_YML="${REPO_ROOT}/.github/workflows/reconcile-release-tags.yml"

if [[ ! -x "$SCRIPT" ]]; then
  harness_fail "scripts/inspect-exact-image-metadata.sh is not executable"
fi
if [[ ! -f "$FIXTURE" ]]; then
  harness_fail "moving-tag metadata fixture is present"
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "  skip: jq unavailable; skipping pinned metadata functional replay."
  harness_summary
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_BIN="${TMP}/bin"
CALL_LOG="${TMP}/docker-calls.log"
mkdir -p "$FAKE_BIN"
: >"$CALL_LOG"

cat >"${FAKE_BIN}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "buildx" ] || [ "${2:-}" != "imagetools" ] ||
  [ "${3:-}" != "inspect" ]; then
  echo "unexpected docker invocation: $*" >&2
  exit 1
fi

REF="$4"
FORMAT="${6:-}"
IMAGE="$(jq -r '.image' "$MOVING_TAG_FIXTURE")"
TAG="$(jq -r '.tag' "$MOVING_TAG_FIXTURE")"
INITIAL_DIGEST="$(jq -r '.initial.digest' "$MOVING_TAG_FIXTURE")"
MOVED_DIGEST="$(jq -r '.moved.digest' "$MOVING_TAG_FIXTURE")"
printf '%s %s\n' "$REF" "$FORMAT" >>"$DOCKER_CALL_LOG"

if [ "$REF" = "${IMAGE}:${TAG}" ] && [ "$FORMAT" = '{{json .Manifest}}' ]; then
    # This first response resolves the original object. The fixture models
    # the tag moving immediately afterward, before the caller requests the
    # platform/config `.Image` view.
    jq -c '.initial.manifest' "$MOVING_TAG_FIXTURE"
elif [ "$REF" = "${IMAGE}:${TAG}" ] && [ "$FORMAT" = '{{json .Image}}' ]; then
    # Any second tag-based request observes the moved object and its wrong
    # labels. Correct code never reaches this branch.
    jq -c '.moved.image' "$MOVING_TAG_FIXTURE"
elif [ "$REF" = "${IMAGE}@${INITIAL_DIGEST}" ] && [ "$FORMAT" = '{{json .Image}}' ]; then
    jq -c '.initial.image' "$MOVING_TAG_FIXTURE"
elif [ "$REF" = "${IMAGE}@${MOVED_DIGEST}" ] && [ "$FORMAT" = '{{json .Image}}' ]; then
    jq -c '.moved.image' "$MOVING_TAG_FIXTURE"
else
  echo "unexpected inspect reference/format: ${REF} ${FORMAT}" >&2
  exit 1
fi
SH
chmod +x "${FAKE_BIN}/docker"

IMAGE="$(jq -r '.image' "$FIXTURE")"
TAG="$(jq -r '.tag' "$FIXTURE")"
INITIAL_DIGEST="$(jq -r '.initial.digest' "$FIXTURE")"
EXPECTED_SHA="$(jq -r '.initial.image["linux/amd64"].config.Labels["dev.ferritelabs.image.source-sha256"]' "$FIXTURE")"

METADATA_JSON="$(
  export PATH="${FAKE_BIN}:${PATH}"
  export MOVING_TAG_FIXTURE="$FIXTURE"
  export DOCKER_CALL_LOG="$CALL_LOG"
  bash "$SCRIPT" "$IMAGE" "$TAG"
)"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  harness_ok "shared metadata helper succeeds while the exact tag moves between registry requests"
else
  harness_fail "shared metadata helper failed against the moving-tag fixture"
fi

assert_eq "$INITIAL_DIGEST" "$(printf '%s' "$METADATA_JSON" | jq -r '.digest')" \
  "the helper records the digest resolved by the first tag request"
assert_eq "1.2.3" \
  "$(printf '%s' "$METADATA_JSON" | jq -r '.image["linux/amd64"].config.Labels["org.opencontainers.image.version"]')" \
  "platform metadata comes from the initially resolved immutable object"
assert_not_contains "$METADATA_JSON" "9.9.9" \
  "metadata from the moved tag is never mixed into the resolved object"
assert_eq \
  "${IMAGE}:${TAG} {{json .Manifest}}
${IMAGE}@${INITIAL_DIGEST} {{json .Image}}" \
  "$(cat "$CALL_LOG")" \
  "the only post-resolution metadata request uses IMAGE@DIGEST"

if printf '%s' "$METADATA_JSON" |
  bash "$LABELS_SCRIPT" exact "1.2.3" "$EXPECTED_SHA" >/dev/null 2>&1; then
  harness_ok "the pinned payload passes the shared exact-label verifier"
else
  harness_fail "the pinned payload did not pass the shared exact-label verifier"
fi

RELEASE_CONTENT="$(cat "$RELEASE_YML")"
RECONCILE_CONTENT="$(cat "$RECONCILE_YML")"
assert_contains "$RELEASE_CONTENT" "METADATA_SCRIPT: scripts/inspect-exact-image-metadata.sh" \
  "release.yml wires in the shared digest-pinned metadata helper"
assert_contains "$RELEASE_CONTENT" 'bash "$METADATA_SCRIPT" "$GHCR_IMAGE" "$VERSION"' \
  "release.yml resolves existing exact-tag metadata through the shared helper"
assert_contains "$RECONCILE_CONTENT" "METADATA_SCRIPT: scripts/inspect-exact-image-metadata.sh" \
  "reconcile-release-tags.yml wires in the shared digest-pinned metadata helper"
assert_contains "$RECONCILE_CONTENT" 'bash "$METADATA_SCRIPT" "$GHCR_IMAGE" "$VERSION"' \
  "reconciliation resolves exact-tag metadata through the shared helper"
assert_not_contains "$RELEASE_CONTENT" '"${GHCR_IMAGE}:${VERSION}" --format '"'"'{{json .Image}}'"'"'' \
  "release.yml never reads exact-tag platform/config metadata through the mutable tag"
assert_not_contains "$RECONCILE_CONTENT" '"${GHCR_IMAGE}:${VERSION}" --format '"'"'{{json .Image}}'"'"'' \
  "reconciliation never reads exact-tag platform/config metadata through the mutable tag"
assert_contains "$RECONCILE_CONTENT" '"${GHCR_IMAGE}@${DIGEST}"' \
  "reconciliation re-checks planned sources through their immutable digest references"

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning "$SCRIPT" "$0"; then
    harness_ok "shellcheck accepts the shared pinned-metadata helper and its regression test"
  else
    harness_fail "shellcheck rejected the shared pinned-metadata helper or regression test"
  fi
fi

harness_summary
