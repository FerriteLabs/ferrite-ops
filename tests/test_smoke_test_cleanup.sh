#!/usr/bin/env bash
# Verifies scripts/smoke_test.sh cleans up its temp config/data directory and
# the background server process, both on success and when the server never
# answers PING.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "  skip: python3 not available, fake ferrite server fixture requires it"
  exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Success case: server responds, process + temp dir must be cleaned up.
"${HERE}/fixtures/make_fake_ferrite.sh" "${WORK_DIR}/bin-ok"

BEFORE_TMP_COUNT=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')
FERRITE_BIN="${WORK_DIR}/bin-ok/ferrite" \
  FERRITE_CLI_BIN="${WORK_DIR}/bin-ok/ferrite-cli" \
  bash "${REPO_ROOT}/scripts/smoke_test.sh" >/dev/null 2>&1
sleep 0.3
AFTER_TMP_COUNT=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$BEFORE_TMP_COUNT" "$AFTER_TMP_COUNT" "no leftover temp dirs after a successful run"

LEFTOVER_PROCS="$(pgrep -f "${WORK_DIR}/bin-ok/ferrite" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$LEFTOVER_PROCS" "no leftover ferrite server process after a successful run"

# --- Failure case: fake ferrite that starts but never answers PING; the
#     script must still time out, exit non-zero, and clean up.
#
# The fixture below `exec`s `sleep` (replacing its own process image, so the
# PID is unchanged) instead of merely calling `sleep 300` as a foreground
# child. That distinction matters: smoke_test.sh's cleanup trap only does
# `kill "$SERVER_PID"`, where SERVER_PID is the PID that was directly
# backgrounded with `&`. If the fixture backgrounded a *wrapper* shell that
# then spawned `sleep 300` as its own child (without `exec`), killing the
# wrapper does not kill that grandchild -- `sleep 300` becomes orphaned and
# keeps running for ~5 minutes, silently leaking a process.
#
# To make the regression test itself meaningful (rather than vacuously
# passing either way), the fixture encodes its own PID into the sleep
# duration itself (`sleep "300.$$"`) before exec'ing. That value survives
# both in the fixed case (exec keeps the same real PID) *and* would survive
# in a hypothetical regressed case (a leaked grandchild's argv would still
# literally read "sleep 300.<wrapper pid>", even though the grandchild runs
# under a different real PID). Searching the whole process table for that
# exact, unique marker -- rather than for the fixture's script path, which
# disappears from argv the moment `sleep` replaces the process image and
# would make the check trivially pass regardless of whether a leak
# occurred -- is what actually distinguishes "cleaned up" from "orphaned".
mkdir -p "${WORK_DIR}/bin-mute"
MUTE_PID_FILE="${WORK_DIR}/mute-server.pid"
cat > "${WORK_DIR}/bin-mute/ferrite" << 'MUTE_FERRITE'
#!/usr/bin/env bash
if [[ "${1:-}" == "init" ]]; then
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) : > "$2"; shift 2 ;;
      --data-dir) mkdir -p "$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  exit 0
fi
: "${FERRITE_MUTE_PID_FILE:?FERRITE_MUTE_PID_FILE must be set by the test}"
echo "$$" > "${FERRITE_MUTE_PID_FILE}"
# Server that never listens. `exec` so smoke_test.sh's `kill "$SERVER_PID"`
# terminates this exact PID directly, rather than leaving an orphaned
# `sleep` grandchild running after only this wrapper shell is killed. The
# PID is baked into the sleep duration purely so the test below can find
# (or fail to find) this exact invocation in the process table afterwards.
exec sleep "300.$$"
MUTE_FERRITE
cat > "${WORK_DIR}/bin-mute/ferrite-cli" << 'MUTE_CLI'
#!/usr/bin/env bash
exit 1
MUTE_CLI
chmod +x "${WORK_DIR}/bin-mute/ferrite" "${WORK_DIR}/bin-mute/ferrite-cli"

FERRITE_BIN="${WORK_DIR}/bin-mute/ferrite" \
  FERRITE_CLI_BIN="${WORK_DIR}/bin-mute/ferrite-cli" \
  FERRITE_MUTE_PID_FILE="$MUTE_PID_FILE" \
  FERRITE_SMOKE_PORT=16399 FERRITE_SMOKE_METRICS_PORT=16499 \
  bash "${REPO_ROOT}/scripts/smoke_test.sh" >/dev/null 2>&1
STATUS=$?
sleep 0.3

assert_eq 1 "$STATUS" "smoke_test.sh exits 1 when the server never responds to PING"

MUTE_PID=""
if [[ -f "$MUTE_PID_FILE" ]]; then
  MUTE_PID="$(cat "$MUTE_PID_FILE")"
fi
assert_true "$( [[ -n "$MUTE_PID" ]]; echo $? )" \
  "the mute fixture recorded its own PID before exec'ing sleep (proves the fixture actually started, not a vacuous check)"

if [[ -n "$MUTE_PID" ]]; then
  if kill -0 "$MUTE_PID" 2>/dev/null; then
    harness_fail "the exact backgrounded server PID (${MUTE_PID}) is still running after smoke_test.sh's cleanup"
  else
    harness_ok "the exact backgrounded server PID (${MUTE_PID}) was terminated by smoke_test.sh's cleanup, not orphaned"
  fi

  # This is the assertion that actually distinguishes "fixed" from
  # "orphaned grandchild leaked": it searches the *entire* process table
  # (not just descendants of a known PID, which would no longer exist to
  # search under) for the unique "300.<mute pid>" marker baked into the
  # fixture's sleep invocation. A regression that replaced `exec sleep
  # "300.$$"` with a plain `sleep "300.$$"` foreground child would still
  # leave this marker visible in `ps`/`pgrep -f` output for ~5 minutes,
  # under a *different* real PID than $MUTE_PID -- so this check, unlike
  # `kill -0 "$MUTE_PID"` above, would correctly still catch that leak.
  ORPHANED_SLEEP_COUNT="$(pgrep -f "sleep 300\.${MUTE_PID}\$" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "0" "$ORPHANED_SLEEP_COUNT" \
    "no process anywhere (by exact PID or orphaned grandchild) still matches the mute fixture's unique sleep marker after cleanup"
else
  harness_fail "the exact backgrounded server PID was terminated by smoke_test.sh's cleanup, not orphaned (no PID recorded)"
  harness_fail "no process anywhere still matches the mute fixture's unique sleep marker after cleanup (no PID recorded)"
fi

harness_summary
