#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck disable=SC1091
source "${HERE}/lib/harness.sh"

TESTER="${REPO_ROOT}/scripts/tester.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

"${HERE}/fixtures/make_fake_docker.sh" "${WORK_DIR}/bin"
FAKE_LOG="${WORK_DIR}/docker.log"
FAKE_STATE="${WORK_DIR}/state"
touch "$FAKE_LOG"
mkdir -p "$FAKE_STATE"

# A valid, exact digest reference matching the fake docker fixture's own
# `docker image inspect` output; used as the default FERRITE_TEST_IMAGE for
# every test that is not specifically exercising missing/malformed values.
FAKE_IMAGE="ghcr.io/ferritelabs/ferrite@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

run_tester() {
  env \
    PATH="${WORK_DIR}/bin:${PATH}" \
    FAKE_DOCKER_LOG="$FAKE_LOG" \
    FAKE_DOCKER_STATE="$FAKE_STATE" \
    FERRITE_TEST_POLL_INTERVAL="0.05" \
    FERRITE_TEST_IMAGE="$FAKE_IMAGE" \
    "$@"
}

# Like run_tester, but does not supply any default FERRITE_TEST_IMAGE at all
# (and strips one from the parent environment) so missing-variable behavior
# can be exercised without a test author having to remember to override it.
run_tester_no_image() {
  env -u FERRITE_TEST_IMAGE \
    PATH="${WORK_DIR}/bin:${PATH}" \
    FAKE_DOCKER_LOG="$FAKE_LOG" \
    FAKE_DOCKER_STATE="$FAKE_STATE" \
    FERRITE_TEST_POLL_INTERVAL="0.05" \
    "$@"
}

assert_nonzero() {
  local status="$1" description="$2"
  if [[ "$status" -ne 0 ]]; then
    harness_ok "$description"
  else
    harness_fail "$description"
  fi
}

assert_existing_file() {
  local path="$1" description="$2"
  if [[ -n "$path" && -f "$path" ]]; then
    harness_ok "$description"
  else
    harness_fail "$description"
  fi
}

assert_empty_file() {
  local path="$1" description="$2"
  if [[ ! -s "$path" ]]; then
    harness_ok "$description"
  else
    harness_fail "$description"
  fi
}

# Portable file-mode reader: GNU stat (Linux) uses -c '%a', BSD/macOS stat
# uses -f '%OLp'. Falls back to empty string (assertion will simply fail)
# rather than erroring out on an unsupported platform.
portable_mode() {
  local path="$1"
  stat -c '%a' "$path" 2>/dev/null || stat -f '%OLp' "$path" 2>/dev/null || echo ""
}

assert_true "$(bash -n "$TESTER"; echo $?)" "tester.sh has valid Bash syntax"

# --- FERRITE_TEST_IMAGE validation happens before Docker is called, for
# every failure mode: missing, implicit/floating latest, and malformed. ---

: >"$FAKE_LOG"
OUTPUT="$(run_tester_no_image bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a missing FERRITE_TEST_IMAGE"
assert_contains "$OUTPUT" "FERRITE_TEST_IMAGE is required" "missing-image rejection is actionable"
assert_empty_file "$FAKE_LOG" "missing-image rejection occurs before Docker calls"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite:latest" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects the latest tag"
assert_contains "$OUTPUT" "must never use latest" "latest rejection explains the campaign rule"
assert_empty_file "$FAKE_LOG" "latest rejection occurs before Docker calls"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="latest" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a bare latest value"
assert_contains "$OUTPUT" "must never use latest" "bare latest rejection explains the campaign rule"
assert_empty_file "$FAKE_LOG" "bare latest rejection occurs before Docker calls"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects an implicit latest image"
assert_contains "$OUTPUT" "explicit tag or sha256 digest" "implicit latest rejection requests an exact reference"
assert_empty_file "$FAKE_LOG" "implicit latest rejection occurs before Docker calls"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite@sha256:not-a-real-digest" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a malformed digest"
assert_contains "$OUTPUT" "sha256:<64 hex characters>" "malformed digest rejection explains the required form"
assert_empty_file "$FAKE_LOG" "malformed digest rejection occurs before Docker calls"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite:" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a malformed empty tag"
assert_contains "$OUTPUT" "malformed image tag" "malformed empty tag rejection identifies the tag"
assert_empty_file "$FAKE_LOG" "malformed empty tag rejection occurs before Docker calls"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite:-candidate" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a malformed tag prefix"
assert_contains "$OUTPUT" "malformed image tag" "malformed tag rejection is actionable"
assert_empty_file "$FAKE_LOG" "malformed tag rejection occurs before Docker calls"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs//ferrite:candidate" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a malformed repository path"
assert_contains "$OUTPUT" "malformed repository path" "malformed repository rejection is actionable"
assert_empty_file "$FAKE_LOG" "malformed repository rejection occurs before Docker calls"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a digest without a repository"
assert_contains "$OUTPUT" "repository name before the digest" "missing repository rejection is actionable"
assert_empty_file "$FAKE_LOG" "missing repository rejection occurs before Docker calls"

# Start validates Compose, pulls the exact image, starts only Ferrite, and waits.
: >"$FAKE_LOG"
OUTPUT="$(run_tester bash "$TESTER" start 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_eq 0 "$STATUS" "start succeeds when the fake container is healthy"
assert_contains "$CALLS" "config" "start renders and validates the tester Compose file"
assert_contains "$CALLS" "pull ferrite" "start pulls the configured tester image"
assert_contains "$CALLS" "up -d ferrite" "start starts only the tester service"
assert_contains "$CALLS" "inspect --format" "start checks Docker health status"
assert_contains "$OUTPUT" "Ferrite is healthy" "start reports readiness"

# Health waiting is bounded.
: >"$FAKE_LOG"
OUTPUT="$(run_tester FAKE_HEALTH_STATUS=unhealthy FERRITE_TEST_READY_TIMEOUT=1 bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start fails after the readiness timeout"
assert_contains "$OUTPUT" "did not become healthy within 1s" "health timeout is actionable"

# Smoke covers the requested command families and always cleans temporary keys.
: >"$FAKE_LOG"
OUTPUT="$(run_tester bash "$TESTER" smoke 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_eq 0 "$STATUS" "smoke succeeds with compatible command responses"
for command in PING SET GET HSET HGET RPUSH LINDEX ZADD ZSCORE EXPIRE TTL DEL; do
  assert_contains "$CALLS" " ${command}" "smoke invokes ${command}"
done
assert_contains "$OUTPUT" "temporary keys were removed" "smoke confirms cleanup"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FAKE_FAIL_COMMAND=HGET bash "$TESTER" smoke 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_nonzero "$STATUS" "smoke propagates a command failure"
assert_contains "$CALLS" " DEL " "smoke best-effort cleans keys after a failure via the exit trap"
assert_not_contains "$OUTPUT" "temporary keys were removed" "smoke does not claim cleanup after a command failure"

# Cleanup must be verified, not assumed: a failing DEL on an otherwise
# successful smoke run must fail the whole command and must not claim
# cleanup succeeded.
: >"$FAKE_LOG"
OUTPUT="$(run_tester FAKE_FAIL_COMMAND=DEL bash "$TESTER" smoke 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "smoke fails when DEL itself fails during verified cleanup"
assert_contains "$OUTPUT" "DEL failed while removing" "DEL failure during cleanup is actionable"
assert_not_contains "$OUTPUT" "temporary keys were removed" "smoke does not claim cleanup when DEL fails"

# A DEL that succeeds but reports the wrong count must also fail: a partial
# delete is not a completed cleanup.
: >"$FAKE_LOG"
OUTPUT="$(run_tester FAKE_DEL_COUNT=3 bash "$TESTER" smoke 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "smoke fails when DEL reports the wrong key count"
assert_contains "$OUTPUT" "expected DEL to remove 5 temporary key(s), got 3" "wrong-count cleanup failure names the expected and actual counts"
assert_not_contains "$OUTPUT" "temporary keys were removed" "smoke does not claim cleanup when the DEL count is wrong"

# --- Durability is opt-in and campaign-specific. ---

: >"$FAKE_LOG"
OUTPUT="$(run_tester bash "$TESTER" durability 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "durability refuses to run without FERRITE_TEST_ENABLE_DURABILITY=1"
assert_contains "$OUTPUT" "FERRITE_TEST_ENABLE_DURABILITY=1" "durability gate names the required opt-in variable"
assert_contains "$OUTPUT" "campaign-specific" "durability gate explains it is an optional, campaign-specific diagnostic"
assert_contains "$OUTPUT" "may not persist data across restart" "durability gate explains the current persistence limitation"
assert_empty_file "$FAKE_LOG" "durability gate rejection occurs before Docker calls"

# Durability restarts the service, waits again, verifies, and removes its key,
# once explicitly enabled.
: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_ENABLE_DURABILITY=1 bash "$TESTER" durability 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_eq 0 "$STATUS" "durability succeeds when explicitly enabled and the value survives restart"
assert_contains "$CALLS" "restart ferrite" "durability restarts Ferrite through Compose"
assert_contains "$CALLS" " GET " "durability reads the value after restart"
assert_contains "$CALLS" " DEL " "durability removes its temporary key"
assert_contains "$OUTPUT" "tester volume was preserved" "durability documents volume preservation"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_ENABLE_DURABILITY=1 FAKE_FAIL_COMMAND=DEL bash "$TESTER" durability 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "durability fails when DEL itself fails during verified cleanup"
assert_contains "$OUTPUT" "DEL failed while removing" "durability DEL failure is actionable"
assert_not_contains "$OUTPUT" "tester volume was preserved" "durability does not claim success when cleanup DEL fails"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_ENABLE_DURABILITY=1 FAKE_DEL_COUNT=0 bash "$TESTER" durability 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "durability fails when DEL reports the wrong key count"
assert_contains "$OUTPUT" "expected DEL to remove 1 temporary key(s), got 0" "durability wrong-count cleanup failure names expected and actual counts"

# Diagnostics collect only bounded, reviewable operational data, and are
# written with restrictive, portable file permissions.
: >"$FAKE_LOG"
DIAGNOSTICS_DIR="${WORK_DIR}/diagnostics"
OUTPUT="$(run_tester bash "$TESTER" diagnostics "$DIAGNOSTICS_DIR" 2>&1)"
STATUS=$?
ARCHIVE="$(find "$DIAGNOSTICS_DIR" -type f -name '*.tar.gz' -print -quit)"
assert_eq 0 "$STATUS" "diagnostics succeeds"
assert_existing_file "$ARCHIVE" "diagnostics creates a timestamped tar.gz"
LISTING="$(tar -tzf "$ARCHIVE")"
for file in versions.txt image.txt compose-ps.txt logs.txt info-server.txt info-memory.txt info-persistence.txt info-stats.txt report.md; do
  assert_contains "$LISTING" "/${file}" "diagnostics archive includes ${file}"
done
assert_not_contains "$LISTING" "environment" "diagnostics archive excludes environment dumps"
assert_not_contains "$LISTING" "config" "diagnostics archive excludes full configuration"
assert_contains "$(cat "$FAKE_LOG")" "logs --no-color --tail 500 ferrite" "diagnostic logs are bounded"
assert_contains "$OUTPUT" "Review and redact logs and INFO output" "diagnostics warns the tester before sharing"

ARCHIVE_MODE="$(portable_mode "$ARCHIVE")"
assert_eq "600" "$ARCHIVE_MODE" "diagnostics archive is created with 0600 permissions"

EXTRACT_DIR="${WORK_DIR}/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"
REPORT="$(find "$EXTRACT_DIR" -type f -name report.md -print -quit)"
REPORT_TEXT="$(cat "$REPORT")"
assert_contains "$REPORT_TEXT" "template=tester_report.yml" "report template links the exact tester report form"
assert_contains "$REPORT_TEXT" "excludes environment variables, secrets, full" "report describes intentional exclusions"

# Stop preserves volumes; reset deletes them only after an explicit signal.
: >"$FAKE_LOG"
OUTPUT="$(run_tester bash "$TESTER" stop 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_eq 0 "$STATUS" "stop succeeds"
assert_contains "$CALLS" "down --remove-orphans" "stop removes containers"
assert_not_contains "$CALLS" "--volumes" "stop preserves the named volume"
assert_contains "$OUTPUT" "volume was preserved" "stop clearly states volume behavior"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_RESET_CONFIRM=1 bash "$TESTER" reset 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_eq 0 "$STATUS" "reset supports the CI confirmation bypass"
assert_contains "$CALLS" "down --volumes --remove-orphans" "reset explicitly removes the volume"
assert_contains "$OUTPUT" "permanently deletes" "reset prints a destructive warning"

: >"$FAKE_LOG"
OUTPUT="$(printf 'NO\n' | run_tester bash "$TESTER" reset 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "reset cancels unless RESET is typed"
assert_not_contains "$(cat "$FAKE_LOG")" "down --volumes" "cancelled reset does not delete the volume"

harness_summary
