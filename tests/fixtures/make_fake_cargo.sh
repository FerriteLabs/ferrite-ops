#!/usr/bin/env bash
# Writes a fake `cargo` executable into $1 that fakes `cargo build
# --release --manifest-path <dir>/Cargo.toml --bin ferrite --bin ferrite-cli`
# by copying prebuilt binaries from $2 into <dir>/target/release/. Used to
# test smoke_test.sh's FERRITE_SOURCE_DIR build path without a real Rust
# toolchain or Ferrite source tree.
set -euo pipefail

DEST_DIR="${1:?usage: make_fake_cargo.sh <dest-dir> <prebuilt-binaries-dir>}"
PREBUILT_DIR="${2:?usage: make_fake_cargo.sh <dest-dir> <prebuilt-binaries-dir>}"
mkdir -p "$DEST_DIR"

cat > "${DEST_DIR}/cargo" << EOF_CARGO
#!/usr/bin/env bash
set -euo pipefail
MANIFEST_PATH=""
ARGS=("\$@")
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --manifest-path) MANIFEST_PATH="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -z "\$MANIFEST_PATH" || ! -f "\$MANIFEST_PATH" ]]; then
  echo "fake cargo: --manifest-path missing or not found: \$MANIFEST_PATH" >&2
  exit 1
fi
SRC_DIR="\$(dirname "\$MANIFEST_PATH")"
TARGET_DIR="\${SRC_DIR}/target/release"
mkdir -p "\$TARGET_DIR"
cp "${PREBUILT_DIR}/ferrite" "\$TARGET_DIR/ferrite"
cp "${PREBUILT_DIR}/ferrite-cli" "\$TARGET_DIR/ferrite-cli"
chmod +x "\$TARGET_DIR/ferrite" "\$TARGET_DIR/ferrite-cli"
EOF_CARGO
chmod +x "${DEST_DIR}/cargo"
