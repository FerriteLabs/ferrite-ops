#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required. Install Rust from https://rustup.rs/ and retry."
  exit 1
fi

if [[ "$(uname -s)" == "Linux" ]]; then
  if ! command -v pkg-config >/dev/null 2>&1; then
    echo "pkg-config and OpenSSL headers are required on Linux."
    echo "Install: sudo apt-get install -y pkg-config libssl-dev"
    echo "Or: sudo dnf install -y pkgconf-pkg-config openssl-devel"
    exit 1
  fi
  if ! pkg-config --exists openssl >/dev/null 2>&1; then
    echo "OpenSSL development headers are required on Linux."
    echo "Install: sudo apt-get install -y libssl-dev"
    echo "Or: sudo dnf install -y openssl-devel"
    exit 1
  fi
fi

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

cargo build --release --bin ferrite --bin ferrite-cli

./target/release/ferrite init --output "$CONFIG_PATH" --data-dir "$DATA_DIR" --force --minimal

RUST_LOG=ferrite=warn ./target/release/ferrite \
  --config "$CONFIG_PATH" \
  --port "$PORT" \
  --metrics-port "$METRICS_PORT" &
SERVER_PID=$!

for _ in {1..40}; do
  if ./target/release/ferrite-cli -p "$PORT" PING >/dev/null 2>&1; then
    ./target/release/ferrite-cli -p "$PORT" PING
    exit 0
  fi
  sleep 0.25
done

echo "Ferrite failed to respond on port ${PORT}."
exit 1
