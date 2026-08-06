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

run_tester() {
  env \
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

assert_true "$(bash -n "$TESTER"; echo $?)" "tester.sh has valid Bash syntax"

# Exact image validation happens before Docker is called.
: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite:latest" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects the latest tag"
assert_contains "$OUTPUT" "must never use latest" "latest rejection explains the campaign rule"
assert_empty_file "$FAKE_LOG" "latest rejection occurs before Docker calls"

OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects an implicit latest image"
assert_contains "$OUTPUT" "explicit tag or sha256 digest" "implicit latest rejection requests an exact reference"

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
assert_contains "$CALLS" " DEL " "smoke cleans keys after a failure"

# Durability restarts the service, waits again, verifies, and removes its key.
: >"$FAKE_LOG"
OUTPUT="$(run_tester bash "$TESTER" durability 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_eq 0 "$STATUS" "durability succeeds when the value survives restart"
assert_contains "$CALLS" "restart ferrite" "durability restarts Ferrite through Compose"
assert_contains "$CALLS" " GET " "durability reads the value after restart"
assert_contains "$CALLS" " DEL " "durability removes its temporary key"
assert_contains "$OUTPUT" "tester volume was preserved" "durability documents volume preservation"

# Diagnostics collect only bounded, reviewable operational data.
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
