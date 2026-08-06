#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck disable=SC1091
source "${HERE}/lib/harness.sh"
# shellcheck source=tests/lib/host_services.sh
source "${HERE}/lib/host_services.sh"

TESTER="${REPO_ROOT}/scripts/tester.sh"
WORK_DIR="$(mktemp -d)"
trap 'host_services_stop; rm -rf "$WORK_DIR"' EXIT

# `start` verifies host reachability with real loopback servers, so commands
# that are expected to reach that stage need something actually listening.
# Every other command is unaffected by these ports.
host_services_start pong ok || {
  echo "  FAIL: could not start the loopback host services fixture" >&2
  exit 1
}

"${HERE}/fixtures/make_fake_docker.sh" "${WORK_DIR}/bin"
FAKE_LOG="${WORK_DIR}/docker.log"
FAKE_STATE="${WORK_DIR}/state"
touch "$FAKE_LOG"
mkdir -p "$FAKE_STATE"

# A valid, exact digest reference matching the fake docker fixture's own
# `docker image inspect` output; used as the default FERRITE_TEST_IMAGE for
# every test that is not specifically exercising missing/malformed values.
FAKE_IMAGE="ghcr.io/ferritelabs/ferrite@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TEARDOWN_DUMMY_IMAGE="ferrite.invalid/teardown-only@sha256:0000000000000000000000000000000000000000000000000000000000000000"

PROVENANCE_ROOT="${WORK_DIR}/provenance-repo"
mkdir -p "${PROVENANCE_ROOT}/scripts"
cp "$TESTER" "${PROVENANCE_ROOT}/scripts/tester.sh"
cp "${REPO_ROOT}/scripts/tester-host-probe.py" "${PROVENANCE_ROOT}/scripts/"
cp "${REPO_ROOT}/docker-compose.tester.yml" "${PROVENANCE_ROOT}/"
git -C "$PROVENANCE_ROOT" init -q
git -C "$PROVENANCE_ROOT" config user.name "Ferrite Ops Tests"
git -C "$PROVENANCE_ROOT" config user.email "ferrite-ops-tests@example.invalid"
git -C "$PROVENANCE_ROOT" add scripts docker-compose.tester.yml
git -C "$PROVENANCE_ROOT" commit -qm "test fixture"
PROVENANCE_COMMIT="$(git -C "$PROVENANCE_ROOT" rev-parse HEAD)"
git -C "$PROVENANCE_ROOT" checkout --detach -q "$PROVENANCE_COMMIT"
PROVENANCE_TESTER="${PROVENANCE_ROOT}/scripts/tester.sh"

SHORT_SHA_BIN="${WORK_DIR}/short-sha-bin"
mkdir -p "$SHORT_SHA_BIN"
REAL_GIT="$(command -v git)"
cat >"${SHORT_SHA_BIN}/git" <<SHORT_GIT
#!/usr/bin/env bash
case "\$*" in
  *"rev-parse --is-inside-work-tree"*) echo true ;;
  *"symbolic-ref -q HEAD"*) exit 1 ;;
  *"rev-parse --verify HEAD^{commit}"*) echo deadbeef ;;
  *) exec "$REAL_GIT" "\$@" ;;
esac
SHORT_GIT
chmod +x "${SHORT_SHA_BIN}/git"

run_tester() {
  env \
    PATH="${WORK_DIR}/bin:${PATH}" \
    FAKE_DOCKER_LOG="$FAKE_LOG" \
    FAKE_DOCKER_STATE="$FAKE_STATE" \
    FERRITE_TEST_POLL_INTERVAL="0.05" \
    FERRITE_TEST_IMAGE="$FAKE_IMAGE" \
    FERRITE_TEST_PORT="$RESP_PORT" \
    FERRITE_TEST_METRICS_PORT="$METRICS_PORT" \
    FERRITE_TEST_PROBE_TIMEOUT=1 \
    FERRITE_TEST_PROBE_RETRIES=0 \
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
    FERRITE_TEST_PORT="$RESP_PORT" \
    FERRITE_TEST_METRICS_PORT="$METRICS_PORT" \
    FERRITE_TEST_PROBE_TIMEOUT=1 \
    FERRITE_TEST_PROBE_RETRIES=0 \
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
assert_contains "$(cat "$TESTER")" '"$FERRITE_TEST_PYTHON" -I "$HOST_PROBE"' "host probe uses Python isolated mode"

# --- FERRITE_TEST_IMAGE validation happens before Docker is called, for
# every failure mode: missing, tags (including latest), bare digests,
# missing repositories, and malformed/uppercase digests. Only a complete
# repository-qualified lowercase sha256 digest is ever accepted. ---

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
assert_nonzero "$STATUS" "start rejects an implicit latest image with no digest"
assert_contains "$OUTPUT" "tags are never accepted" "implicit latest rejection requires a digest"
assert_empty_file "$FAKE_LOG" "implicit latest rejection occurs before Docker calls"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite:v1.2.3" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a pinned tag"
assert_contains "$OUTPUT" "tags are never accepted" "pinned tag rejection requires a digest"
assert_empty_file "$FAKE_LOG" "pinned tag rejection occurs before Docker calls"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite:v1.2.3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a tag combined with a digest"
assert_contains "$OUTPUT" "must not combine a tag with a digest" "tag+digest rejection is actionable"
assert_empty_file "$FAKE_LOG" "tag+digest rejection occurs before Docker calls"

: >"$FAKE_LOG"
REGISTRY_PORT_IMAGE="localhost:5000/team/ferrite@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="$REGISTRY_PORT_IMAGE" FAKE_RUNNING_IMAGE="$REGISTRY_PORT_IMAGE" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_eq 0 "$STATUS" "start accepts a digest reference whose registry includes a port"
assert_contains "$(cat "$FAKE_LOG")" "up -d ferrite" "registry-port digest reaches Compose"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs/ferrite@sha256:not-a-real-digest" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a malformed digest"
assert_contains "$OUTPUT" "lowercase sha256:<64 lowercase hex characters>" "malformed digest rejection explains the required form"
assert_empty_file "$FAKE_LOG" "malformed digest rejection occurs before Docker calls"

: >"$FAKE_LOG"
UPPERCASE_DIGEST="ghcr.io/ferritelabs/ferrite@sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="$UPPERCASE_DIGEST" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects an uppercase-hex digest"
assert_contains "$OUTPUT" "lowercase sha256" "uppercase digest rejection explains the lowercase-only form"
assert_empty_file "$FAKE_LOG" "uppercase digest rejection occurs before Docker calls"

: >"$FAKE_LOG"
MIXED_CASE_DIGEST="ghcr.io/ferritelabs/ferrite@sha256:aAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="$MIXED_CASE_DIGEST" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a mixed-case digest"
assert_contains "$OUTPUT" "lowercase sha256" "mixed-case digest rejection explains the lowercase-only form"
assert_empty_file "$FAKE_LOG" "mixed-case digest rejection occurs before Docker calls"

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ghcr.io/ferritelabs//ferrite@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" bash "$TESTER" start 2>&1)"
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

: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_IMAGE="ferrite@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start rejects a single-segment (non-repository-qualified) image name"
assert_contains "$OUTPUT" "not a bare image name" "single-segment rejection asks for a repository-qualified name"
assert_empty_file "$FAKE_LOG" "single-segment rejection occurs before Docker calls"

# Start validates Compose, pulls the exact image, starts only Ferrite, waits,
# and verifies the running container's image matches FERRITE_TEST_IMAGE.
: >"$FAKE_LOG"
OUTPUT="$(run_tester bash "$TESTER" start 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_eq 0 "$STATUS" "start succeeds when the fake container is healthy"
assert_contains "$CALLS" "config" "start renders and validates the tester Compose file"
assert_contains "$CALLS" "--profile tester" "start always enables the dedicated tester profile"
assert_contains "$CALLS" "pull ferrite" "start pulls the configured tester image"
assert_contains "$CALLS" "up -d ferrite" "start starts only the tester service"
assert_contains "$CALLS" "inspect --format" "start checks Docker health status"
assert_contains "$CALLS" ".Config.Image" "start verifies the running container's image after health"
assert_contains "$OUTPUT" "Ferrite is healthy" "start reports readiness"
assert_contains "$OUTPUT" "Host reachability verified" "start verifies host reachability before claiming availability"
assert_contains "$OUTPUT" "Ferrite is available on localhost" "start reports availability once reachable"

# Health waiting is bounded.
: >"$FAKE_LOG"
OUTPUT="$(run_tester FAKE_HEALTH_STATUS=unhealthy FERRITE_TEST_READY_TIMEOUT=1 bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start fails after the readiness timeout"
assert_contains "$OUTPUT" "did not become healthy within 1s" "health timeout is actionable"

# start fails, with a clear message, when the container that became healthy
# is not actually running the requested image (e.g. a stale container).
: >"$FAKE_LOG"
MISMATCHED_IMAGE="ghcr.io/ferritelabs/ferrite@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
OUTPUT="$(run_tester FAKE_RUNNING_IMAGE="$MISMATCHED_IMAGE" bash "$TESTER" start 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "start fails when the running container image does not match FERRITE_TEST_IMAGE"
assert_contains "$OUTPUT" "does not match FERRITE_TEST_IMAGE" "start image-mismatch failure is actionable"

# smoke verifies the running container's image before any CLI exec: no
# running container, and a running-but-mismatched image, must both fail
# clearly before any ferrite-cli command is invoked.
: >"$FAKE_LOG"
OUTPUT="$(run_tester FAKE_NO_CONTAINER=1 bash "$TESTER" smoke 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_nonzero "$STATUS" "smoke fails when no tester container is running"
assert_contains "$OUTPUT" "No running tester container was found" "no-container failure is actionable"
assert_not_contains "$CALLS" "exec" "no-container failure occurs before any CLI exec"

: >"$FAKE_LOG"
MISMATCHED_IMAGE="ghcr.io/ferritelabs/ferrite@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
OUTPUT="$(run_tester FAKE_RUNNING_IMAGE="$MISMATCHED_IMAGE" bash "$TESTER" smoke 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_nonzero "$STATUS" "smoke fails when the running container image does not match FERRITE_TEST_IMAGE"
assert_contains "$OUTPUT" "does not match FERRITE_TEST_IMAGE" "smoke image-mismatch failure is actionable"
assert_not_contains "$CALLS" "exec" "image-mismatch failure occurs before any CLI exec"

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

# Once enabled, durability also verifies the running container's image
# before any CLI exec: no running container, and a mismatched image, must
# both fail clearly before the durability SET is ever issued.
: >"$FAKE_LOG"
OUTPUT="$(run_tester FERRITE_TEST_ENABLE_DURABILITY=1 FAKE_NO_CONTAINER=1 bash "$TESTER" durability 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_nonzero "$STATUS" "durability fails when no tester container is running"
assert_contains "$OUTPUT" "No running tester container was found" "durability no-container failure is actionable"
assert_not_contains "$CALLS" "exec" "durability no-container failure occurs before any CLI exec"

: >"$FAKE_LOG"
MISMATCHED_IMAGE="ghcr.io/ferritelabs/ferrite@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
OUTPUT="$(run_tester FERRITE_TEST_ENABLE_DURABILITY=1 FAKE_RUNNING_IMAGE="$MISMATCHED_IMAGE" bash "$TESTER" durability 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_nonzero "$STATUS" "durability fails when the running container image does not match FERRITE_TEST_IMAGE"
assert_contains "$OUTPUT" "does not match FERRITE_TEST_IMAGE" "durability image-mismatch failure is actionable"
assert_not_contains "$CALLS" "exec" "durability image-mismatch failure occurs before any CLI exec"

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

# Provenance is verified before Docker availability, container inspection, or
# any other diagnostic collection. The main source checkout is intentionally
# attached to the development branch, so diagnostics must reject it.
: >"$FAKE_LOG"
OUTPUT="$(run_tester bash "$TESTER" diagnostics "${WORK_DIR}/diagnostics-attached" 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "diagnostics rejects an attached Git checkout"
assert_contains "$OUTPUT" "requires detached HEAD" "attached-checkout failure explains the required state"
assert_empty_file "$FAKE_LOG" "attached-checkout rejection occurs before Docker diagnostics"

: >"$FAKE_LOG"
OUTPUT="$(
  run_tester \
    PATH="${SHORT_SHA_BIN}:${WORK_DIR}/bin:${PATH}" \
    bash "$TESTER" diagnostics "${WORK_DIR}/diagnostics-short-sha" 2>&1
)"
STATUS=$?
assert_nonzero "$STATUS" "diagnostics rejects a non-canonical short tooling SHA"
assert_contains "$OUTPUT" "full 40-character" "short-SHA failure states the canonical commit requirement"
assert_empty_file "$FAKE_LOG" "short-SHA rejection occurs before Docker diagnostics"

# Diagnostics also verifies the running container's image before any CLI
# exec once provenance is valid: no running container, and a mismatched image,
# must both fail clearly before any diagnostics are collected.
: >"$FAKE_LOG"
OUTPUT="$(run_tester FAKE_NO_CONTAINER=1 bash "$PROVENANCE_TESTER" diagnostics "${WORK_DIR}/diagnostics-no-container" 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_nonzero "$STATUS" "diagnostics fails when no tester container is running"
assert_contains "$OUTPUT" "No running tester container was found" "diagnostics no-container failure is actionable"
assert_not_contains "$CALLS" "exec" "diagnostics no-container failure occurs before any CLI exec"

: >"$FAKE_LOG"
MISMATCHED_IMAGE="ghcr.io/ferritelabs/ferrite@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
OUTPUT="$(run_tester FAKE_RUNNING_IMAGE="$MISMATCHED_IMAGE" bash "$PROVENANCE_TESTER" diagnostics "${WORK_DIR}/diagnostics-mismatch" 2>&1)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_nonzero "$STATUS" "diagnostics fails when the running container image does not match FERRITE_TEST_IMAGE"
assert_contains "$OUTPUT" "does not match FERRITE_TEST_IMAGE" "diagnostics image-mismatch failure is actionable"
assert_not_contains "$CALLS" "exec" "diagnostics image-mismatch failure occurs before any CLI exec"

# Diagnostics collect only bounded, reviewable operational data, and are
# written with restrictive, portable file permissions.
touch "${PROVENANCE_ROOT}/untracked-tester-note"
: >"$FAKE_LOG"
DIAGNOSTICS_DIR="${WORK_DIR}/diagnostics"
OUTPUT="$(run_tester bash "$PROVENANCE_TESTER" diagnostics "$DIAGNOSTICS_DIR" 2>&1)"
STATUS=$?
ARCHIVE="$(find "$DIAGNOSTICS_DIR" -type f -name '*.tar.gz' -print -quit)"
assert_eq 0 "$STATUS" "diagnostics succeeds from a detached clean checkout with untracked files"
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

# Diagnostics are a provenance record: the exact ops tooling commit must be
# recorded, never inferred from a branch or tag, so a report can always be
# attributed to the campaign commit it was produced from.
VERSIONS_TEXT="$(cat "$(find "$EXTRACT_DIR" -type f -name versions.txt -print -quit)")"
IMAGE_TEXT="$(cat "$(find "$EXTRACT_DIR" -type f -name image.txt -print -quit)")"
assert_contains "$VERSIONS_TEXT" "ferrite-ops tooling commit: ${PROVENANCE_COMMIT}" "versions.txt records the exact ops tooling commit"
assert_contains "$IMAGE_TEXT" "ferrite-ops tooling commit: ${PROVENANCE_COMMIT}" "image.txt records the exact ops tooling commit"
assert_contains "$REPORT_TEXT" "ferrite-ops tooling commit (CAMPAIGN_OPS_COMMIT): \`${PROVENANCE_COMMIT}\`" "report.md records the exact ops tooling commit"

assert_contains "$REPORT_TEXT" "template=tester_report.yml" "report template links the exact tester report form"
assert_contains "$REPORT_TEXT" "excludes environment variables, secrets, full" "report describes intentional exclusions"

cat >"${PROVENANCE_ROOT}/scripts/argparse.py" <<'PY'
raise SystemExit(0)
PY
: >"$FAKE_LOG"
OUTPUT="$(run_tester bash "$PROVENANCE_TESTER" diagnostics "${WORK_DIR}/diagnostics-shadowed" 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "diagnostics rejects untracked files under tester tooling paths"
assert_contains "$OUTPUT" "untracked or modified files" "untracked-tooling failure explains the provenance risk"
assert_empty_file "$FAKE_LOG" "untracked-tooling rejection occurs before Docker diagnostics"
rm -f "${PROVENANCE_ROOT}/scripts/argparse.py"

# Tracked unstaged and staged modifications both invalidate provenance, and
# each rejection must happen before any Docker diagnostic operation.
printf '\n# unstaged provenance test\n' >>"${PROVENANCE_ROOT}/scripts/tester.sh"
: >"$FAKE_LOG"
OUTPUT="$(run_tester bash "$PROVENANCE_TESTER" diagnostics "${WORK_DIR}/diagnostics-unstaged" 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "diagnostics rejects tracked unstaged tooling modifications"
assert_contains "$OUTPUT" "tracked staged or unstaged modifications" "unstaged-dirty failure explains the clean-checkout requirement"
assert_empty_file "$FAKE_LOG" "unstaged-dirty rejection occurs before Docker diagnostics"
git -C "$PROVENANCE_ROOT" checkout -- scripts/tester.sh

printf '\n# staged provenance test\n' >>"${PROVENANCE_ROOT}/docker-compose.tester.yml"
git -C "$PROVENANCE_ROOT" add docker-compose.tester.yml
: >"$FAKE_LOG"
OUTPUT="$(run_tester bash "$PROVENANCE_TESTER" diagnostics "${WORK_DIR}/diagnostics-staged" 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "diagnostics rejects tracked staged tooling modifications"
assert_contains "$OUTPUT" "tracked staged or unstaged modifications" "staged-dirty failure explains the clean-checkout requirement"
assert_empty_file "$FAKE_LOG" "staged-dirty rejection occurs before Docker diagnostics"
git -C "$PROVENANCE_ROOT" reset --hard -q "$PROVENANCE_COMMIT"

# Running the tooling outside a Git checkout means the exact ops commit cannot
# be determined. Diagnostics must fail rather than emit an archive that
# misattributes (or silently omits) its provenance.
NON_GIT_ROOT="${WORK_DIR}/non-git"
mkdir -p "${NON_GIT_ROOT}/scripts"
cp "$TESTER" "${NON_GIT_ROOT}/scripts/tester.sh"
cp "${REPO_ROOT}/docker-compose.tester.yml" "${NON_GIT_ROOT}/"
cp -R "${REPO_ROOT}/scripts/tester-host-probe.py" "${NON_GIT_ROOT}/scripts/"
: >"$FAKE_LOG"
NON_GIT_OUTPUT_DIR="${WORK_DIR}/diagnostics-non-git"
OUTPUT="$(run_tester bash "${NON_GIT_ROOT}/scripts/tester.sh" diagnostics "$NON_GIT_OUTPUT_DIR" 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "diagnostics fails outside a Git checkout rather than misattributing provenance"
assert_contains "$OUTPUT" "requires a Git worktree" "missing-provenance failure is actionable"
NON_GIT_ARCHIVE="$(find "$NON_GIT_OUTPUT_DIR" -type f -name '*.tar.gz' -print -quit 2>/dev/null || true)"
assert_eq "" "$NON_GIT_ARCHIVE" "no diagnostics archive is produced without verifiable provenance"

# Stop/reset require only a valid project name and Compose availability. The
# campaign image and port settings are irrelevant to cleanup, while an
# internal parse-only image lets Compose process its required interpolation.
: >"$FAKE_LOG"
OUTPUT="$(
  run_tester_no_image \
    FAKE_EXPECT_COMPOSE_IMAGE="$TEARDOWN_DUMMY_IMAGE" \
    FERRITE_TEST_PORT=not-a-port \
    FERRITE_TEST_METRICS_PORT=also-invalid \
    bash "$TESTER" stop 2>&1
)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_eq 0 "$STATUS" "stop succeeds without a campaign image or valid runtime ports"
assert_contains "$CALLS" "--profile tester" "stop always invokes Compose through the tester profile"
assert_contains "$CALLS" "down --remove-orphans" "stop removes containers"
assert_not_contains "$CALLS" " pull " "stop never pulls the teardown dummy image"
assert_not_contains "$CALLS" " up " "stop never starts the teardown dummy image"
assert_not_contains "$CALLS" "--volumes" "stop preserves the named volume"
assert_contains "$OUTPUT" "volume was preserved" "stop clearly states volume behavior"

: >"$FAKE_LOG"
OUTPUT="$(
  run_tester_no_image \
    FAKE_EXPECT_COMPOSE_IMAGE="$TEARDOWN_DUMMY_IMAGE" \
    FERRITE_TEST_PORT=not-a-port \
    FERRITE_TEST_METRICS_PORT=also-invalid \
    FERRITE_TEST_RESET_CONFIRM=1 \
    bash "$TESTER" reset 2>&1
)"
STATUS=$?
CALLS="$(cat "$FAKE_LOG")"
assert_eq 0 "$STATUS" "reset supports cleanup without a campaign image or valid runtime ports"
assert_contains "$CALLS" "down --volumes --remove-orphans" "reset explicitly removes the volume"
assert_not_contains "$CALLS" " pull " "reset never pulls the teardown dummy image"
assert_not_contains "$CALLS" " up " "reset never starts the teardown dummy image"
assert_contains "$OUTPUT" "permanently deletes" "reset prints a destructive warning"

: >"$FAKE_LOG"
OUTPUT="$(printf 'NO\n' | run_tester bash "$TESTER" reset 2>&1)"
STATUS=$?
assert_nonzero "$STATUS" "reset cancels unless RESET is typed"
assert_not_contains "$(cat "$FAKE_LOG")" "down --volumes" "cancelled reset does not delete the volume"

harness_summary
