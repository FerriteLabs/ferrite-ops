#!/usr/bin/env bash
set -euo pipefail

REPO="ferritelabs/ferrite"
VERSION="${1:-latest}"
INSTALL_DIR="${FERRITE_INSTALL_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${FERRITE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ferrite}"
DATA_DIR="${FERRITE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ferrite}"
CONFIG_PATH="${FERRITE_CONFIG_PATH:-$CONFIG_DIR/ferrite.toml}"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "${OS}-${ARCH}" in
  linux-x86_64)
    ASSET="ferrite-linux-amd64"
    ;;
  linux-aarch64|linux-arm64)
    ASSET="ferrite-linux-arm64"
    ;;
  darwin-x86_64)
    ASSET="ferrite-macos-amd64"
    ;;
  darwin-arm64)
    ASSET="ferrite-macos-arm64"
    ;;
  *)
    echo "Unsupported platform: ${OS}-${ARCH}"
    exit 1
    ;;
esac

if [[ "$VERSION" == "latest" ]]; then
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
  BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

TARBALL="${ASSET}.tar.gz"
echo "Downloading ${BASE_URL}/${TARBALL}..."
curl -fsSL "${BASE_URL}/${TARBALL}" -o "${TMP_DIR}/${TARBALL}"

# Verify checksum if available
CHECKSUM_URL="${BASE_URL}/${TARBALL}.sha256"
if curl -fsSL "$CHECKSUM_URL" -o "${TMP_DIR}/${TARBALL}.sha256" 2>/dev/null; then
  echo "Verifying SHA256 checksum..."
  cd "${TMP_DIR}"
  if command -v sha256sum &>/dev/null; then
    sha256sum -c "${TARBALL}.sha256" || { echo "ERROR: Checksum verification failed!"; exit 1; }
  elif command -v shasum &>/dev/null; then
    shasum -a 256 -c "${TARBALL}.sha256" || { echo "ERROR: Checksum verification failed!"; exit 1; }
  else
    echo "Warning: No sha256sum or shasum found, skipping verification"
  fi
  cd - >/dev/null
else
  echo "Warning: No checksum file available, skipping verification"
fi

mkdir -p "${INSTALL_DIR}"
tar -xzf "${TMP_DIR}/${TARBALL}" -C "${TMP_DIR}"

for bin in ferrite ferrite-cli ferrite-tui; do
  if [[ -f "${TMP_DIR}/${bin}" ]]; then
    install -m 755 "${TMP_DIR}/${bin}" "${INSTALL_DIR}/${bin}"
  fi
done

if [[ "${FERRITE_SKIP_INIT:-}" != "1" ]]; then
  mkdir -p "${CONFIG_DIR}"
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    if ! "${INSTALL_DIR}/ferrite" init --output "${CONFIG_PATH}" --data-dir "${DATA_DIR}" --minimal; then
      echo "Warning: failed to create config at ${CONFIG_PATH}."
    fi
  fi
fi

echo "Ferrite installed to ${INSTALL_DIR}"
echo "Add it to PATH: export PATH=\"${INSTALL_DIR}:\$PATH\""
if [[ -f "${CONFIG_PATH}" ]]; then
  echo "Config created at ${CONFIG_PATH}"
  echo "Run: ferrite --config ${CONFIG_PATH}"
fi
