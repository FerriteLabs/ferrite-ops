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
| F-12 | P0 | `Dockerfile` | Builder stage used `rust:1.95-slim-bookworm` (Debian/glibc) but the runtime stage used `alpine:3.23.4` (musl) — a genuine ABI mismatch risk for a binary compiled against glibc. | Fixed: runtime switched to `debian:bookworm-slim`, matching the builder's libc; UID 1000, paths, volumes, ports, entrypoint/CMD, labels, and HEALTHCHECK preserved unchanged. A post-build `docker run --rm ferrite:test --version` / `ferrite-cli --version` smoke test was added to `.github/workflows/ci.yml`'s `docker` job. |
| F-13 | P1 | `Dockerfile`, `ferrite.example.toml` | The Dockerfile copied the packaged `ferrite.example.toml` verbatim into the image, including its `bind = "127.0.0.1"` defaults for both `[server]` and `[metrics]` — a plain `docker run` of the published image (no compose env vars) would never be reachable via its own `EXPOSE`d/published ports. | Fixed with a new `runtime-config` build stage that generates a **container-specific** copy of the example config with both binds changed to `0.0.0.0`, plus a build-time assertion that fails the build if the substitution is incomplete. `ferrite.example.toml` itself (the public, documented default) is untouched — verified by both a static test and a Docker-daemon-dependent runtime test (`tests/test_docker_runtime_config.sh`). |
| F-14 | P1 | `Dockerfile` (`source` stage) | The pinned Ferrite source tarball was fetched and extracted with no integrity verification — a compromised mirror, MITM, or accidental version-override could silently ship different source than expected. | Fixed: added a required `ARG FERRITE_SOURCE_SHA256` (defaulting to the real, verified v0.3.0 digest `42cc9cd0...25979`) that is checked via `sha256sum -c -` before `tar` extraction; the build now fails loudly if the arg is empty or the checksum doesn't match. Verified with three Docker-based scenarios (default success, empty-checksum failure, mismatched-checksum failure) in `tests/test_docker_build.sh`. |
| F-15 | P1 | `.github/workflows/release.yml`, `version-sync.yml` | Release-publishing workflows relied on the Dockerfile's pinned default `FERRITE_VERSION`/`FERRITE_SOURCE_SHA256` build-args rather than deriving them from the actual release trigger (push tag / `repository_dispatch` / `workflow_dispatch`), risking a release image silently shipping the wrong version. | Fixed: `release.yml` now derives and semver-validates the version from the triggering event, computes the real source checksum, and passes both explicitly via `build-args`; `version-sync.yml` now also updates the Dockerfile's `FERRITE_SOURCE_SHA256` default (previously only `FERRITE_VERSION`). Ordinary CI/scan workflows (`ci.yml`, `docker-scan.yml`, `sbom.yml`) intentionally retain the Dockerfile's pinned defaults. Covered by `tests/test_release_workflows.sh`, including a functional replay against the real v0.3.0 tarball checksum. |
| F-16 | P1 | `tests/test_smoke_test_cleanup.sh` | The failure-case "mute" fixture backgrounded a wrapper shell that ran a bare `sleep 300` as a foreground child rather than `exec`ing it, so `smoke_test.sh`'s `kill "$SERVER_PID"` only killed the wrapper, orphaning a `sleep 300` grandchild for ~5 minutes on every failure-case test run. The existing assertion (`pgrep -f` against the fixture's script path) was also vacuous — it could never have detected this leak. | Fixed: the fixture now `exec`s `sleep`, so the tracked PID *is* the real server process; the test now asserts both the exact PID's death and (more importantly) that no process anywhere still matches a unique per-run marker baked into the sleep invocation — verified to actually catch the regression by temporarily reverting to the non-`exec`'d fixture and confirming the test then fails as expected. |
| F-17 | P2 (informational) | `ferrite.example.toml` vs. the real `FerriteLabs/ferrite` v0.3.0 binary's config parser | End-to-end verification discovered the packaged default config is **not actually loadable** by the pinned v0.3.0 binary: `max_memory = "1GB"` (a quoted string) is rejected because the parser expects a raw `usize` byte count, and `eviction_policy = "noeviction"` is rejected because the binary only accepts the hyphenated `"no-eviction"`. This affected `docker run` with the image's own baked-in config. | Fixed (see "F-17/D-03 Resolution" below): the image's `runtime-config` Dockerfile stage no longer reads `ferrite.example.toml` at all. It now generates the baked-in `/etc/ferrite/ferrite.toml` with the exact freshly built `ferrite` binary's own `ferrite init --minimal`, rewrites both binds to `0.0.0.0`, and asserts the result with that same binary's `--test-config` before the image is exported — so the primary image starts successfully with its default `ENTRYPOINT`/`CMD` and zero mounted or substituted config. `ferrite.example.toml` itself is untouched. `docker-compose.yml`'s own volume-mounted default (`${FERRITE_CONFIG:-./ferrite.example.toml}`) still depends on the unmodified example and is unaffected by this fix — out of scope for this item, which is limited to the image's own baked config; tracked as a follow-up if compose's out-of-the-box default is later required to work unedited. |

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

## Final End-to-End Verification (this pass)

Performed after F-11..F-17 above, with a Docker daemon, `shellcheck`, and `helm` all available locally:

- **`docker build -t ferrite:test .`** (the exact command CI runs): succeeded, produced a 115MB
  `debian:bookworm-slim`-based image (`docker images ferrite:test`).
- **Binary execution**: `docker run --rm ferrite:test --version` → `ferrite 0.3.0`;
  `docker run --rm --entrypoint /usr/local/bin/ferrite-cli ferrite:test --version` → `ferrite-cli 0.3.0`.
  Both exit 0.
- **External reachability via a published random port**: `docker run -d -P ferrite:test` (letting Docker
  assign random host ports for both `EXPOSE`d ports), then a bounded readiness loop (`redis-cli -h 127.0.0.1
  -p "$HOST_PORT" PING`, up to 40 attempts / 10s) confirmed `PONG` on the first attempt, followed by a real
  `SET`/`GET` round-trip through the published port (`OK`, then the exact value back). This directly
  exercises the F-12/F-13 fixes end-to-end with the real compiled binary, not a fake fixture. Cleanup used
  `docker rm -f "$CONTAINER_ID"` against the exact container ID captured from `docker run`'s own output
  (never a name- or pattern-based kill); confirmed via `docker ps -a` afterward that no `ferrite:test`
  container remained.
  - Note: the image's own baked-in `runtime-config` (verified separately via
    `tests/test_docker_runtime_config.sh`) already has both `bind = "0.0.0.0"` lines correctly in place.
    Because the packaged example config cannot actually be parsed by the real v0.3.0 binary (F-17,
    pre-existing and out of this pass's scope), this specific reachability run substituted a config
    generated by the real binary's own `ferrite init` (schema-guaranteed-valid) with the identical
    `127.0.0.1` → `0.0.0.0` substitution the Dockerfile's `runtime-config` stage performs, to isolate and
    prove the Docker/reachability fix independently of F-17's unrelated config-content bug. The metrics
    port (`9090`) was confirmed TCP-reachable via its own published random port; its HTTP response body was
    empty in this test, which appears to be a real-binary/core-repo behavior and is out of this pass's scope
    (not a regression from any change in this pass — the metrics *bind address* fix itself, i.e. that the
    port accepts external connections at all, is what F-13 concerns and is confirmed working).
- **`bash tests/run.sh`**: 11/11 suites passed (10 pre-existing + the new `tests/test_release_workflows.sh`
  and `tests/test_ops_scripts_static.sh` added in this pass, plus the rewritten
  `tests/test_smoke_test_cleanup.sh`).
- **`shellcheck --severity=warning scripts/*.sh tests/*.sh`**: clean (0 findings; previously 3 — see F-11).
- **`helm lint charts/ferrite charts/ferrite-sidecar`**: both charts, 0 failures (only the pre-existing
  informational `Chart.yaml: icon is recommended` notice, unrelated to this pass).
- **`helm template` (both charts)**: renders successfully with no changes to public chart values.
- **`actionlint .github/workflows/release.yml .github/workflows/version-sync.yml`**: clean.
- No stray processes or containers were left behind: `pgrep -fl "sleep 300"` empty after the test suite;
  `docker ps -a --filter ancestor=ferrite:test` empty after the final end-to-end run.

## F-17/D-03 Resolution

`ferrite.example.toml` is unmodified (git-diff-clean for this file in this pass). Instead, the Dockerfile's
`runtime-config` stage was changed to stop reading the public example entirely and generate the image's
baked-in `/etc/ferrite/ferrite.toml` from the exact freshly built `ferrite` binary produced by the `builder`
stage in the same build (never a separately downloaded or previously published binary):

1. `COPY --from=builder /app/target/release/ferrite /usr/local/bin/ferrite` into a minimal
   `debian:bookworm-slim`-based stage (same runtime shared libraries as the final `runtime` stage).
2. `ferrite init --minimal --force -o /etc/ferrite/ferrite.toml -d /var/lib/ferrite/data` — the binary's own
   config generator, schema-guaranteed to match its own parser (its `--minimal` output uses a raw
   `max_memory = 1073741824` byte count and omits `eviction_policy`, which defaults in code to
   `EvictionPolicy::NoEviction` — neither of the two values the real v0.3.0 parser rejected in the packaged
   example are present).
3. `sed -i 's/^bind = "127\.0\.0\.1"$/bind = "0.0.0.0"/'` on the generated file, then a build-time assertion
   (`grep -c` / `grep -q`) that both `[server]` and `[metrics]` binds were rewritten and no loopback bind
   remains — same reachability contract as the previous fix (F-13), now applied to the generated file
   instead of a copy of the example.
4. **New build-time assertion that directly resolves F-17**: `ferrite --test-config --config
   /etc/ferrite/ferrite.toml --data-dir /var/lib/ferrite/data`, using the exact binary and exact config file
   that will be copied into the final image. This fails the Docker build loudly if the packaged binary can't
   actually load its own baked-in config, rather than silently shipping a container that fails at `docker run`
   time.

Trade-off: `runtime-config` now depends on the full `builder` stage (it needs the real compiled binary),
whereas previously it was a cheap, Rust-build-independent stage. This is an unavoidable consequence of
resolving F-17 correctly — validating the real binary's config parser requires the real compiled binary.
`tests/test_docker_runtime_config.sh`'s header comment and `tests/run.sh`'s own docstring have been updated
to reflect this; Docker's build cache keeps repeat runs fast in practice (a cold-cache run recompiles the
Rust workspace once; this was already required by the separate `docker`/`trivy` CI jobs' own full builds).

Regression coverage:
- `tests/test_docker_runtime_config.sh` (updated): asserts the generated config is produced by `ferrite
  init` (not copied from the example), and explicitly asserts the two rejected F-17 values
  (`max_memory = "1GB"` / `eviction_policy = "noeviction"`) are absent from the baked-in config.
- `tests/test_dockerfile_static.sh` (updated): new static assertions that `runtime-config` copies the
  binary `--from=builder`, calls `ferrite init --minimal` and `ferrite --test-config`, and never references
  `ferrite.example.toml` anywhere in that stage's body.
- `tests/test_docker_image_defaults.sh` (new): builds the exact default primary image (`docker build -t
  <image> .`, no build-arg overrides — the same command CI's `docker` job runs) and runs it with its exact
  default `ENTRYPOINT`/`CMD` (`docker run -d -P`, no `-v`/`--config`/env overrides of any kind), then:
  - Confirms `PING` → `PONG`, `SET` → `OK`, and `GET` return the written value through the container's
    published random host port, using a small dependency-free RESP client built on bash's `/dev/tcp` (no
    `redis-cli`/`ferrite-cli` required on the host running `tests/run.sh`).
  - Confirms the metrics port is TCP-reachable on its own published random host port (an empty HTTP response
    body from the real binary's metrics endpoint is a separate, pre-existing, out-of-scope behavior already
    documented above — not asserted here).
  - Confirms the image's own baked-in `HEALTHCHECK` (`ferrite-cli PING`) reports `healthy`.
  - Cleans up deterministically: `docker rm -f "$CONTAINER_ID"` against the exact container ID captured from
    `docker run`'s own output, and `docker image rm -f "$IMAGE_TAG"` against the exact tag this run built —
    never a name- or pattern-based kill. Verified (3 consecutive local runs) that no container or image tag
    from this test remains afterward.

Verified locally in this pass (Docker daemon available):
- `docker build --target runtime-config -t <tag> .` succeeds and the generated config passes both build-time
  assertions.
- `docker build -t ferrite:test .` (exact CI command, no build-args) succeeds.
- `docker run -d -P ferrite:test` (exact defaults) starts a **healthy** container; `PING`/`SET`/`GET` all
  succeed through the published Redis port with zero config overrides; the metrics port is TCP-reachable
  through its published port. Cleaned up with `docker rm -f` against the exact container ID.
- `bash tests/run.sh`: all suites pass (see the updated count in the next full verification pass below).
- `shellcheck --severity=warning scripts/*.sh tests/*.sh`: clean.

Assumption: this item's scope is the primary image's own baked-in default config (per the task's explicit
"final primary image must start successfully with default ENTRYPOINT/CMD and baked config, with no
mounted/substituted config"), not `docker-compose.yml`'s separate volume-mount default, which intentionally
still points at the unmodified `ferrite.example.toml` and is a distinct, out-of-scope concern noted in the
F-17 row above.
