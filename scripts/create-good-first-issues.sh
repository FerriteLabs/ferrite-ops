#!/usr/bin/env bash
# create-good-first-issues.sh — Create good-first-issue tickets on GitHub
# Run this after repos are public on GitHub.
#
# Prerequisites: gh CLI authenticated, repos accessible
set -euo pipefail

REPO="ferritelabs/ferrite"

create_issue() {
  local title="$1"
  local body="$2"
  local labels="$3"
  echo "Creating: $title"
  gh issue create --repo "$REPO" --title "$title" --body "$body" --label "$labels" 2>/dev/null \
    && echo "  ✓ Created" \
    || echo "  ⚠ Skipped (repo not accessible or issue exists)"
}

create_issue \
  "Pin model checksums in embedding catalog" \
  "**File:** \`crates/ferrite-ai/src/embedding/catalog.rs:72\`

The model catalog has \`None\` for checksums with a TODO to pin them once models are verified. Add SHA256 checksums for each model in the catalog to ensure download integrity.

**Getting started:**
1. Look at the \`ModelSpec\` structs in the catalog
2. Download each model and compute its SHA256
3. Replace \`None\` with \`Some(\"sha256:...\")\`
4. Add a test that verifies checksums match" \
  "good first issue,help wanted,ferrite-ai"

create_issue \
  "Track pub/sub state in connection handler" \
  "**File:** \`src/server/handler.rs:1028\`

The RESET command notes that pub/sub mode exit needs pub/sub state tracking in the handler. Implement pub/sub state tracking so RESET can properly clean up subscriptions.

**Getting started:**
1. Add a \`subscriptions: HashSet<String>\` field to the connection state
2. Update SUBSCRIBE/UNSUBSCRIBE handlers to track state
3. Update RESET to clear subscriptions" \
  "good first issue,help wanted,enhancement"

create_issue \
  "Add property-based tests for RESP parser" \
  "**File:** \`crates/ferrite-core/src/protocol/parser.rs\`

Add \`proptest\` tests for the RESP protocol parser to verify roundtrip encoding/decoding for all frame types (Simple String, Error, Integer, Bulk String, Array, Null).

**Getting started:**
1. Add \`proptest\` as a dev-dependency in \`crates/ferrite-core/Cargo.toml\`
2. Create arbitrary Frame generators
3. Test: encode(frame) |> parse == original frame" \
  "good first issue,help wanted,testing"

create_issue \
  "Add fuzz target for ACL rule parsing" \
  "**Directory:** \`fuzz/fuzz_targets/\`

The fuzz directory has targets for RESP, commands, config, gossip, and WAL. Add a fuzz target for ACL rule parsing (\`crates/ferrite-core/src/auth/acl.rs\`) since this is a security-critical surface.

**Getting started:**
1. Create \`fuzz/fuzz_targets/fuzz_acl.rs\`
2. Feed arbitrary bytes to the ACL rule parser
3. Verify it never panics on malformed input" \
  "good first issue,help wanted,security"

create_issue \
  "Add shell completion scripts for ferrite-cli" \
  "Generate shell completion scripts (bash, zsh, fish) for \`ferrite-cli\` using \`clap_complete\`.

**Getting started:**
1. Add \`clap_complete\` dependency
2. Add a \`--generate-completions <shell>\` flag
3. Add installation instructions to CLI docs
4. Test with: \`ferrite-cli --generate-completions bash > ferrite.bash\`" \
  "good first issue,help wanted,cli"

create_issue \
  "Implement COMMAND DOCS compatibility" \
  "Implement the Redis \`COMMAND DOCS\` subcommand (Redis 7.0+) to return documentation for each command.

This helps Redis client libraries auto-discover command metadata and improves compatibility.

**Getting started:**
1. Look at existing COMMAND subcommands in \`src/commands/handlers/\`
2. Add a \`command_docs\` handler
3. Return structured metadata (summary, since, group, complexity) for each command" \
  "good first issue,help wanted,compatibility"

create_issue \
  "Add benchmarks for persistence operations" \
  "The \`benches/\` directory has latency, throughput, tiered_storage, and vector benchmarks but no persistence benchmarks.

Add criterion benchmarks for:
- AOF write/fsync latency
- RDB snapshot creation time
- Checkpoint operations

**Getting started:**
1. Create \`benches/persistence.rs\`
2. Use \`criterion\` framework (see existing benches for patterns)
3. Add to \`[[bench]]\` in Cargo.toml" \
  "good first issue,help wanted,performance"

create_issue \
  "Improve error messages in FerriteQL parser" \
  "**File:** \`crates/ferrite-core/src/query/parser.rs\`

The FerriteQL parser could provide better error messages with line/column information and suggestions for common mistakes.

**Examples of improvements:**
- \`Unexpected token 'FORM' at line 1, col 8. Did you mean 'FROM'?\`
- \`Missing WHERE clause. Usage: SELECT ... FROM ... WHERE ...\`

**Getting started:**
1. Track position (line, column) during parsing
2. Add a \`suggest_correction()\` function for common typos
3. Include context in error messages" \
  "good first issue,help wanted,dx"

echo ""
echo "Done! Created good-first-issue tickets."
echo "Remember to also create issues on vscode-ferrite for extension-specific tasks."
