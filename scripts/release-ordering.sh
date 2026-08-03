#!/usr/bin/env bash
# release-ordering.sh — Deterministic SemVer release-ordering guard.
#
# Single source of truth for release *precedence* decisions across the
# release and version-sync workflows, so an out-of-order, retried, or stale
# release can never regress a floating registry tag or a canonical pin.
#
# Subcommands:
#   semver-cmp A B    Print 'lt', 'eq', or 'gt' for A relative to B using
#                     SemVer 2.0 precedence (including pre-release handling).
#   ge A B            Exit 0 if A >= B, exit 1 if A < B (SemVer precedence).
#   classify CAND_VER CAND_SHA CUR_VER CUR_SHA
#                     Print NEWER / EQUAL_SAME / EQUAL_DIFFERENT / OLDER for a
#                     candidate release relative to the current one.
#
# Every version and checksum argument is validated before use; invalid input
# is rejected with a clear error and a non-zero exit, so an untrusted payload
# can never smuggle shell metacharacters through this guard.
set -euo pipefail

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'
SHA256_RE='^[0-9a-f]{64}$'

err() {
  echo "release-ordering: $*" >&2
}

validate_semver() {
  if ! printf '%s\n' "$1" | grep -qE "$SEMVER_RE"; then
    err "invalid SemVer: '$1'"
    exit 2
  fi
}

validate_sha256() {
  if ! printf '%s\n' "$1" | grep -qE "$SHA256_RE"; then
    err "invalid SHA-256: '$1'"
    exit 2
  fi
}

# Compare the numeric MAJOR.MINOR.PATCH cores. Echoes -1, 0, or 1.
_cmp_core() {
  local -a a_parts b_parts
  IFS='.' read -r -a a_parts <<<"$1"
  IFS='.' read -r -a b_parts <<<"$2"
  local i a_field b_field
  for i in 0 1 2; do
    a_field="${a_parts[$i]}"
    b_field="${b_parts[$i]}"
    if ((10#$a_field < 10#$b_field)); then
      echo -1
      return
    fi
    if ((10#$a_field > 10#$b_field)); then
      echo 1
      return
    fi
  done
  echo 0
}

# Compare two dot-separated pre-release strings (either may be empty). Echoes
# -1, 0, or 1 per SemVer 2.0: a version with no pre-release outranks one that
# has a pre-release, numeric identifiers rank below alphanumeric ones, and a
# larger set of identifiers wins when all preceding identifiers are equal.
_cmp_prerelease() {
  local a="$1" b="$2"
  if [[ -z "$a" && -z "$b" ]]; then
    echo 0
    return
  fi
  if [[ -z "$a" ]]; then
    echo 1
    return
  fi
  if [[ -z "$b" ]]; then
    echo -1
    return
  fi
  local -a a_ids b_ids
  IFS='.' read -r -a a_ids <<<"$a"
  IFS='.' read -r -a b_ids <<<"$b"
  local n=${#a_ids[@]} m=${#b_ids[@]} max i a_id b_id a_num b_num
  if ((n > m)); then max=$n; else max=$m; fi
  for ((i = 0; i < max; i++)); do
    if ((i >= n)); then
      echo -1
      return
    fi
    if ((i >= m)); then
      echo 1
      return
    fi
    a_id="${a_ids[$i]}"
    b_id="${b_ids[$i]}"
    a_num=0
    b_num=0
    if [[ "$a_id" =~ ^[0-9]+$ ]]; then a_num=1; fi
    if [[ "$b_id" =~ ^[0-9]+$ ]]; then b_num=1; fi
    if ((a_num == 1 && b_num == 1)); then
      if ((10#$a_id < 10#$b_id)); then
        echo -1
        return
      fi
      if ((10#$a_id > 10#$b_id)); then
        echo 1
        return
      fi
    elif ((a_num == 1 && b_num == 0)); then
      echo -1
      return
    elif ((a_num == 0 && b_num == 1)); then
      echo 1
      return
    else
      if [[ "$a_id" < "$b_id" ]]; then
        echo -1
        return
      fi
      if [[ "$a_id" > "$b_id" ]]; then
        echo 1
        return
      fi
    fi
  done
  echo 0
}

semver_cmp() {
  local a="$1" b="$2" a_core b_core a_pre b_pre c
  a_core="${a%%-*}"
  b_core="${b%%-*}"
  if [[ "$a" == *-* ]]; then a_pre="${a#*-}"; else a_pre=""; fi
  if [[ "$b" == *-* ]]; then b_pre="${b#*-}"; else b_pre=""; fi
  c="$(_cmp_core "$a_core" "$b_core")"
  if [[ "$c" != 0 ]]; then
    if [[ "$c" == 1 ]]; then echo gt; else echo lt; fi
    return
  fi
  c="$(_cmp_prerelease "$a_pre" "$b_pre")"
  case "$c" in
  1) echo gt ;;
  -1) echo lt ;;
  *) echo eq ;;
  esac
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
  semver-cmp)
    validate_semver "${2:-}"
    validate_semver "${3:-}"
    semver_cmp "$2" "$3"
    ;;
  ge)
    validate_semver "${2:-}"
    validate_semver "${3:-}"
    if [[ "$(semver_cmp "$2" "$3")" == lt ]]; then
      exit 1
    fi
    exit 0
    ;;
  classify)
    validate_semver "${2:-}"
    validate_sha256 "${3:-}"
    validate_semver "${4:-}"
    validate_sha256 "${5:-}"
    case "$(semver_cmp "$2" "$4")" in
    gt) echo NEWER ;;
    lt) echo OLDER ;;
    eq)
      if [[ "$3" == "$5" ]]; then echo EQUAL_SAME; else echo EQUAL_DIFFERENT; fi
      ;;
    esac
    ;;
  *)
    err "unknown subcommand: '${cmd}'"
    exit 2
    ;;
  esac
}

main "$@"
