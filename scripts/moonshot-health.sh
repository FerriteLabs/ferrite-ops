#!/usr/bin/env bash
# moonshot-health.sh — Verify moonshot features are operational
#
# Usage:
#   ./moonshot-health.sh                        # localhost:6379, all features
#   ./moonshot-health.sh -h ferrite-primary -p 6379
#   ./moonshot-health.sh --skip concord,pangea   # skip disabled features
#
# Exit codes:
#   0 — all enabled moonshots responded
#   1 — one or more checks failed
set -euo pipefail

HOST="localhost"
PORT="6379"
SKIP=""
REDIS_CLI="${REDIS_CLI:-redis-cli}"
VERBOSE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --host HOST       Ferrite host (default: localhost)
  -p, --port PORT       Ferrite port (default: 6379)
  -s, --skip FEATURES   Comma-separated features to skip (e.g. concord,pangea)
  -v, --verbose         Print per-check details
  --help                Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host)  HOST="$2"; shift 2 ;;
    -p|--port)  PORT="$2"; shift 2 ;;
    -s|--skip)  SKIP="$2"; shift 2 ;;
    -v|--verbose) VERBOSE=true; shift ;;
    --help)     usage ;;
    *)          echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Convert skip list to an associative array for O(1) lookup
declare -A SKIP_MAP
IFS=',' read -ra SKIP_ARR <<< "$SKIP"
for feat in "${SKIP_ARR[@]}"; do
  SKIP_MAP["${feat,,}"]="1"  # lowercase key
done

PASSED=0
FAILED=0
SKIPPED=0
ERRORS=()

run_check() {
  local name="$1"
  local cmd="$2"
  local key="${name,,}"

  if [[ -n "${SKIP_MAP[$key]+x}" ]]; then
    $VERBOSE && echo "  SKIP  $name"
    ((SKIPPED++))
    return
  fi

  local output
  if output=$($REDIS_CLI -h "$HOST" -p "$PORT" $cmd 2>&1); then
    if [[ -n "$output" && "$output" != *"ERR"* && "$output" != *"unknown command"* ]]; then
      $VERBOSE && echo "  OK    $name"
      ((PASSED++))
    else
      $VERBOSE && echo "  FAIL  $name — response: $output"
      ((FAILED++))
      ERRORS+=("$name: unexpected response — $output")
    fi
  else
    $VERBOSE && echo "  FAIL  $name — could not connect or command error"
    ((FAILED++))
    ERRORS+=("$name: command failed — $output")
  fi
}

echo "Moonshot health check — ${HOST}:${PORT}"
echo "────────────────────────────────────────"

# Basic connectivity
if ! $REDIS_CLI -h "$HOST" -p "$PORT" PING >/dev/null 2>&1; then
  echo "FATAL: cannot reach Ferrite at ${HOST}:${PORT}"
  exit 1
fi
$VERBOSE && echo "  OK    PING"

# Moonshot subsystem checks
run_check "Forge"     "FN.HELP"
run_check "Mnemo"     "MEM.HELP"
run_check "Chronicle" "CHR.HELP"
run_check "Lucidity"  "LUC.HELP"
run_check "Concord"   "CNC.HELP"
run_check "Pangea"    "PAN.HELP"

echo "────────────────────────────────────────"
echo "Results: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"

if [[ ${FAILED} -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for err in "${ERRORS[@]}"; do
    echo "  • $err"
  done
  exit 1
fi

echo "All enabled moonshots healthy ✓"
exit 0
