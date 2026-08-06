#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.tester.yml"

# No default: the campaign owner must supply an exact image reference.
# Left unset (rather than defaulted) so validate_image's missing-value check
# below is reachable and every command fails fast, before any Docker call.
export FERRITE_TEST_IMAGE="${FERRITE_TEST_IMAGE:-}"
export FERRITE_TEST_PORT="${FERRITE_TEST_PORT:-6379}"
export FERRITE_TEST_METRICS_PORT="${FERRITE_TEST_METRICS_PORT:-9090}"
export FERRITE_TEST_READY_TIMEOUT="${FERRITE_TEST_READY_TIMEOUT:-60}"
export FERRITE_TEST_PROJECT="${FERRITE_TEST_PROJECT:-ferrite-tester}"

# Internal override used by dependency-free tests to avoid one-second sleeps.
FERRITE_TEST_POLL_INTERVAL="${FERRITE_TEST_POLL_INTERVAL:-1}"

CLEANUP_KEYS=()
DIAGNOSTICS_TMP=""

die() {
  echo "${SCRIPT_NAME}: error: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: ./scripts/tester.sh <command> [arguments]

Commands:
  start                    Validate and start the isolated tester environment
  smoke                    Run core Redis-compatible command checks
  durability               Verify a value survives a controlled restart
                           (optional; requires FERRITE_TEST_ENABLE_DURABILITY=1)
  diagnostics [output-dir] Create a redaction-conscious diagnostic archive
  stop                     Remove containers and preserve the tester volume
  reset                    Destructively remove containers and tester volume

Environment:
  FERRITE_TEST_IMAGE           Exact campaign image tag or digest; required, no
                               default, never latest
  FERRITE_TEST_PORT            Host Redis-compatible port (default: 6379)
  FERRITE_TEST_METRICS_PORT    Host metrics port (default: 9090)
  FERRITE_TEST_READY_TIMEOUT   Health wait in seconds (default: 60)
  FERRITE_TEST_PROJECT         Isolated Compose project (default: ferrite-tester)
  FERRITE_TEST_RESET_CONFIRM   Set to 1 to bypass reset confirmation in CI
  FERRITE_TEST_ENABLE_DURABILITY
                               Must be set to 1 to run `durability`; it is an
                               optional, campaign-specific diagnostic track,
                               not part of the required core tester path
USAGE
}

validate_uint_range() {
  local name="$1" value="$2" minimum="$3" maximum="$4"
  if [[ ! "$value" =~ ^[0-9]+$ ]] ||
     ((10#$value < minimum || 10#$value > maximum)); then
    die "${name} must be an integer between ${minimum} and ${maximum}; got '${value}'"
  fi
}

validate_image() {
  local image="${FERRITE_TEST_IMAGE:-}"
  local lower leaf digest reference name tag segment

  [[ -n "$image" ]] ||
    die "FERRITE_TEST_IMAGE is required; set it to the exact campaign image tag or digest (never latest). There is no default."

  [[ "$image" != *[[:space:]]* ]] ||
    die "FERRITE_TEST_IMAGE must be one exact image reference"
  [[ "$image" != *"://"* ]] ||
    die "FERRITE_TEST_IMAGE must be an image reference without a URL scheme"

  lower="$(printf '%s' "$image" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == "latest" || "$lower" == *":latest" ]]; then
    die "FERRITE_TEST_IMAGE must never use latest; use the campaign tag or digest"
  fi

  reference="$image"
  if [[ "$image" == *"@"* ]]; then
    [[ "$image" != *@*@* ]] ||
      die "FERRITE_TEST_IMAGE contains more than one digest separator"
    reference="${image%@*}"
    digest="${image##*@}"
    [[ -n "$reference" ]] ||
      die "FERRITE_TEST_IMAGE must include a repository name before the digest"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
      die "image digests must use the full lowercase sha256:<64 lowercase hex characters> form"
  fi

  [[ "$reference" != /* && "$reference" != */ && "$reference" != *"//"* ]] ||
    die "FERRITE_TEST_IMAGE contains a malformed repository path"

  leaf="${reference##*/}"
  name="$reference"
  if [[ "$leaf" == *":"* ]]; then
    tag="${leaf##*:}"
    name="${reference%:*}"
    [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
      die "FERRITE_TEST_IMAGE contains a malformed image tag"
  elif [[ "$image" != *"@"* ]]; then
    die "FERRITE_TEST_IMAGE must include an explicit tag or sha256 digest"
  fi

  IFS='/' read -r -a image_segments <<<"$name"
  ((${#image_segments[@]} > 0)) ||
    die "FERRITE_TEST_IMAGE must include a repository name"
  for segment in "${image_segments[@]}"; do
    [[ "$segment" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(:[0-9]+)?$ ]] ||
      die "FERRITE_TEST_IMAGE contains a malformed repository path"
  done

  if [[ "$image" != *"@"* ]]; then
    leaf="${image##*/}"
    [[ "$leaf" == *":"* && -n "${leaf##*:}" ]] ||
      die "FERRITE_TEST_IMAGE must include an explicit tag or sha256 digest"
  fi
}

validate_settings() {
  validate_image
  validate_uint_range "FERRITE_TEST_PORT" "$FERRITE_TEST_PORT" 1 65535
  validate_uint_range "FERRITE_TEST_METRICS_PORT" "$FERRITE_TEST_METRICS_PORT" 1 65535
  validate_uint_range "FERRITE_TEST_READY_TIMEOUT" "$FERRITE_TEST_READY_TIMEOUT" 1 86400
  [[ "$FERRITE_TEST_PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
    die "FERRITE_TEST_PROJECT must match [a-z0-9][a-z0-9_-]*"
}

require_compose() {
  command -v docker >/dev/null 2>&1 ||
    die "Docker is required; install Docker Engine or Docker Desktop"
  docker compose version >/dev/null 2>&1 ||
    die "Docker Compose v2 is required ('docker compose')"
}

compose() {
  docker compose \
    --project-name "$FERRITE_TEST_PROJECT" \
    --file "$COMPOSE_FILE" \
    "$@"
}

validate_compose() {
  compose config >/dev/null
}

container_id() {
  compose ps -q ferrite | sed -n '1p'
}

wait_for_health() {
  local deadline status id
  deadline=$((SECONDS + FERRITE_TEST_READY_TIMEOUT))

  while true; do
    id="$(container_id)"
    if [[ -n "$id" ]]; then
      status="$(docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$id" 2>/dev/null || true)"
      case "$status" in
        healthy)
          echo "Ferrite is healthy."
          return 0
          ;;
        exited | dead)
          die "Ferrite container entered state '${status}' before becoming healthy"
          ;;
      esac
    fi

    if ((SECONDS >= deadline)); then
      compose ps --all || true
      die "Ferrite did not become healthy within ${FERRITE_TEST_READY_TIMEOUT}s"
    fi
    sleep "$FERRITE_TEST_POLL_INTERVAL"
  done
}

cli_json() {
  compose exec -T ferrite ferrite-cli --format json "$@"
}

cli_raw() {
  compose exec -T ferrite ferrite-cli "$@"
}

# Best-effort cleanup used only by the EXIT trap: it must never itself fail
# or mask the script's real exit status (e.g. during an error unwind where
# the container is already gone), so it swallows DEL errors.
cleanup_keys_best_effort() {
  if ((${#CLEANUP_KEYS[@]} > 0)); then
    cli_raw DEL "${CLEANUP_KEYS[@]}" >/dev/null 2>&1 || true
    CLEANUP_KEYS=()
  fi
}

# Verified cleanup used on the success path of smoke/durability: a command
# may only claim "temporary keys were removed" after DEL both succeeds and
# reports removing exactly the number of keys requested. A silent partial
# delete (e.g. a key already expired, or a server-side error swallowed by a
# less strict check) must be surfaced as a failure, not a quiet pass.
cleanup_keys_verified() {
  local description="$1" expected output
  expected=${#CLEANUP_KEYS[@]}
  ((expected > 0)) || return 0

  output="$(cli_json DEL "${CLEANUP_KEYS[@]}" | tr -d '\r')" ||
    die "${description}: DEL failed while removing ${expected} temporary key(s); cleanup could not be confirmed"
  [[ "$output" == "$expected" ]] ||
    die "${description}: expected DEL to remove ${expected} temporary key(s), got ${output}; cleanup could not be confirmed"

  CLEANUP_KEYS=()
}

cleanup_on_exit() {
  cleanup_keys_best_effort
  if [[ -n "$DIAGNOSTICS_TMP" && -d "$DIAGNOSTICS_TMP" ]]; then
    rm -rf "$DIAGNOSTICS_TMP"
  fi
}
trap cleanup_on_exit EXIT

expect_json() {
  local expected="$1" description="$2"
  shift 2
  local output
  output="$(cli_json "$@" | tr -d '\r')" ||
    die "${description} command failed"
  [[ "$output" == "$expected" ]] ||
    die "${description} failed: expected ${expected}, got ${output}"
}

start_environment() {
  validate_settings
  require_compose
  validate_compose
  echo "Starting ${FERRITE_TEST_PROJECT} with ${FERRITE_TEST_IMAGE}"
  compose pull ferrite
  compose up -d ferrite
  wait_for_health
  echo "Ferrite is available on localhost:${FERRITE_TEST_PORT}; metrics: localhost:${FERRITE_TEST_METRICS_PORT}"
}

run_smoke() {
  local prefix value ttl zscore
  validate_settings
  require_compose
  prefix="ferrite:tester:smoke:$(date -u +%Y%m%dT%H%M%SZ):$$:${RANDOM}"
  value="value-${RANDOM}-$$"
  CLEANUP_KEYS=(
    "${prefix}:string"
    "${prefix}:hash"
    "${prefix}:list"
    "${prefix}:zset"
    "${prefix}:ttl"
  )

  expect_json '"PONG"' "PING" PING
  expect_json '"OK"' "SET" SET "${prefix}:string" "$value"
  expect_json "\"${value}\"" "GET" GET "${prefix}:string"
  expect_json "1" "HSET" HSET "${prefix}:hash" field "$value"
  expect_json "\"${value}\"" "HGET" HGET "${prefix}:hash" field
  expect_json "2" "RPUSH" RPUSH "${prefix}:list" alpha beta
  expect_json '"alpha"' "LINDEX 0" LINDEX "${prefix}:list" 0
  expect_json '"beta"' "LINDEX 1" LINDEX "${prefix}:list" 1
  expect_json "1" "ZADD" ZADD "${prefix}:zset" 42 member
  zscore="$(cli_json ZSCORE "${prefix}:zset" member | tr -d '\r')"
  [[ "$zscore" == '"42"' || "$zscore" == '"42.0"' ]] ||
    die "ZSCORE failed: expected \"42\", got ${zscore}"
  expect_json '"OK"' "TTL SET" SET "${prefix}:ttl" temporary
  expect_json "1" "EXPIRE" EXPIRE "${prefix}:ttl" 30
  ttl="$(cli_json TTL "${prefix}:ttl" | tr -d '\r')"
  if [[ ! "$ttl" =~ ^[0-9]+$ ]] || ((ttl <= 0 || ttl > 30)); then
    die "TTL failed: expected 1..30, got ${ttl}"
  fi

  cleanup_keys_verified "smoke"
  echo "Smoke checks passed and temporary keys were removed."
}

run_durability() {
  local key value actual

  # Durability is an optional, campaign-specific diagnostic track, not part
  # of the required core tester path; it must be explicitly opted into by
  # the campaign owner before it runs.
  [[ "${FERRITE_TEST_ENABLE_DURABILITY:-}" == "1" ]] ||
    die "durability is an optional, campaign-specific diagnostic because current candidate images may not persist data across restart; set FERRITE_TEST_ENABLE_DURABILITY=1 only if the campaign owner has explicitly enabled this track. It is not part of the required core tester path."

  validate_settings
  require_compose
  key="ferrite:tester:durability:$(date -u +%Y%m%dT%H%M%SZ):$$:${RANDOM}"
  value="durable-${RANDOM}-$$"
  CLEANUP_KEYS=("$key")

  expect_json '"OK"' "durability SET" SET "$key" "$value"
  compose restart ferrite
  wait_for_health
  actual="$(cli_json GET "$key" | tr -d '\r')"
  [[ "$actual" == "\"${value}\"" ]] ||
    die "durability check failed: value did not survive restart"

  cleanup_keys_verified "durability"
  echo "Durability check passed; the tester volume was preserved."
}

collect_command() {
  local destination="$1"
  shift
  if "$@" >"$destination" 2>&1; then
    return 0
  fi
  echo "Collection command failed; see output above." >>"$destination"
  return 0
}

collect_diagnostics() {
  local output_dir="${1:-${PWD}/tester-diagnostics}"
  local timestamp bundle_name bundle archive id
  local previous_umask

  validate_settings
  require_compose
  command -v tar >/dev/null 2>&1 || die "tar is required to create diagnostics"

  # Diagnostics can contain operationally sensitive data (client addresses,
  # keys, or values that leak into logs/INFO output; see report.md below).
  # Restrict every file and directory created in this function to the
  # current user via umask, and belt-and-suspenders chmod the final archive
  # explicitly so its permissions don't depend on umask alone.
  previous_umask="$(umask)"
  umask 077

  mkdir -p "$output_dir"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  bundle_name="ferrite-tester-diagnostics-${timestamp}-$$"
  DIAGNOSTICS_TMP="$(mktemp -d)"
  bundle="${DIAGNOSTICS_TMP}/${bundle_name}"
  archive="${output_dir%/}/${bundle_name}.tar.gz"
  mkdir -p "$bundle"
  id="$(container_id)"

  {
    echo "tester.sh diagnostics format: 1"
    docker --version 2>&1 || true
    docker compose version 2>&1 || true
    compose exec -T ferrite ferrite-cli --version 2>&1 || true
  } >"${bundle}/versions.txt"

  {
    echo "Requested image: ${FERRITE_TEST_IMAGE}"
    if [[ -n "$id" ]]; then
      echo "Container image ID:"
      docker inspect --format '{{.Image}}' "$id" 2>&1 || true
    fi
    echo "Repository digests:"
    docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
      "$FERRITE_TEST_IMAGE" 2>&1 || true
  } >"${bundle}/image.txt"

  collect_command "${bundle}/compose-ps.txt" compose ps --all
  collect_command "${bundle}/logs.txt" compose logs --no-color --tail 500 ferrite
  collect_command "${bundle}/info-server.txt" cli_raw INFO server
  collect_command "${bundle}/info-memory.txt" cli_raw INFO memory
  collect_command "${bundle}/info-persistence.txt" cli_raw INFO persistence
  collect_command "${bundle}/info-stats.txt" cli_raw INFO stats

  cat >"${bundle}/report.md" <<REPORT
# Ferrite external tester report

Submit at: https://github.com/ferritelabs/ferrite/issues/new?template=tester_report.yml

- Track completed:
- Highest severity observed:
- Version and exact image tag or digest: \`${FERRITE_TEST_IMAGE}\`
- Install method: ferrite-ops tester Docker Compose
- Environment:
- Redis client or application:
- Steps performed:
- Expected behavior:
- Actual behavior:
- Reproducibility:
- Regression:

## Diagnostic review

This archive intentionally excludes environment variables, secrets, full
configuration, and database contents. **Review and redact logs and INFO output
before sharing** because application keys, values, addresses, or identifying
details can still appear there.
REPORT

  tar -czf "$archive" -C "$DIAGNOSTICS_TMP" "$bundle_name"
  chmod 600 "$archive"
  rm -rf "$DIAGNOSTICS_TMP"
  DIAGNOSTICS_TMP=""
  umask "$previous_umask"

  echo "Diagnostics archive: ${archive}"
  echo "Review and redact logs and INFO output before sharing."
}

stop_environment() {
  validate_settings
  require_compose
  compose down --remove-orphans
  echo "Tester containers removed; the named data volume was preserved."
}

reset_environment() {
  local reply
  validate_settings
  require_compose
  echo "WARNING: reset permanently deletes the ${FERRITE_TEST_PROJECT} tester data volume." >&2
  if [[ "${FERRITE_TEST_RESET_CONFIRM:-}" != "1" ]]; then
    printf "Type RESET to continue: " >&2
    read -r reply || die "reset cancelled"
    [[ "$reply" == "RESET" ]] || die "reset cancelled"
  fi
  compose down --volumes --remove-orphans
  echo "Tester containers and data volume removed."
}

main() {
  local command="${1:-}"
  case "$command" in
    start)
      [[ $# -eq 1 ]] || die "start takes no arguments"
      start_environment
      ;;
    smoke)
      [[ $# -eq 1 ]] || die "smoke takes no arguments"
      run_smoke
      ;;
    durability)
      [[ $# -eq 1 ]] || die "durability takes no arguments"
      run_durability
      ;;
    diagnostics)
      [[ $# -le 2 ]] || die "diagnostics accepts at most one output directory"
      collect_diagnostics "${2:-}"
      ;;
    stop)
      [[ $# -eq 1 ]] || die "stop takes no arguments"
      stop_environment
      ;;
    reset)
      [[ $# -eq 1 ]] || die "reset takes no arguments"
      reset_environment
      ;;
    -h | --help | help)
      usage
      ;;
    "")
      usage >&2
      exit 1
      ;;
    *)
      die "unknown command '${command}' (use --help)"
      ;;
  esac
}

main "$@"
