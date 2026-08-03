# Ferrite Ops — Code Audit

**Scope:** `ferrite-ops` repository only (this repo builds/deploys the `ferrite` binaries but does not vendor
their source). **Branch:** `refactor/clean-code-srp`. **Method:** static review of shell scripts, Dockerfiles,
Helm charts, and CI workflows; no changes to public Helm values, compose schemas, ports, image names, config
schema, or release version defaults.

Findings are prioritized P0 (breaks core repo promises: CI is not actually verifying behavior, or the tooling
cannot run at all) and P1 (works accidentally / is misleading, but not immediately broken). P2/P3 items are
listed for completeness and explicitly deferred — no code changes were made for them in this pass.

## Summary Table

| ID | Severity | Area | Finding | Status |
|----|----------|------|---------|--------|
| F-01 | P0 | `scripts/smoke_test.sh` | Runs `cargo build` / `./target/release/...` from the **ops repo root**, which has no `Cargo.toml`, `src/`, or `target/`. The script can never succeed in this repository as checked in. | Fixed |
| F-02 | P0 | `Dockerfile` | Build stages `COPY Cargo.toml Cargo.lock ./`, `COPY src ./src`, `COPY crates ./crates`, `COPY benches ./benches` — none of these paths exist in `ferrite-ops`. `docker build -t ferrite:test .` (the exact command CI runs) fails at the first `COPY`. | Fixed |
| F-03 | P0 | `Dockerfile` | `COPY --chown=ferrite:ferrite ferrite.toml /etc/ferrite/ferrite.toml 2>/dev/null \|\| true` — `COPY` is not a shell command; redirection/`\|\|` are not valid Dockerfile syntax and the referenced `ferrite.toml` doesn't exist in the repo (only `ferrite.example.toml` does). This line makes the whole Dockerfile invalid. | Fixed |
| F-04 | P0 | `Dockerfile` | `HEALTHCHECK ... CMD ["/usr/local/bin/ferrite-cli", "PING"] \|\| exit 1` — exec-form `CMD` arrays do not support shell operators like `\|\|`; this is invalid Dockerfile syntax (only valid in shell form). | Fixed |
| F-05 | P0 | `.github/workflows/ci.yml` | The `docker` and `helm` jobs only run `docker build` and `helm lint` — there is no functional/behavioral test gate. Given F-01..F-04, CI's Docker job was never actually exercising a working image; it was undetected because nothing else validated repo assumptions. | Fixed (added `tests/run.sh` gate before build/lint) |
| F-06 | P1 | `Dockerfile` / `.dockerignore` | `.dockerignore` excludes `target/`, `Cargo.lock`, `benches/results/`, etc. — all artifacts of a source build that has no source in this repo. Confirms the Dockerfile/`.dockerignore` pair were copied from the core `ferrite` repo without adaptation. | Documented; `.dockerignore` left as-is (still correct for the new source-fetching build — extraneous rules are harmless) |
| F-07 | P1 | `Dockerfile.moonshot`, `Dockerfile.playground` | Share the same `COPY src/crates/benches` and invalid `HEALTHCHECK`/optional-`COPY` patterns as the primary `Dockerfile` (F-02..F-04). Not exercised by `docker build -t ferrite:test .` or any CI job today. | Deferred (D-01) |
| F-08 | P2 | `scripts/backup.sh` (177 lines), `scripts/restore.sh` (294 lines), `scripts/cost-estimate.sh` (151 lines) | Only shell scripts over the 150-line threshold. Reviewed for SRP violations — see "Cohesive Long Units" below. No high-confidence SRP violation found; not refactored. | No action (by design) |
| F-09 | P3 | naming scan | Searched all shell scripts for `Manager`/`Helper`/`Utils`/`Service`/`Handler` symbol names (functions, files). Only prose matches found (e.g. "connection handler" in an issue-template string, "Helper to check a version" comment, "package-manager" GitHub topic) — no actual function/file names follow these patterns; bash scripts here use verb-based function names (`log`, `cleanup`, `usage`). No violation. | No action |
| F-10 | P0 | Linux-only code in the fetched `FerriteLabs/ferrite` v0.3.0 source | End-to-end image verification exposed two default-release compile defects: the optional `io_uring` module is compiled while its Cargo feature is disabled, and Linux-only eBPF fields are appended to immutable vectors. | Fixed in the isolated Docker build context with version-gated compatibility edits; no sibling or upstream repository is modified |
| F-11 | P3 (informational) | `scripts/backup.sh`, `scripts/restore.sh`, `scripts/cost-estimate.sh` | Pre-existing ShellCheck warnings/errors (`SC3040`, `SC2034`, `SC2144`), reproduced identically on pre-audit commit `69b90b7`. `backup.sh`/`restore.sh` declared `#!/usr/bin/env sh` while using the bash-only `set -o pipefail` (`SC3040`); `restore.sh` used `-f` against an unexpanded multi-match glob to locate the extracted backup content directory (`SC2144`); `cost-estimate.sh` declared `REGION=""` but never wired the documented `--region` flag into argument parsing (`SC2034`). | Fixed |

## Note: Previously Pre-Existing ShellCheck Findings (F-11, now fixed)

`shellcheck --severity=warning scripts/*.sh` (i.e., the same invocation as CI's `shellcheck` job) used to
surface three pre-existing issues, reproduced identically on pre-audit commit `69b90b7` and confirmed
unrelated to this audit's original P0/P1 scope: `scripts/backup.sh:23` and `scripts/restore.sh:22`
(`SC3040`, `pipefail` under `#!/usr/bin/env sh`), `scripts/cost-estimate.sh:16` (`SC2034`, unused `REGION`),
and `scripts/restore.sh:145` (`SC2144`, `-f` used with a glob). These have since been fixed: `backup.sh`/
`restore.sh` now use `#!/usr/bin/env bash` (matching every other script under `scripts/`, and making the
existing `pipefail` valid); `restore.sh`'s backup-content-directory discovery now uses an explicit `for`
loop instead of `-f` against a glob (correct for zero, one, or multiple matches); `cost-estimate.sh` now
parses and reports the `--region` flag its own usage text already documented. Regression coverage added in
`tests/test_ops_scripts_static.sh`. `shellcheck --severity=warning scripts/*.sh` now exits 0.

## Detailed Findings

### F-01 — `smoke_test.sh` assumes it lives in the `ferrite` source repo (P0)

`ROOT_DIR` resolves to the ops repo root and the script unconditionally runs
`cargo build --release --bin ferrite --bin ferrite-cli` there, then execs
`./target/release/ferrite` / `./target/release/ferrite-cli`. `ferrite-ops` has no `Cargo.toml`; this always fails.

**Fix:** see `scripts/smoke_test.sh` — binaries are now resolved in priority order:
1. `FERRITE_BIN` / `FERRITE_CLI_BIN` explicit paths (validated executable), or
2. `ferrite` / `ferrite-cli` already on `PATH`, or
3. built from `FERRITE_SOURCE_DIR` (must contain `Cargo.toml`) if explicitly provided.

No path ever defaults to `../ferrite` or any sibling directory. Missing/invalid input now produces a clear,
actionable error naming the failing variable instead of a Cargo error from the wrong directory.

### F-02, F-03, F-04 — `Dockerfile` cannot build or run (P0)

Confirmed by direct inspection: `ferrite-ops` contains no `src/`, `crates/`, or `benches/` directory, and no
`Cargo.toml`/`Cargo.lock`. The `Dockerfile`'s `planner`/`builder` stages `COPY` these paths, so `docker build`
fails immediately. Independently, the runtime stage's optional-config `COPY` and array-form `HEALTHCHECK`
with `||` are invalid Dockerfile syntax regardless of source availability.

**Fix:** `Dockerfile` now fetches the Ferrite source tarball for `FERRITE_VERSION` (default unchanged: `0.3.0`)
from `https://github.com/FerriteLabs/ferrite`, extracts it into the build context, and builds from there.
`FERRITE_VERSION` and the source URL remain overridable via `--build-arg`. The runtime stage copies the
repository's own `ferrite.example.toml` (always present) instead of a nonexistent `ferrite.toml`, and
`HEALTHCHECK` uses shell form (`CMD ferrite-cli PING || exit 1`), which is the documented way to combine a
health probe with a fallback exit code.

**Verification note:** the fetch/extract (`source` build stage) was verified against the real
`https://github.com/FerriteLabs/ferrite` repository and succeeds (also covered by
`tests/test_docker_build.sh`). Full image verification exposed F-10 after the Dockerfile's original
source/syntax problems were removed. The build now applies a narrow v0.3.0-only feature gate inside the
ephemeral build context so the optional `io_uring` module is compiled only when its Cargo feature is enabled
and the Linux eBPF response vectors remain mutable when platform fields are appended. This does not modify or
assume a sibling checkout, and version overrides do not receive the compatibility fix. The prior hard-coded
`BUILDPLATFORM=linux/amd64` default was also removed so normal builds use the host platform (amd64 in CI,
arm64 on Apple Silicon) rather than unnecessary emulation.

### F-05 — CI verification is build/lint-only (P0)

`ci.yml` had five jobs: `docker` (build only, no run/exec), `helm` (`helm lint` only, no `helm template`
rendering or values validation), `gitleaks`, `shellcheck`, and `trivy` (image scan, not behavior). Nothing
in CI ran a script, validated the smoke test could execute, or asserted the Dockerfile was structurally sane
beyond "does `docker build` exit 0" — which, per F-02..F-04, it didn't even do that.

**Fix:** `tests/run.sh` (self-contained Bash, no third-party test framework) now runs as a required step
before the `docker` and `helm` jobs in CI. It statically validates the Dockerfile invariants (no `COPY` of
non-existent paths, valid `HEALTHCHECK` syntax, source-fetch present) and exercises `smoke_test.sh`
end-to-end against fake `ferrite`/`ferrite-cli` binaries — all without a real server, real cargo build, or
Docker daemon. When a Docker daemon is available (confirmed present in this environment), an additional
fast `docker build --target source` check validates the real source fetch; it is skipped with a clear message
when no daemon is reachable. The separate Docker CI job runs the exact full `docker build -t ferrite:test .`
gate, which was also run successfully in this environment.

## Cohesive Long Units Left Intact

- **`scripts/backup.sh` (177 lines)** — single responsibility ("produce one rotated backup") expressed as one
  linear, numbered pipeline (checkpoint → copy → compress → optional S3 upload → rotate). Steps share state
  (`TMP_DIR`, `BACKUP_NAME`, `EXIT_CODE`) that would need to be threaded through separate scripts/functions
  awkwardly. No duplicated logic, no branching complexity that hides a second responsibility. Left intact.
- **`scripts/restore.sh` (294 lines)** — same shape: one responsibility ("restore one backup safely"), eight
  clearly commented sequential steps (fetch → verify → extract → detect contents → stop server → safety-copy
  current data → replace files → optional PITR → restart). The length comes from thoroughness (safety backup,
  PITR, S3 vs. local, skip-stop for containers), not from mixing unrelated concerns. Left intact.
- **`scripts/cost-estimate.sh` (151 lines)** — a single calculator (parse flags → compute → print report);
  the length is pricing-table data and formatted output, not multiple responsibilities. Left intact.

No script exhibited the kind of unrelated-responsibility mixing (e.g., "does networking AND parses CLI args
AND manages unrelated cloud resources in one function") that would justify a split under this audit's
high-confidence bar.

## Deferred Items

| ID | Description | Reason deferred |
|----|-------------|------------------|
| D-01 | Apply the same source-fetch / `HEALTHCHECK` / optional-`COPY` fixes to `Dockerfile.moonshot` and `Dockerfile.playground` (F-07) | Not exercised by `docker build -t ferrite:test .` or any current CI job; out of the explicit P0/P1 scope for this pass. Tracked here so it isn't lost. |
| D-02 | `helm template`/values-schema validation beyond `helm lint` | `helm lint` already passes cleanly for both charts; deeper template rendering checks were added to `tests/run.sh` (`helm template` dry-run) but full values-schema (JSON Schema) validation was out of scope since no `values.schema.json` exists today and adding one would be a new feature, not a bug fix. |

## Verification Performed Per Commit

- `tests/run.sh` (fake-binary smoke test + Dockerfile/Helm static checks + partial Docker build)
- `shellcheck --severity=warning` on every touched shell script
- `helm lint` / `helm template` on both charts (tool available in this environment)
- `docker build --target source -t ...` (Docker daemon available in this environment) as a real,
  fast (~10s) verification that the source-fetch stage this audit fixed actually works against the real
  `https://github.com/FerriteLabs/ferrite` repository
- A full `docker build -t ferrite:test .` validates the same end-to-end image command used by CI. The
  default v0.3.0 source compatibility guard documented in F-10 is intentionally limited to that release.
