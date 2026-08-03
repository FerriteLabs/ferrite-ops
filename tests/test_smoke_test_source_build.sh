#!/usr/bin/env bash
# Verifies scripts/smoke_test.sh builds from an explicit FERRITE_SOURCE_DIR
# (containing Cargo.toml) using a fake `cargo`, without a real Rust toolchain
# or any assumption about a sibling ../ferrite checkout.
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

PREBUILT_DIR="${WORK_DIR}/prebuilt"
"${HERE}/fixtures/make_fake_ferrite.sh" "$PREBUILT_DIR"

FAKE_CARGO_DIR="${WORK_DIR}/fake-cargo-bin"
"${HERE}/fixtures/make_fake_cargo.sh" "$FAKE_CARGO_DIR" "$PREBUILT_DIR"

SOURCE_DIR="${WORK_DIR}/ferrite-source"
mkdir -p "$SOURCE_DIR"
cat > "${SOURCE_DIR}/Cargo.toml" << 'CARGO_TOML'
[package]
name = "fake-ferrite-source"
version = "0.0.0"
CARGO_TOML

OUTPUT="$(env -u FERRITE_BIN -u FERRITE_CLI_BIN \
          FERRITE_SOURCE_DIR="$SOURCE_DIR" \
          PATH="${FAKE_CARGO_DIR}:${PATH}" \
          bash "${REPO_ROOT}/scripts/smoke_test.sh" 2>&1)"
STATUS=$?

assert_eq 0 "$STATUS" "smoke_test.sh exits 0 when built from FERRITE_SOURCE_DIR"
assert_contains "$OUTPUT" "Building ferrite/ferrite-cli from FERRITE_SOURCE_DIR=${SOURCE_DIR}" "smoke_test.sh reports it is building from the source dir"
assert_contains "$OUTPUT" "PONG" "smoke_test.sh output reports a PONG reply after building from source"
assert_true "$( [[ -x "${SOURCE_DIR}/target/release/ferrite" ]]; echo $? )" "built ferrite binary exists under FERRITE_SOURCE_DIR/target/release"

harness_summary
