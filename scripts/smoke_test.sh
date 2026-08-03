#!/usr/bin/env bash
# Ferrite Smoke Test
#
# Starts a Ferrite server and confirms it responds to PING, then cleans up.
# This script is repository-independent: ferrite-ops does not vendor the
# Ferrite source, so it never assumes a sibling ../ferrite checkout or that
# Cargo sources exist in this repo.
#
# Binary resolution order (first match wins):
#   1. FERRITE_BIN / FERRITE_CLI_BIN - explicit paths to prebuilt binaries.
#   2. FERRITE_SOURCE_DIR            - explicit path to a Ferrite source
#                                      checkout (must contain Cargo.toml);
#                                      built locally with `cargo build`.
#   3. `ferrite` / `ferrite-cli` already available on PATH.
#
# Environment variables:
#   FERRITE_BIN              - path to a prebuilt `ferrite` executable
#   FERRITE_CLI_BIN          - path to a prebuilt `ferrite-cli` executable
#   FERRITE_SOURCE_DIR       - path to a Ferrite source checkout to build from
#   FERRITE_SMOKE_PORT       - fallback server port if python is unavailable
#   FERRITE_SMOKE_METRICS_PORT - fallback metrics port if python is unavailable
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

die() {
  # Print the first argument prefixed with "error:"; any further arguments
  # are printed as additional indented lines (used for multi-line hints).
  echo "${SCRIPT_NAME}: error: $1" >&2
  shift || true
  for line in "$@"; do
    echo "  $line" >&2
  done
  exit 1
}

# --- Resolve the ferrite/ferrite-cli binaries -------------------------------
#
# FERRITE_BIN/FERRITE_CLI_BIN and FERRITE_SOURCE_DIR are both explicit,
# opt-in signals from the caller, so either takes precedence over binaries
# that merely happen to be on PATH. This script never builds anything unless
# FERRITE_SOURCE_DIR is explicitly provided.

FERRITE_BIN="${FERRITE_BIN:-}"
FERRITE_CLI_BIN="${FERRITE_CLI_BIN:-}"
FERRITE_SOURCE_DIR="${FERRITE_SOURCE_DIR:-}"

if [[ -n "$FERRITE_BIN" && ! -x "$FERRITE_BIN" ]]; then
  die "FERRITE_BIN='${FERRITE_BIN}' is not an executable file."
fi
if [[ -n "$FERRITE_CLI_BIN" && ! -x "$FERRITE_CLI_BIN" ]]; then
  die "FERRITE_CLI_BIN='${FERRITE_CLI_BIN}' is not an executable file."
fi

if [[ -n "$FERRITE_SOURCE_DIR" && ! -f "${FERRITE_SOURCE_DIR}/Cargo.toml" ]]; then
  die "FERRITE_SOURCE_DIR='${FERRITE_SOURCE_DIR}' does not contain a Cargo.toml." \
      "Point FERRITE_SOURCE_DIR at a Ferrite source checkout, e.g. a clone of" \
      "https://github.com/FerriteLabs/ferrite."
fi

# Only build from source if at least one binary still needs resolving and a
# source dir was explicitly given.
NEED_BUILD=0
if [[ -n "$FERRITE_SOURCE_DIR" ]]; then
  if [[ -z "$FERRITE_BIN" || -z "$FERRITE_CLI_BIN" ]]; then
    NEED_BUILD=1
  fi
fi

if [[ "$NEED_BUILD" -eq 1 ]]; then
  if ! command -v cargo >/dev/null 2>&1; then
    die "cargo is required to build from FERRITE_SOURCE_DIR. Install Rust from https://rustup.rs/ and retry."
  fi

  if [[ "$(uname -s)" == "Linux" ]]; then
    if ! command -v pkg-config >/dev/null 2>&1; then
      die "pkg-config and OpenSSL headers are required on Linux to build from source." \
          "Install: sudo apt-get install -y pkg-config libssl-dev" \
          "Or: sudo dnf install -y pkgconf-pkg-config openssl-devel"
    fi
    if ! pkg-config --exists openssl >/dev/null 2>&1; then
      die "OpenSSL development headers are required on Linux to build from source." \
          "Install: sudo apt-get install -y libssl-dev" \
          "Or: sudo dnf install -y openssl-devel"
    fi
  fi

  echo "Building ferrite/ferrite-cli from FERRITE_SOURCE_DIR=${FERRITE_SOURCE_DIR} ..."
  cargo build --release --manifest-path "${FERRITE_SOURCE_DIR}/Cargo.toml" --bin ferrite --bin ferrite-cli

  BUILT_TARGET_DIR="${FERRITE_SOURCE_DIR}/target/release"
  [[ -z "$FERRITE_BIN" ]] && FERRITE_BIN="${BUILT_TARGET_DIR}/ferrite"
  [[ -z "$FERRITE_CLI_BIN" ]] && FERRITE_CLI_BIN="${BUILT_TARGET_DIR}/ferrite-cli"
fi

# Fall back to PATH lookups for anything still unresolved.
if [[ -z "$FERRITE_BIN" ]]; then
  FERRITE_BIN="$(command -v ferrite || true)"
fi
if [[ -z "$FERRITE_CLI_BIN" ]]; then
  FERRITE_CLI_BIN="$(command -v ferrite-cli || true)"
fi

if [[ -z "$FERRITE_BIN" || ! -x "$FERRITE_BIN" ]]; then
  die "Could not locate the 'ferrite' binary. Set FERRITE_BIN=/path/to/ferrite," \
      "install it onto PATH, or set FERRITE_SOURCE_DIR=/path/to/ferrite-source" \
      "(containing Cargo.toml) to build it."
fi
if [[ -z "$FERRITE_CLI_BIN" || ! -x "$FERRITE_CLI_BIN" ]]; then
  die "Could not locate the 'ferrite-cli' binary. Set FERRITE_CLI_BIN=/path/to/ferrite-cli," \
      "install it onto PATH, or set FERRITE_SOURCE_DIR=/path/to/ferrite-source" \
      "(containing Cargo.toml) to build it."
fi

echo "Using ferrite binary:     ${FERRITE_BIN}"
echo "Using ferrite-cli binary: ${FERRITE_CLI_BIN}"

# --- Run the smoke test -----------------------------------------------------

TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

CONFIG_PATH="${TMP_DIR}/ferrite.toml"
DATA_DIR="${TMP_DIR}/data"

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
fi

if [[ -n "$PYTHON_BIN" ]]; then
  read -r PORT METRICS_PORT < <("$PYTHON_BIN" - <<'PY'
import socket
s1 = socket.socket()
s1.bind(("", 0))
p1 = s1.getsockname()[1]
s2 = socket.socket()
s2.bind(("", 0))
p2 = s2.getsockname()[1]
s1.close()
s2.close()
print(f"{p1} {p2}")
PY
)
else
  PORT="${FERRITE_SMOKE_PORT:-6380}"
  METRICS_PORT="${FERRITE_SMOKE_METRICS_PORT:-9091}"
  echo "python not found; using fallback ports ${PORT}/${METRICS_PORT}."
fi

"$FERRITE_BIN" init --output "$CONFIG_PATH" --data-dir "$DATA_DIR" --force --minimal

RUST_LOG=ferrite=warn "$FERRITE_BIN" \
  --config "$CONFIG_PATH" \
  --port "$PORT" \
  --metrics-port "$METRICS_PORT" &
SERVER_PID=$!

for _ in {1..40}; do
  if "$FERRITE_CLI_BIN" -p "$PORT" PING >/dev/null 2>&1; then
    "$FERRITE_CLI_BIN" -p "$PORT" PING
    exit 0
  fi
  sleep 0.25
done

echo "Ferrite failed to respond on port ${PORT}."
exit 1
