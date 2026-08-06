#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.tester.yml"
HOST_PROBE="${REPO_ROOT}/scripts/tester-host-probe.py"

# No default: the campaign owner must supply an exact image reference.
# Left unset (rather than defaulted) so validate_image's missing-value check
# below is reachable and every command fails fast, before any Docker call.
export FERRITE_TEST_IMAGE="${FERRITE_TEST_IMAGE:-}"
export FERRITE_TEST_PORT="${FERRITE_TEST_PORT:-6379}"
export FERRITE_TEST_METRICS_PORT="${FERRITE_TEST_METRICS_PORT:-9090}"
export FERRITE_TEST_READY_TIMEOUT="${FERRITE_TEST_READY_TIMEOUT:-60}"
export FERRITE_TEST_PROJECT="${FERRITE_TEST_PROJECT:-ferrite-tester}"

# docker-compose.tester.yml is an implementation detail of this wrapper. The
# guard and profile prevent an accidental direct `docker compose up` from
# exposing the tester service, while image validation remains here.
export FERRITE_TEST_WRAPPER_GUARD="tester.sh"
TESTER_COMPOSE_PROFILE="tester"
OWNERSHIP_LABEL_KEY="com.ferritelabs.tester.wrapper-guard"
OWNERSHIP_LABEL_VALUE="tester.sh"

# Host reachability probe settings. Docker health only proves the in-container
# check passed; these govern the host-side verification that the published
# loopback ports actually answer before `start` claims availability.
FERRITE_TEST_PROBE_TIMEOUT="${FERRITE_TEST_PROBE_TIMEOUT:-5}"
FERRITE_TEST_PROBE_RETRIES="${FERRITE_TEST_PROBE_RETRIES:-5}"

# Internal overrides used by dependency-free tests to avoid one-second sleeps
# and to exercise the missing-interpreter path without mutating PATH.
FERRITE_TEST_POLL_INTERVAL="${FERRITE_TEST_POLL_INTERVAL:-1}"
FERRITE_TEST_PYTHON="${FERRITE_TEST_PYTHON:-python3}"

# Compose expands the required image even for `down`. Teardown commands use
# this internal placeholder solely to let Compose parse the model; no command
# that can pull or start a service is allowed to use it.
TEARDOWN_DUMMY_IMAGE="ferrite.invalid/teardown-only@sha256:0000000000000000000000000000000000000000000000000000000000000000"

CLEANUP_KEYS=()
DIAGNOSTICS_TMP=""
PROJECT_LOCK_DIR=""
PROJECT_LOCK_OWNER_PID=""
PROJECT_OWNERSHIP_REVALIDATION_PENDING=0

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
  FERRITE_TEST_IMAGE           Exact repository-qualified sha256 digest reference
                               (repository/path@sha256:<64 lowercase hex
                               characters>); required except for stop/reset,
                               no default, never a tag or latest
  FERRITE_TEST_PORT            Host Redis-compatible port (default: 6379)
  FERRITE_TEST_METRICS_PORT    Host metrics port (default: 9090)
  FERRITE_TEST_READY_TIMEOUT   Health wait in seconds (default: 60)
  FERRITE_TEST_PROBE_TIMEOUT   Host reachability probe timeout in seconds
                               (default: 5)
  FERRITE_TEST_PROBE_RETRIES   Extra host reachability probe attempts after a
                               failure (default: 5)
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
  local lower reference digest segment

  [[ -n "$image" ]] ||
    die "FERRITE_TEST_IMAGE is required; set it to the exact repository-qualified sha256 digest (repository/path@sha256:<64 lowercase hex characters>); never a tag or latest. There is no default."

  [[ "$image" != *[[:space:]]* ]] ||
    die "FERRITE_TEST_IMAGE must be one exact image reference"
  [[ "$image" != *"://"* ]] ||
    die "FERRITE_TEST_IMAGE must be an image reference without a URL scheme"

  lower="$(printf '%s' "$image" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == "latest" || "$lower" == *":latest" ]]; then
    die "FERRITE_TEST_IMAGE must never use latest; use the exact repository-qualified sha256 digest"
  fi

  # Only a digest reference is accepted: a bare tag, an implicit-latest
  # reference, or a tag alongside a digest are all rejected before any
  # Docker call.
  [[ "$image" == *"@"* ]] ||
    die "FERRITE_TEST_IMAGE must be a repository-qualified sha256 digest reference (repository/path@sha256:<64 lowercase hex characters>); tags are never accepted"

  [[ "$image" != *@*@* ]] ||
    die "FERRITE_TEST_IMAGE contains more than one digest separator"

  reference="${image%@*}"
  digest="${image##*@}"

  [[ -n "$reference" ]] ||
    die "FERRITE_TEST_IMAGE must include a repository name before the digest"

  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "image digests must use the full lowercase sha256:<64 lowercase hex characters> form"

  [[ "$reference" != /* && "$reference" != */ && "$reference" != *"//"* ]] ||
    die "FERRITE_TEST_IMAGE contains a malformed repository path"

  IFS='/' read -r -a image_segments <<<"$reference"
  ((${#image_segments[@]} > 1)) ||
    die "FERRITE_TEST_IMAGE must include a repository name (e.g. ghcr.io/ferritelabs/ferrite), not a bare image name"
  for index in "${!image_segments[@]}"; do
    segment="${image_segments[$index]}"
    if ((index == 0)); then
      [[ "$segment" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(:[0-9]+)?$ ]] ||
        die "FERRITE_TEST_IMAGE contains a malformed registry host"
    else
      [[ "$segment" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] ||
        die "FERRITE_TEST_IMAGE must not combine a tag with a digest; use repository/path@sha256:<digest> only"
    fi
  done
}

validate_settings() {
  validate_image
  validate_uint_range "FERRITE_TEST_PORT" "$FERRITE_TEST_PORT" 1 65535
  validate_uint_range "FERRITE_TEST_METRICS_PORT" "$FERRITE_TEST_METRICS_PORT" 1 65535
  validate_uint_range "FERRITE_TEST_READY_TIMEOUT" "$FERRITE_TEST_READY_TIMEOUT" 1 86400
  validate_uint_range "FERRITE_TEST_PROBE_TIMEOUT" "$FERRITE_TEST_PROBE_TIMEOUT" 1 300
  validate_uint_range "FERRITE_TEST_PROBE_RETRIES" "$FERRITE_TEST_PROBE_RETRIES" 0 60
  validate_project
}

validate_project() {
  [[ "$FERRITE_TEST_PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
    die "FERRITE_TEST_PROJECT must match [a-z0-9][a-z0-9_-]*"
}

process_is_alive() {
  local pid="$1" observed_pid

  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  # kill -0 can fail for an existing process owned by another user. ps
  # distinguishes that case from a PID that is no longer present.
  observed_pid="$(ps -p "$pid" -o pid= 2>/dev/null || true)"
  observed_pid="${observed_pid//[[:space:]]/}"
  [[ "$observed_pid" == "$pid" ]]
}

acquire_project_lock() {
  local lock_root lock_dir pid_file owner_pid process_id

  validate_project
  lock_root="${TMPDIR:-/tmp}"
  [[ -d "$lock_root" && -w "$lock_root" ]] ||
    die "TMPDIR '${lock_root}' must be an existing writable directory"

  lock_dir="${lock_root%/}/ferrite-tester-${FERRITE_TEST_PROJECT}.lock"
  [[ -n "${lock_root%/}" ]] ||
    lock_dir="/ferrite-tester-${FERRITE_TEST_PROJECT}.lock"
  pid_file="${lock_dir}/pid"
  process_id="${BASHPID:-$$}"

  while true; do
    if (umask 077 && mkdir "$lock_dir") 2>/dev/null; then
      if ! (umask 077 && printf '%s\n' "$process_id" >"$pid_file"); then
        rmdir "$lock_dir" 2>/dev/null || true
        die "could not record PID ownership for project lock '${lock_dir}'"
      fi
      if ! chmod 700 "$lock_dir" || ! chmod 600 "$pid_file"; then
        rm -f "$pid_file"
        rmdir "$lock_dir" 2>/dev/null || true
        die "could not apply restrictive permissions to project lock '${lock_dir}'"
      fi

      PROJECT_LOCK_DIR="$lock_dir"
      PROJECT_LOCK_OWNER_PID="$process_id"
      return 0
    fi

    [[ -d "$lock_dir" ]] ||
      die "could not create project lock '${lock_dir}'"

    owner_pid=""
    if [[ -f "$pid_file" ]]; then
      IFS= read -r owner_pid <"$pid_file" || owner_pid=""
    fi
    [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] ||
      die "project lock '${lock_dir}' has no valid recorded owner PID; refusing stale-lock recovery"

    if process_is_alive "$owner_pid"; then
      die "Compose project '${FERRITE_TEST_PROJECT}' is locked by active process PID ${owner_pid}; wait for it to finish"
    fi

    # Removing the PID file is the recovery claim. Only the process that
    # successfully removes that exact dead-owner record may remove the now
    # empty lock directory; concurrent recoverers fail closed.
    if rm "$pid_file" 2>/dev/null; then
      if ! rmdir "$lock_dir" 2>/dev/null; then
        (umask 077 && printf '%s\n' "$owner_pid" >"$pid_file") || true
        die "stale project lock '${lock_dir}' contains unexpected entries; refusing recovery"
      fi
      echo "Recovered stale project lock for '${FERRITE_TEST_PROJECT}' from PID ${owner_pid}." >&2
      continue
    fi

    [[ ! -e "$lock_dir" ]] ||
      die "project lock '${lock_dir}' changed during stale-lock recovery; retry the command"
  done
}

release_project_lock() {
  local process_id recorded_pid

  [[ -n "$PROJECT_LOCK_DIR" && -n "$PROJECT_LOCK_OWNER_PID" ]] || return 0
  process_id="${BASHPID:-$$}"
  [[ "$process_id" == "$PROJECT_LOCK_OWNER_PID" ]] || return 0

  recorded_pid=""
  if [[ -f "${PROJECT_LOCK_DIR}/pid" ]]; then
    IFS= read -r recorded_pid <"${PROJECT_LOCK_DIR}/pid" || recorded_pid=""
  fi
  [[ "$recorded_pid" == "$PROJECT_LOCK_OWNER_PID" ]] || return 0

  if rm "${PROJECT_LOCK_DIR}/pid" 2>/dev/null; then
    if ! rmdir "$PROJECT_LOCK_DIR" 2>/dev/null; then
      (umask 077 && printf '%s\n' "$PROJECT_LOCK_OWNER_PID" >"${PROJECT_LOCK_DIR}/pid") ||
        true
    fi
  fi
  PROJECT_LOCK_DIR=""
  PROJECT_LOCK_OWNER_PID=""
}

require_compose() {
  command -v docker >/dev/null 2>&1 ||
    die "Docker is required; install Docker Engine or Docker Desktop"
  docker compose version >/dev/null 2>&1 ||
    die "Docker Compose v2 is required ('docker compose')"
}

require_python() {
  command -v "$FERRITE_TEST_PYTHON" >/dev/null 2>&1 ||
    die "Python 3 is required to verify host reachability ('${FERRITE_TEST_PYTHON}' was not found); install Python 3 and rerun"
  "$FERRITE_TEST_PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1 ||
    die "'${FERRITE_TEST_PYTHON}' is not a working Python 3 interpreter; install Python 3 and rerun"
}

# Docker reporting the container healthy only proves the in-container
# healthcheck passed. Before telling a tester the deployment is available on
# localhost, verify from the host that the published loopback ports actually
# answer: RESP PING must return +PONG and GET /metrics must return 2xx with a
# non-empty body. The probe is standard-library Python 3 only and every
# timeout it uses is bounded.
verify_host_reachability() {
  [[ -f "$HOST_PROBE" ]] ||
    die "host reachability probe is missing at ${HOST_PROBE}; the checkout is incomplete, re-clone ferrite-ops at the campaign commit"

  "$FERRITE_TEST_PYTHON" -I "$HOST_PROBE" \
    --host 127.0.0.1 \
    --port "$FERRITE_TEST_PORT" \
    --metrics-port "$FERRITE_TEST_METRICS_PORT" \
    --timeout "$FERRITE_TEST_PROBE_TIMEOUT" \
    --retries "$FERRITE_TEST_PROBE_RETRIES" ||
    die "Ferrite is NOT reachable from this host (see the probe error above); do not begin a tester session until it is"
}

# The exact ferrite-ops commit this tooling is running from. Diagnostics are
# provenance records, so attribution is accepted only from a detached, clean
# Git worktree. Untracked files under the tester tooling paths are included:
# Python imports and Compose/script behavior can be changed by such files.
ops_tooling_commit() {
  local commit worktree_status tooling_status
  command -v git >/dev/null 2>&1 ||
    die "git is required so diagnostics can record the exact ferrite-ops tooling commit; install git and rerun"

  [[ "$(git -C "$REPO_ROOT" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]] ||
    die "ferrite-ops tooling provenance requires a Git worktree; run diagnostics from a detached checkout of the campaign commit"

  if git -C "$REPO_ROOT" symbolic-ref -q HEAD >/dev/null 2>&1; then
    die "ferrite-ops tooling provenance requires detached HEAD; run 'git -C ${REPO_ROOT} checkout --detach <CAMPAIGN_OPS_COMMIT>' before diagnostics"
  fi

  commit="$(git -C "$REPO_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] ||
    die "could not determine a full 40-character ferrite-ops tooling commit via 'git -C ${REPO_ROOT} rev-parse --verify HEAD^{commit}'; check out the campaign commit by its full SHA"

  worktree_status="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ||
    die "could not verify that the ferrite-ops tooling checkout is clean"
  [[ -z "$worktree_status" ]] ||
    die "ferrite-ops tooling has tracked staged or unstaged modifications; restore the checkout before diagnostics"

  tooling_status="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- scripts docker-compose.tester.yml 2>/dev/null)" ||
    die "could not verify the ferrite-ops tester tooling paths"
  [[ -z "$tooling_status" ]] ||
    die "ferrite-ops tester tooling paths contain untracked or modified files; restore the campaign checkout before diagnostics"

  printf '%s\n' "$commit"
}

compose() {
  docker compose \
    --project-name "$FERRITE_TEST_PROJECT" \
    --file "$COMPOSE_FILE" \
    --profile "$TESTER_COMPOSE_PROFILE" \
    "$@"
}

compose_teardown() {
  FERRITE_TEST_IMAGE="$TEARDOWN_DUMMY_IMAGE" compose "$@"
}

ownership_collision() {
  local resource_type="$1" resource_name="$2" actual_label="$3"
  [[ -n "$actual_label" ]] || actual_label="<missing>"
  die "${resource_type} '${resource_name}' collides with Compose project '${FERRITE_TEST_PROJECT}': expected ownership label '${OWNERSHIP_LABEL_KEY}=${OWNERSHIP_LABEL_VALUE}', found '${actual_label}'. Change FERRITE_TEST_PROJECT to use a different isolated project name."
}

verify_named_resource_ownership() {
  local resource_type="$1" resource_name="$2"
  local names label found
  found=0

  names="$(
    docker "$resource_type" ls \
      --filter "name=${resource_name}" \
      --format '{{.Name}}'
  )" || die "could not list Docker ${resource_type} resources while verifying project ownership"

  while IFS= read -r name; do
    if [[ "$name" == "$resource_name" ]]; then
      found=1
      break
    fi
  done <<<"$names"

  ((found == 1)) || return 0

  label="$(
    docker "$resource_type" inspect \
      --format '{{index .Labels "com.ferritelabs.tester.wrapper-guard"}}' \
      "$resource_name" 2>/dev/null
  )" || die "could not inspect Docker ${resource_type} '${resource_name}' while verifying project ownership"

  [[ "$label" == "$OWNERSHIP_LABEL_VALUE" ]] ||
    ownership_collision "Docker ${resource_type}" "$resource_name" "$label"
}

verify_project_ownership() {
  local container_ids container_id label
  local volume_name="${FERRITE_TEST_PROJECT}_ferrite-tester-data"
  local network_name="${FERRITE_TEST_PROJECT}_default"

  container_ids="$(
    docker container ls --all --quiet \
      --filter "label=com.docker.compose.project=${FERRITE_TEST_PROJECT}" \
      --filter "label=com.docker.compose.service=ferrite"
  )" || die "could not list existing Docker containers while verifying project ownership"

  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    label="$(
      docker container inspect \
        --format '{{index .Config.Labels "com.ferritelabs.tester.wrapper-guard"}}' \
        "$container_id" 2>/dev/null
    )" || die "could not inspect Docker container '${container_id}' while verifying project ownership"

    [[ "$label" == "$OWNERSHIP_LABEL_VALUE" ]] ||
      ownership_collision "Docker container" "$container_id" "$label"
  done <<<"$container_ids"

  verify_named_resource_ownership volume "$volume_name"
  verify_named_resource_ownership network "$network_name"
}

revalidate_project_ownership() {
  # Leave this set if verification exits through die(). The EXIT cleanup must
  # not issue a best-effort mutating CLI call after ownership became unsafe.
  PROJECT_OWNERSHIP_REVALIDATION_PENDING=1
  verify_project_ownership
  PROJECT_OWNERSHIP_REVALIDATION_PENDING=0
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

# Confirms the currently running tester container is actually running the
# requested FERRITE_TEST_IMAGE, not a stale container left over from a prior
# session with a different image. Called after `start` becomes healthy and
# again before every command that talks to the container (smoke, durability,
# diagnostics), before any `compose exec`/CLI call.
verify_running_image() {
  local id running_image
  id="$(container_id)"
  [[ -n "$id" ]] ||
    die "No running tester container was found; run './scripts/tester.sh start' first"

  running_image="$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null || true)"
  [[ -n "$running_image" ]] ||
    die "Could not determine the running container's image; run './scripts/tester.sh start' first"

  [[ "$running_image" == "$FERRITE_TEST_IMAGE" ]] ||
    die "Running container image '${running_image}' does not match FERRITE_TEST_IMAGE '${FERRITE_TEST_IMAGE}'; run './scripts/tester.sh stop' then 'start' with the intended image"
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
  if ((PROJECT_OWNERSHIP_REVALIDATION_PENDING == 1)); then
    CLEANUP_KEYS=()
    return 0
  fi
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
  release_project_lock
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
  require_python
  require_compose
  verify_project_ownership
  validate_compose
  echo "Starting ${FERRITE_TEST_PROJECT} with ${FERRITE_TEST_IMAGE}"
  compose pull ferrite
  revalidate_project_ownership
  compose up -d ferrite
  wait_for_health
  verify_running_image
  verify_host_reachability
  echo "Ferrite is available on localhost:${FERRITE_TEST_PORT}; metrics: localhost:${FERRITE_TEST_METRICS_PORT}"
}

run_smoke() {
  local prefix value ttl zscore
  validate_settings
  require_compose
  verify_project_ownership
  verify_running_image
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
  verify_project_ownership
  verify_running_image
  key="ferrite:tester:durability:$(date -u +%Y%m%dT%H%M%SZ):$$:${RANDOM}"
  value="durable-${RANDOM}-$$"
  CLEANUP_KEYS=("$key")

  expect_json '"OK"' "durability SET" SET "$key" "$value"
  revalidate_project_ownership
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
  local timestamp bundle_name bundle archive id ops_commit
  local previous_umask

  ops_commit="$(ops_tooling_commit)"
  validate_settings
  require_compose
  verify_project_ownership
  verify_running_image
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
    echo "ferrite-ops tooling commit: ${ops_commit}"
    docker --version 2>&1 || true
    docker compose version 2>&1 || true
    compose exec -T ferrite ferrite-cli --version 2>&1 || true
  } >"${bundle}/versions.txt"

  {
    echo "ferrite-ops tooling commit: ${ops_commit}"
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
- Version and exact image digest: \`${FERRITE_TEST_IMAGE}\`
- ferrite-ops tooling commit (CAMPAIGN_OPS_COMMIT): \`${ops_commit}\`
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
  validate_project
  require_compose
  revalidate_project_ownership
  compose_teardown down
  echo "Tester containers removed; the named data volume was preserved."
}

reset_environment() {
  local reply
  validate_project
  require_compose
  verify_project_ownership
  echo "WARNING: reset permanently deletes the ${FERRITE_TEST_PROJECT} tester data volume." >&2
  if [[ "${FERRITE_TEST_RESET_CONFIRM:-}" != "1" ]]; then
    printf "Type RESET to continue: " >&2
    read -r reply || die "reset cancelled"
    [[ "$reply" == "RESET" ]] || die "reset cancelled"
  fi
  revalidate_project_ownership
  compose_teardown down --volumes
  echo "Tester containers and data volume removed."
}

main() {
  local command="${1:-}"
  case "$command" in
    start)
      [[ $# -eq 1 ]] || die "start takes no arguments"
      acquire_project_lock
      start_environment
      ;;
    smoke)
      [[ $# -eq 1 ]] || die "smoke takes no arguments"
      acquire_project_lock
      run_smoke
      ;;
    durability)
      [[ $# -eq 1 ]] || die "durability takes no arguments"
      acquire_project_lock
      run_durability
      ;;
    diagnostics)
      [[ $# -le 2 ]] || die "diagnostics accepts at most one output directory"
      acquire_project_lock
      collect_diagnostics "${2:-}"
      ;;
    stop)
      [[ $# -eq 1 ]] || die "stop takes no arguments"
      acquire_project_lock
      stop_environment
      ;;
    reset)
      [[ $# -eq 1 ]] || die "reset takes no arguments"
      acquire_project_lock
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
