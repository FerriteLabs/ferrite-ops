#!/usr/bin/env bash
# Resolve an exact image tag once, then inspect its platform/config metadata
# exclusively through the resulting immutable digest reference.
#
# Usage:
#   inspect-exact-image-metadata.sh <image> <exact-tag>
#
# Prints one compact JSON object:
#   {"digest":"sha256:...","manifest":{...},"image":{...}}
#
# The first registry request is necessarily tag-based so the caller can
# resolve the exact tag. Every subsequent request is IMAGE@DIGEST, preventing
# a tag move between requests from mixing one object's manifest digest with a
# different object's platform configs or labels.
set -euo pipefail

err() {
  echo "inspect-exact-image-metadata: $*" >&2
}

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  err "usage: $0 <image> <exact-tag>"
  exit 2
fi

IMAGE="$1"
EXACT_TAG="$2"
TAGGED_REF="${IMAGE}:${EXACT_TAG}"

MANIFEST_JSON="$(docker buildx imagetools inspect \
  "$TAGGED_REF" --format '{{json .Manifest}}')"

DIGEST="$(printf '%s' "$MANIFEST_JSON" |
  jq -r '.digest // empty')"
if ! printf '%s\n' "$DIGEST" | grep -qE '^sha256:[0-9a-f]{64}$'; then
  err "${TAGGED_REF} did not resolve to a valid sha256 manifest digest"
  exit 1
fi

PINNED_REF="${IMAGE}@${DIGEST}"
IMAGE_JSON="$(docker buildx imagetools inspect \
  "$PINNED_REF" --format '{{json .Image}}')"

if ! jq -cn \
  --arg digest "$DIGEST" \
  --argjson manifest "$MANIFEST_JSON" \
  --argjson image "$IMAGE_JSON" \
  '{digest: $digest, manifest: $manifest, image: $image}'; then
  err "registry returned malformed manifest or image metadata for ${PINNED_REF}"
  exit 1
fi
