#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v cargo >/dev/null 2>&1; then
  cat <<'EOF'
cargo is required. Install Rust from https://rustup.rs/ and retry.

No Rust toolchain? Use Docker:
  docker compose up -d
  docker compose exec -T ferrite ferrite-cli PING

Or install a prebuilt binary:
  curl -fsSL https://raw.githubusercontent.com/ferritelabs/ferrite/main/scripts/install.sh | bash
  ferrite --config ~/.config/ferrite/ferrite.toml
EOF
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

echo "Building Ferrite (release mode)..."
cargo build --release --bin ferrite --bin ferrite-cli

# Use explicit config if set, otherwise let Ferrite use its built-in fallback chain:
# ferrite.toml -> ferrite.example.toml -> built-in defaults
if [[ -n "${FERRITE_CONFIG:-}" ]]; then
  exec ./target/release/ferrite --config "$FERRITE_CONFIG"
else
  exec ./target/release/ferrite
fi
