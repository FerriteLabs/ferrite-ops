#!/usr/bin/env bash
# compute-source-checksum.sh — single trusted source of truth for the
# canonical Ferrite source-archive SHA256 checksum, shared by release.yml,
# version-sync.yml, and release-orchestration.yml.
#
# The canonical checksum is ALWAYS downloaded and computed fresh from the
# tagged GitHub source archive for the given version. A caller-supplied
# checksum — from a repository_dispatch client_payload or a manual
# workflow_dispatch input — is NEVER trusted as truth on its own: if
# supplied, it is first validated for shape and then compared byte-for-byte
# against the freshly computed canonical value. Any mismatch fails loudly
# instead of silently accepting an unverified, stale, or malicious value; a
# syntactically invalid supplied value fails before any network access.
#
# Usage:
#   compute-source-checksum.sh <repository-owner> <version> [<supplied-sha256>]
#
# Prints the canonical, normalized (lowercase) SHA256 to stdout on success.
# All diagnostic/progress output goes to stderr, so stdout is always exactly
# the 64-character checksum and nothing else.
#
# Exit codes:
#   0 — canonical checksum computed (and, if supplied, confirmed to match)
#   1 — invalid input, download/hash failure, or supplied/computed mismatch
#   2 — usage error (wrong argument count)
set -euo pipefail

err() {
  echo "compute-source-checksum: $*" >&2
}

SHA256_RE='^[0-9a-f]{64}$'
OWNER_RE='^[A-Za-z0-9_.-]+$'
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  err "usage: $0 <repository-owner> <version> [<supplied-sha256>]"
  exit 2
fi

REPOSITORY_OWNER="$1"
VERSION="$2"
SUPPLIED_SHA256="${3:-}"

if ! printf '%s\n' "$REPOSITORY_OWNER" | grep -qE "$OWNER_RE"; then
  err "invalid repository owner: '${REPOSITORY_OWNER}'"
  exit 1
fi
if ! printf '%s\n' "$VERSION" | grep -qE "$VERSION_RE"; then
  err "invalid version: '${VERSION}'"
  exit 1
fi

# Validate the supplied checksum's SHAPE before any network access — an
# obviously malformed value (wrong length, non-hex characters, a shell
# metacharacter injection attempt, ...) is rejected immediately rather than
# being carried forward to a comparison against the real download.
NORMALIZED_SUPPLIED=""
if [ -n "$SUPPLIED_SHA256" ]; then
  NORMALIZED_SUPPLIED="$(printf '%s' "$SUPPLIED_SHA256" | tr 'A-F' 'a-f')"
  if ! printf '%s\n' "$NORMALIZED_SUPPLIED" | grep -qE "$SHA256_RE"; then
    err "supplied SHA256 is not exactly 64 hexadecimal characters: '${SUPPLIED_SHA256}'"
    exit 1
  fi
fi

TARBALL_URL="https://github.com/${REPOSITORY_OWNER}/ferrite/archive/refs/tags/v${VERSION}.tar.gz"
err "computing canonical source archive SHA256 for ${TARBALL_URL} ..."

COMPUTED_SHA256=""
if ! COMPUTED_SHA256="$(curl -fsSL "$TARBALL_URL" | shasum -a 256 | awk '{print $1}')"; then
  err "failed to download or hash the canonical source archive: ${TARBALL_URL}"
  exit 1
fi
COMPUTED_SHA256="$(printf '%s' "$COMPUTED_SHA256" | tr 'A-F' 'a-f')"
if ! printf '%s\n' "$COMPUTED_SHA256" | grep -qE "$SHA256_RE"; then
  err "failed to obtain a valid SHA256 checksum for the source archive (got: '${COMPUTED_SHA256}')"
  exit 1
fi

# The freshly computed value is the ONLY source of truth. A supplied
# checksum is corroborating evidence at most: it must match exactly, or the
# release is refused outright rather than silently trusting either value.
if [ -n "$NORMALIZED_SUPPLIED" ] && [ "$NORMALIZED_SUPPLIED" != "$COMPUTED_SHA256" ]; then
  err "supplied SHA256 (${NORMALIZED_SUPPLIED}) does not match the canonical computed checksum (${COMPUTED_SHA256}) for v${VERSION}; refusing to trust the supplied value."
  exit 1
fi

err "canonical source archive SHA256 for v${VERSION}: ${COMPUTED_SHA256}"
printf '%s\n' "$COMPUTED_SHA256"
