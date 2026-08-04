#!/usr/bin/env bash
# Keeps the audit status aligned with the implemented release/runtime fixes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
AUDIT_CONTENT="$(cat "${REPO_ROOT}/AUDIT.md")"
GITLEAKS_CONTENT="$(cat "${REPO_ROOT}/.gitleaks.toml")"
GRAFANA_README_CONTENT="$(cat "${REPO_ROOT}/grafana/README.md")"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

assert_contains "$AUDIT_CONTENT" "| F-18 |" "AUDIT.md records the Moonshot finding"
assert_contains "$AUDIT_CONTENT" "| F-19 |" "AUDIT.md records the Playground finding"
for finding in F-20 F-21 F-22 F-23 F-24 F-25 F-26 F-27 F-28 F-29 F-30 F-35 F-36 F-37 F-38 F-39 F-40 F-49 F-50 F-51 F-52 F-53; do
  assert_contains "$AUDIT_CONTENT" "| ${finding} |" \
    "AUDIT.md records final-review finding ${finding} as fixed"
done
assert_contains "$AUDIT_CONTENT" "## Playground Lifecycle and Bounds Resolution" \
  "AUDIT.md records the playground lifecycle and response-bound resolution"
assert_contains "$AUDIT_CONTENT" "127.0.0.1:6380" \
  "AUDIT.md records that the Ferrite child is internal-loopback only"
assert_contains "$AUDIT_CONTENT" "ResponseBudget" \
  "AUDIT.md records the cumulative response byte budget"
assert_contains "$AUDIT_CONTENT" "none interpolate expressions" \
  "AUDIT.md records release workflow shell-injection hardening"
assert_contains "$AUDIT_CONTENT" "value_omitted: true" \
  "AUDIT.md records metadata-only hash/set key detail"
assert_contains "$AUDIT_CONTENT" "strict two-second deadline" \
  "AUDIT.md records slow-client RESP write protection"
assert_contains "$AUDIT_CONTENT" "compact typed base64 data" \
  "AUDIT.md records bounded binary HTTP conversion"
assert_contains "$AUDIT_CONTENT" "default SELECT/HELLO state" \
  "AUDIT.md records terminal proxy state-loss handling"
assert_contains "$AUDIT_CONTENT" "ferrite-ops-v0.4.0" \
  "AUDIT.md records immutable production ops revisions"
assert_contains "$AUDIT_CONTENT" "prereleases leave" \
  "AUDIT.md records stable-only RPM synchronization"
assert_contains "$AUDIT_CONTENT" "ferrite-cli -p 6380 PING" \
  "AUDIT.md records direct internal container health"
assert_contains "$AUDIT_CONTENT" "answers \`409\` for \`SELECT\`" \
  "AUDIT.md records stateless HTTP SELECT rejection"
assert_not_contains "$AUDIT_CONTENT" "executes against the actual Ferrite RESP child on \`0.0.0.0:6379\`" \
  "AUDIT.md no longer claims the Ferrite child owns the public RESP port"
assert_contains "$AUDIT_CONTENT" 'publishes `0.4.0`, `0.4`, `0`, and' \
  "AUDIT.md records normalized stable release tags"
assert_contains "$AUDIT_CONTENT" "chart's appVersion" \
  "AUDIT.md records sidecar image-version synchronization"
assert_contains "$AUDIT_CONTENT" "Fixed; D-01 resolved" "AUDIT.md marks D-01 resolved"
assert_contains "$AUDIT_CONTENT" "## Release Drift Resolution" "AUDIT.md records release drift as resolved"
assert_contains "$AUDIT_CONTENT" "D-02 is the only deferred item." "AUDIT.md leaves only D-02 deferred"
assert_not_contains "$AUDIT_CONTENT" "| D-01 |" "AUDIT.md no longer lists D-01 as deferred"
assert_not_contains "$AUDIT_CONTENT" 'compiles `playground-launcher` against `crates/ferrite-studio`' \
  "AUDIT.md no longer claims the Playground uses placeholder Studio APIs"

assert_contains "$AUDIT_CONTENT" "## Immutable Version Tags and Serialized Promotion Resolution" \
  "AUDIT.md records the split exact-build / serialized-promotion resolution"
assert_contains "$AUDIT_CONTENT" "ferrite-floating-tag-promotion" \
  "AUDIT.md records the serialized floating-tag promotion concurrency group"
assert_contains "$AUDIT_CONTENT" "docker buildx imagetools create" \
  "AUDIT.md records digest promotion via imagetools compatible with cosign"
assert_contains "$AUDIT_CONTENT" "## Release Ordering and Supersession Resolution" \
  "AUDIT.md records the version-sync ordering and supersession resolution"
assert_contains "$AUDIT_CONTENT" "## Downgrade Override Removal Resolution" \
  "AUDIT.md records the allow_downgrade removal resolution"
assert_contains "$AUDIT_CONTENT" "it was fully removed in a later" \
  "AUDIT.md's historical ordering section notes the override was later fully removed"
assert_contains "$AUDIT_CONTENT" "explicitly human-driven process" \
  "AUDIT.md records that rollbacks are deferred to a future human-driven process"
assert_contains "$AUDIT_CONTENT" "scripts/release-ordering.sh" \
  "AUDIT.md records the shared SemVer ordering guard"
assert_contains "$AUDIT_CONTENT" "suppresses \`pull_request\` events" \
  "AUDIT.md records automated-PR event suppression and reconciliation"
assert_contains "$AUDIT_CONTENT" "merge-queue" \
  "AUDIT.md records merge-time supersession enforcement"
assert_contains "$AUDIT_CONTENT" "28/28 discovered suites" \
  "AUDIT.md records the full 28-suite verification pass"

assert_contains "$AUDIT_CONTENT" "## Supersession Trust Boundary and Strict SemVer Resolution" \
  "AUDIT.md records the supersession trust-boundary and strict-SemVer resolution"
assert_contains "$AUDIT_CONTENT" "never invoked" \
  "AUDIT.md records that the candidate checkout's scripts are never invoked"
assert_contains "$AUDIT_CONTENT" "version-supersession-reconcile" \
  "AUDIT.md records the reconciliation concurrency group"
assert_contains "$AUDIT_CONTENT" "validate VERSION" \
  "AUDIT.md records the new strict-SemVer validate subcommand"

assert_contains "$AUDIT_CONTENT" "## Immutable Ops Tag Trigger Scoping Resolution" \
  "AUDIT.md records the ops tag trigger scoping resolution"
assert_contains "$AUDIT_CONTENT" "ferrite-ops-tag-<version>" \
  "AUDIT.md records the version-keyed ops tag concurrency group"
assert_contains "$AUDIT_CONTENT" "exactly \`[active-release.env]\`" \
  "AUDIT.md records the restricted ops tag trigger paths"

assert_contains "$AUDIT_CONTENT" "## Exact Image Immutability and Independent Floating-Tag Resolution" \
  "AUDIT.md records the exact-image-immutability and independent floating-tag resolution"
assert_contains "$AUDIT_CONTENT" "dev.ferritelabs.image.source-sha256" \
  "AUDIT.md records the new baked source-checksum label"
assert_contains "$AUDIT_CONTENT" "candidate-<run id>-<run attempt>" \
  "AUDIT.md records the unique throwaway candidate tag"
assert_contains "$AUDIT_CONTENT" "the exact tag is the last" \
  "AUDIT.md records that the exact tag is the last thing the release workflow writes"
assert_contains "$AUDIT_CONTENT" "1.9.1\` published after \`2.0.0" \
  "AUDIT.md records the independent floating-tag backport scenario"
assert_contains "$AUDIT_CONTENT" "29/29 discovered suites" \
  "AUDIT.md records the final 29-suite verification pass"

for finding in F-54 F-55 F-56 F-57 F-58 F-59 F-60; do
  assert_contains "$AUDIT_CONTENT" "| ${finding} |" \
    "AUDIT.md records release-hardening finding ${finding} as fixed"
done
assert_contains "$AUDIT_CONTENT" "## Deterministic Ops Tags, Event/Ref Trust, and Full Release Transaction Resolution" \
  "AUDIT.md records the current release-hardening resolution section"
assert_contains "$AUDIT_CONTENT" "release-transaction" \
  "AUDIT.md records the single full per-version release transaction"
assert_contains "$AUDIT_CONTENT" "manual dispatch" \
  "AUDIT.md records dispatch/ref trust rejection coverage"
assert_contains "$AUDIT_CONTENT" "later unrelated \`main\` advance" \
  "AUDIT.md records that later main advances do not change the ops tag target"
assert_contains "$AUDIT_CONTENT" "imjasonh/setup-crane" \
  "AUDIT.md records the pinned crane cross-registry blob copy tool"
assert_contains "$AUDIT_CONTENT" "ferrite-release-exact-<version>" \
  "AUDIT.md records the normalized-version job-level concurrency group"
assert_contains "$AUDIT_CONTENT" "never uses \`--force-with-lease\`" \
  "AUDIT.md records removal of the misleading unchanged-main lease"
assert_contains "$AUDIT_CONTENT" "refs/tags/<tag>:refs/tags/<tag>" \
  "AUDIT.md records the non-force tag-only ops push"
assert_contains "$GITLEAKS_CONTENT" 'Authorization:\s+Bearer\s+YOUR_API_KEY' \
  "gitleaks narrowly allowlists the historical documentation placeholder"
assert_contains "$GRAFANA_README_CONTENT" 'Authorization: Bearer ${GRAFANA_API_TOKEN}' \
  "Grafana import documentation reads its API token from the environment"
assert_not_contains "$GRAFANA_README_CONTENT" "Authorization: Bearer YOUR_API_KEY" \
  "Grafana import documentation no longer contains the secret-like placeholder"
assert_contains "$AUDIT_CONTENT" "D-02 is the only deferred item." \
  "AUDIT.md still leaves only D-02 deferred after this change"

harness_summary
