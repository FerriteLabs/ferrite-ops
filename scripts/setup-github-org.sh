#!/usr/bin/env bash
# setup-github-org.sh — One-time GitHub organization setup for FerriteLabs
# Run this after repos are public on GitHub.
#
# Prerequisites: gh CLI authenticated with appropriate permissions
set -euo pipefail

echo "=== Setting repository topics ==="

gh repo edit ferritelabs/ferrite \
  --add-topic redis,key-value,database,rust,cache,vector-search,ai,kubernetes,nosql,embedded-database \
  --description "High-performance tiered-storage key-value store. Drop-in Redis replacement built in Rust with epoch-based concurrency and io_uring persistence." \
  2>/dev/null && echo "✓ ferrite topics set" || echo "⚠ ferrite: skipped (repo not accessible)"

gh repo edit ferritelabs/ferrite-docs \
  --add-topic documentation,docusaurus,redis,ferrite \
  --description "Documentation website for Ferrite — the Rust-native Redis alternative" \
  2>/dev/null && echo "✓ ferrite-docs topics set" || echo "⚠ ferrite-docs: skipped"

gh repo edit ferritelabs/ferrite-ops \
  --add-topic docker,helm,kubernetes,monitoring,grafana,devops \
  --description "Deployment, monitoring, and packaging for Ferrite (Docker, Helm, Grafana)" \
  2>/dev/null && echo "✓ ferrite-ops topics set" || echo "⚠ ferrite-ops: skipped"

gh repo edit ferritelabs/ferrite-bench \
  --add-topic benchmarks,performance,redis,database-benchmarks \
  --description "Performance benchmarks comparing Ferrite against Redis, Dragonfly, and KeyDB" \
  2>/dev/null && echo "✓ ferrite-bench topics set" || echo "⚠ ferrite-bench: skipped"

gh repo edit ferritelabs/vscode-ferrite \
  --add-topic vscode-extension,redis,syntax-highlighting,ferriteql \
  --description "VS Code extension for Ferrite — syntax highlighting, snippets, and connection management" \
  2>/dev/null && echo "✓ vscode-ferrite topics set" || echo "⚠ vscode-ferrite: skipped"

gh repo edit ferritelabs/jetbrains-ferrite \
  --add-topic jetbrains-plugin,intellij,redis,ferriteql \
  --description "JetBrains IDE plugin for Ferrite — language support, code completion, and database tools" \
  2>/dev/null && echo "✓ jetbrains-ferrite topics set" || echo "⚠ jetbrains-ferrite: skipped"

gh repo edit ferritelabs/homebrew-tap \
  --add-topic homebrew,macos,linux,package-manager \
  --description "Homebrew formula for installing Ferrite on macOS and Linux" \
  2>/dev/null && echo "✓ homebrew-tap topics set" || echo "⚠ homebrew-tap: skipped"

echo ""
echo "=== Enabling GitHub Discussions ==="
# Note: gh CLI does not support enabling discussions directly.
# You must enable this via: Repository Settings → Features → Discussions ✓
echo "⚠ GitHub Discussions must be enabled manually:"
echo "  1. Go to https://github.com/ferritelabs/ferrite/settings"
echo "  2. Under 'Features', check 'Discussions'"
echo "  3. Recommended categories: Announcements, Q&A, Show and Tell, Ideas"

echo ""
echo "=== Social Preview ==="
echo "⚠ Social preview images must be uploaded manually via Settings → Social Preview"
echo "  Recommended: 1280×640px branded image with Ferrite logo + tagline"
echo "  Upload to all 7 repos for consistent branding"

echo ""
echo "Done! Review output above for any items that need manual action."
