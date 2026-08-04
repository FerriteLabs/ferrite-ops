#!/usr/bin/env bash
# verify-exact-image-labels.sh — single trusted source of truth for what it
# means for a (possibly multi-platform) exact-tag OCI image to carry correct
# `org.opencontainers.image.version` / `dev.ferritelabs.image.source-sha256`
# labels.
#
# Used by BOTH release.yml's pre-build "Check existing exact GHCR tag" step
# (which knows this run's own freshly computed version/checksum and must
# reject ANY platform that disagrees with them) and
# reconcile-release-tags.yml's "Verify every exact stable GHCR source" step
# (which has no independent source of truth for a historical release's
# checksum, but must still refuse a tag whose platforms disagree with EACH
# OTHER). Centralizing this logic in one script means the two workflows can
# never drift on what "this exact tag's metadata is trustworthy" means: the
# earlier duplicated inline jq in release.yml only ever inspected the FIRST
# platform of a multi-platform manifest, silently ignoring the rest, while
# reconcile-release-tags.yml's independently-written jq already inspected
# every platform. That drift is exactly the bug this shared script closes.
#
# `docker buildx imagetools inspect <ref> --format '{{json .Image}}'` prints
# either:
#   - a single object with a top-level "config" key, for a single-platform
#     image, or
#   - an object mapping each platform string (e.g. "linux/amd64") to its own
#     `{"config": {...}}`, for a multi-platform image.
# This script normalizes both shapes into a list of "platform configs" and
# requires EVERY one of them — not just the first — to carry the expected
# labels, so mixed-platform metadata (a stale or partially-rebuilt manifest
# list) always fails instead of silently passing on the strength of a single
# platform.
#
# Usage:
#   verify-exact-image-labels.sh exact <version> <sha256>
#     Reads the `.Image` JSON on stdin. Requires EVERY platform's
#     org.opencontainers.image.version label to equal <version> AND its
#     dev.ferritelabs.image.source-sha256 label to equal <sha256> EXACTLY
#     (byte-for-byte). Used when the caller already knows the specific
#     correct checksum (release.yml's own freshly computed value).
#
#   verify-exact-image-labels.sh consistent <version>
#     Reads the `.Image` JSON on stdin. Requires EVERY platform's version
#     label to equal <version>, EVERY platform's source-sha256 label to be a
#     well-formed 64-hex-digit value, and ALL platforms to share the exact
#     SAME source-sha256 value. Used when the caller has no independently
#     known canonical checksum for a historical exact tag (reconciliation)
#     but must still refuse inconsistent per-platform metadata.
#
# In both modes: an image with zero platforms, a platform missing either
# label, or malformed input JSON all FAIL.
#
# Exit codes: 0 = verified; 1 = mismatched/missing/inconsistent labels or
# unreadable input; 2 = usage error.
set -euo pipefail

VERSION_LABEL='org.opencontainers.image.version'
SHA256_LABEL='dev.ferritelabs.image.source-sha256'
SHA256_RE='^[0-9a-f]{64}$'

err() {
  echo "verify-exact-image-labels: $*" >&2
}

usage() {
  err "usage: $0 exact <version> <sha256>"
  err "       $0 consistent <version>"
  exit 2
}

# Shared jq helper: normalizes either a single-platform `{"config": {...}}`
# object or a multi-platform `{"<platform>": {"config": {...}}, ...}` map
# into an array of platform config objects.
JQ_IMAGES_DEF='
  def images:
    if type == "object" and has("config") then [.]
    elif type == "object" then [.[]]
    else [] end;
'

main() {
  if [ "$#" -lt 2 ]; then
    usage
  fi
  local mode="$1" version="$2" sha256="${3:-}"

  case "$mode" in
    exact)
      if [ "$#" -ne 3 ] || [ -z "$version" ] || [ -z "$sha256" ]; then
        usage
      fi
      ;;
    consistent)
      if [ "$#" -ne 2 ] || [ -z "$version" ]; then
        usage
      fi
      ;;
    *)
      usage
      ;;
  esac

  local raw_image
  if ! raw_image="$(cat)"; then
    err "could not read image manifest JSON from stdin"
    exit 1
  fi
  if [ -z "$raw_image" ]; then
    err "empty image manifest JSON on stdin"
    exit 1
  fi

  local jq_filter
  case "$mode" in
    exact)
      jq_filter="${JQ_IMAGES_DEF}"'
        images as $images |
        ($images | length) > 0 and
        all($images[]; (.config.Labels["'"$VERSION_LABEL"'"] // "") == $version) and
        all($images[]; (.config.Labels["'"$SHA256_LABEL"'"] // "") == $sha256)
      '
      ;;
    consistent)
      jq_filter="${JQ_IMAGES_DEF}"'
        images as $images |
        ($images | length) > 0 and
        all($images[]; (.config.Labels["'"$VERSION_LABEL"'"] // "") == $version) and
        all($images[]; (.config.Labels["'"$SHA256_LABEL"'"] // "") | test("'"$SHA256_RE"'")) and
        ([$images[] | .config.Labels["'"$SHA256_LABEL"'"]] | unique | length) == 1
      '
      ;;
  esac

  local jq_err
  jq_err="$(mktemp)"

  if printf '%s' "$raw_image" |
    jq -e --arg version "$version" --arg sha256 "$sha256" "$jq_filter" \
      >/dev/null 2>"$jq_err"; then
    rm -f "$jq_err"
    return 0
  fi

  if [ -s "$jq_err" ]; then
    err "could not evaluate image labels (malformed manifest JSON?):"
    cat "$jq_err" >&2
  else
    if [ "$mode" = exact ]; then
      err "image labels failed verification in 'exact' mode (expected version='${version}', sha256='${sha256}'); at least one platform's baked labels do not match exactly."
    else
      err "image labels failed verification in 'consistent' mode (expected version='${version}'); platforms are missing labels, have malformed checksums, or disagree with each other."
    fi
  fi
  rm -f "$jq_err"
  exit 1
}

main "$@"
