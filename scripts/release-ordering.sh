#!/usr/bin/env bash
# release-ordering.sh — Deterministic, strict SemVer release-ordering guard.
#
# Single source of truth for release *precedence* decisions across the
# release and version-sync workflows, so an out-of-order, retried, or stale
# release can never regress a floating registry tag or a canonical pin.
#
# Strict SemVer 2.0 enforcement:
#   - The MAJOR.MINOR.PATCH core and any purely-numeric pre-release
#     identifier must not contain a leading zero (a bare "0" is fine; "01" is
#     not). This matches the SemVer 2.0 spec precisely and rejects ambiguous
#     version strings before they can affect any ordering decision.
#   - Numeric comparisons (both the core fields and numeric pre-release
#     identifiers) are performed by comparing normalized digit-string length
#     first, then lexical (byte-wise) order for equal-length strings — never
#     with Bash arithmetic (`((...))`). Bash integer arithmetic is bounded by
#     64-bit signed range and silently misbehaves (or errors) on arbitrarily
#     large numeric fields; a version core or pre-release field is free to be
#     any number of digits under SemVer, so this script never assumes it
#     fits in a machine word.
#
# Subcommands:
#   validate VERSION  Exit 0 if VERSION is a strictly valid SemVer 2.0
#                     string per the rules above; exit 2 otherwise.
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

# Force a stable, byte-wise collation for every string comparison in this
# script (semver-cmp/_cmp_numeric_str rely on `<`/`>` being pure ASCII
# ordering, which does not hold in every locale).
export LC_ALL=C

# A SemVer core field, or a numeric pre-release identifier: either the
# single digit "0", or a non-zero digit followed by any number of digits.
# This is what actually forbids leading zeros ("00", "01", "007", ...).
NUMERIC_FIELD_RE='(0|[1-9][0-9]*)'
SEMVER_RE="^${NUMERIC_FIELD_RE}\\.${NUMERIC_FIELD_RE}\\.${NUMERIC_FIELD_RE}(-[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?\$"
SHA256_RE='^[0-9a-f]{64}$'

err() {
  echo "release-ordering: $*" >&2
}

# Validates strict SemVer 2.0: the shape regex above forbids a leading zero
# in the MAJOR/MINOR/PATCH core, and this additionally rejects a leading
# zero in any pre-release identifier that is purely numeric (an identifier
# containing any non-digit character, e.g. "rc1" or "x1", is an alphanumeric
# identifier and may take any form).
validate_semver() {
  local v="$1"
  if ! printf '%s\n' "$v" | grep -qE "$SEMVER_RE"; then
    err "invalid SemVer: '$v'"
    exit 2
  fi
  if [[ "$v" == *-* ]]; then
    local pre="${v#*-}"
    local -a ids
    IFS='.' read -r -a ids <<<"$pre"
    local id
    for id in "${ids[@]}"; do
      if [[ "$id" =~ ^[0-9]+$ ]] && [[ "$id" != "0" ]] && [[ "$id" == 0* ]]; then
        err "invalid SemVer: '$v' (pre-release identifier '$id' has a leading zero)"
        exit 2
      fi
    done
  fi
}

validate_sha256() {
  if ! printf '%s\n' "$1" | grep -qE "$SHA256_RE"; then
    err "invalid SHA-256: '$1'"
    exit 2
  fi
}

# Compare two non-negative, leading-zero-free decimal integer strings by
# numeric value using only string length and lexical (byte-wise) order —
# never Bash arithmetic, so a field of any number of digits (larger than
# fits in a 64-bit word) still compares correctly. Echoes -1, 0, or 1.
_cmp_numeric_str() {
  local a="$1" b="$2"
  if [[ ${#a} -lt ${#b} ]]; then
    echo -1
    return
  fi
  if [[ ${#a} -gt ${#b} ]]; then
    echo 1
    return
  fi
  if [[ "$a" < "$b" ]]; then
    echo -1
    return
  fi
  if [[ "$a" > "$b" ]]; then
    echo 1
    return
  fi
  echo 0
}

# Compare the MAJOR.MINOR.PATCH cores field-by-field. Echoes -1, 0, or 1.
_cmp_core() {
  local -a a_parts b_parts
  IFS='.' read -r -a a_parts <<<"$1"
  IFS='.' read -r -a b_parts <<<"$2"
  local i c
  for i in 0 1 2; do
    c="$(_cmp_numeric_str "${a_parts[$i]}" "${b_parts[$i]}")"
    if [[ "$c" != 0 ]]; then
      echo "$c"
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
  local n=${#a_ids[@]} m=${#b_ids[@]} max i a_id b_id a_num b_num c
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
      c="$(_cmp_numeric_str "$a_id" "$b_id")"
      if [[ "$c" != 0 ]]; then
        echo "$c"
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
  validate)
    validate_semver "${2:-}"
    ;;
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
