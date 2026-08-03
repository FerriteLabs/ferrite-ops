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
mkdir -p "${WORK_DIR}/bin-mute"
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
# Server that never listens: just sleep so it's a real backgroundable PID.
sleep 300
MUTE_FERRITE
cat > "${WORK_DIR}/bin-mute/ferrite-cli" << 'MUTE_CLI'
#!/usr/bin/env bash
exit 1
MUTE_CLI
chmod +x "${WORK_DIR}/bin-mute/ferrite" "${WORK_DIR}/bin-mute/ferrite-cli"

FERRITE_BIN="${WORK_DIR}/bin-mute/ferrite" \
  FERRITE_CLI_BIN="${WORK_DIR}/bin-mute/ferrite-cli" \
  FERRITE_SMOKE_PORT=16399 FERRITE_SMOKE_METRICS_PORT=16499 \
  bash "${REPO_ROOT}/scripts/smoke_test.sh" >/dev/null 2>&1
STATUS=$?
sleep 0.3

assert_eq 1 "$STATUS" "smoke_test.sh exits 1 when the server never responds to PING"
LEFTOVER_MUTE_PROCS="$(pgrep -f "${WORK_DIR}/bin-mute/ferrite" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "$LEFTOVER_MUTE_PROCS" "the never-responding server process is still killed on cleanup"

harness_summary
