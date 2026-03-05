#!/usr/bin/env bash
# version-sync.sh — Check and display version references across all FerriteLabs repos.
#
# Usage:
#   ./version-sync.sh              # Check current versions
#   ./version-sync.sh 0.3.0        # Show what would need updating for a release
#
# Run from the FerriteLabs organization root directory (parent of all repos).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORG_ROOT="${SCRIPT_DIR}/../.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TARGET_VERSION="${1:-}"

echo "════════════════════════════════════════════════════════"
echo "  FerriteLabs Version Sync Check"
echo "════════════════════════════════════════════════════════"
echo ""

errors=0

# Helper to check a version in a file
check_version() {
    local repo="$1"
    local file="$2"
    local sed_pattern="$3"
    local label="$4"

    local filepath="$ORG_ROOT/$repo/$file"
    if [ ! -f "$filepath" ]; then
        echo -e "  ${YELLOW}SKIP${NC}  $repo/$file (not found)"
        return
    fi

    local found
    found=$(sed -n "$sed_pattern" "$filepath" 2>/dev/null | head -1 || true)

    if [ -z "$found" ]; then
        echo -e "  ${YELLOW}SKIP${NC}  $repo/$file (pattern not matched)"
        return
    fi

    if [ -n "$TARGET_VERSION" ]; then
        if [ "$found" = "$TARGET_VERSION" ] || [ "$found" = "v$TARGET_VERSION" ]; then
            echo -e "  ${GREEN}  OK${NC}  $label: $found"
        else
            echo -e "  ${RED}DIFF${NC}  $label: $found (expected $TARGET_VERSION)"
            errors=$((errors + 1))
        fi
    else
        echo -e "  ${GREEN}INFO${NC}  $label: $found"
    fi
}

# ── ferrite (core engine) ──────────────────────────────────────
echo "📦 ferrite/"
check_version "ferrite" "Cargo.toml" 's/^version = "\([^"]*\)".*/\1/p' "Cargo.toml workspace version"
echo ""

# ── homebrew-tap ────────────────────────────────────────────────
echo "🍺 homebrew-tap/"
check_version "homebrew-tap" "ferrite.rb" 's|.*/tags/v\([^"]*\)\.tar\.gz.*|\1|p' "Formula URL version"
echo ""

# ── ferrite-ops ─────────────────────────────────────────────────
echo "🚀 ferrite-ops/"
check_version "ferrite-ops" "charts/ferrite/Chart.yaml" 's/^appVersion: "\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "Helm chart appVersion"
check_version "ferrite-ops" "charts/ferrite/Chart.yaml" 's/^version: \(.*\)/\1/p' "Helm chart version"
echo ""

# ── vscode-ferrite ──────────────────────────────────────────────
echo "🎨 vscode-ferrite/"
check_version "vscode-ferrite" "package.json" 's/.*"version": "\([^"]*\)".*/\1/p' "package.json version"
echo ""

# ── jetbrains-ferrite ───────────────────────────────────────────
echo "🛠  jetbrains-ferrite/"
check_version "jetbrains-ferrite" "build.gradle.kts" 's/.*version = "\([^"]*\)".*/\1/p' "build.gradle.kts version"
echo ""

# ── ferrite-docs ────────────────────────────────────────────────
echo "📚 ferrite-docs/"
check_version "ferrite-docs" "website/package.json" 's/.*"version": "\([^"]*\)".*/\1/p' "package.json version"
echo ""

# ── ferrite-bench ───────────────────────────────────────────────
echo "📊 ferrite-bench/"
check_version "ferrite-bench" "docker-compose.benchmark.yml" 's/.*ferrite:\([^ ]*\).*/\1/p' "Docker image tag"
echo ""

# ── Summary ─────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
if [ -n "$TARGET_VERSION" ]; then
    if [ "$errors" -gt 0 ]; then
        echo -e "${RED}$errors version(s) need updating for release $TARGET_VERSION${NC}"
        exit 1
    else
        echo -e "${GREEN}All versions aligned with $TARGET_VERSION${NC}"
    fi
else
    echo "Run with a version argument to check alignment:"
    echo "  $0 0.3.0"
fi
