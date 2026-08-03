# Ferrite Ops — Code Audit

**Scope:** `ferrite-ops` only.
**Branch:** `refactor/clean-code-srp`.
**Current operational Ferrite release:** `v0.4.0`
**Verified source SHA256:** `b4db8cc8eb0d3c2cef4a019a47d550c347df69fb8a4f77550c814fae463005cf`

## Findings

| ID | Severity | Area | Finding | Status |
|----|----------|------|---------|--------|
| F-01 | P0 | `scripts/smoke_test.sh` | Assumed the ops repository contained Ferrite source and binaries. | Fixed |
| F-02 | P0 | `Dockerfile` | Copied source paths that do not exist in this repository. | Fixed |
| F-03 | P0 | `Dockerfile` | Used invalid optional-`COPY` shell syntax. | Fixed |
| F-04 | P0 | `Dockerfile` | Mixed exec-form `HEALTHCHECK` with shell operators. | Fixed |
| F-05 | P0 | CI | Build/lint jobs did not run the repository test gate. | Fixed |
| F-06 | P1 | `.dockerignore` | Contained harmless source-build exclusions inherited from the core repository. | Documented; no action required |
| F-07 | P1 | Auxiliary Dockerfiles | Moonshot and Playground repeated invalid source/context and healthcheck assumptions. | Fixed; D-01 resolved |
| F-08 | P2 | Long shell scripts | Long units were reviewed for SRP violations. | No high-confidence violation |
| F-09 | P3 | Naming | No `Manager`/`Helper`/`Utils`-style code symbols were found. | No action required |
| F-10 | P0 | Ferrite source builds | v0.3.0 and v0.4.0 Linux sources expose optional `io_uring` code while disabled and append to immutable eBPF vectors. | Fixed with version-scoped build-context compatibility edits; no sibling repository is modified |
| F-11 | P3 | Shell scripts | Existing ShellCheck findings in backup/restore/cost scripts. | Fixed |
| F-12 | P0 | Primary image ABI | glibc builder was paired with a musl runtime. | Fixed |
| F-13 | P1 | Primary image reachability | Baked config bound container services to loopback. | Fixed |
| F-14 | P1 | Source integrity | Source archives were extracted without checksum verification. | Fixed; all Dockerfiles pin the v0.4.0 checksum |
| F-15 | P1 | Release automation | Published builds and synchronized defaults could drift from the release trigger. | Fixed; releases derive version/checksum explicitly and version sync validates/updates all three Dockerfiles together |
| F-16 | P1 | Smoke-test cleanup | Failure fixtures could orphan a background `sleep` process. | Fixed |
| F-17 | P2 | Runtime config | The documented example was not guaranteed to load in the packaged binary. | Fixed; images generate and validate their own runtime config with the exact built binary |
| F-18 | P0 | Moonshot Compose | Default Compose depended on `../ferrite`, omitted explicit release metadata, and could silently build ordinary default features. | Fixed; context is this repository, v0.4.0 version/checksum are explicit, and `forge-runtime` is the Dockerfile and Compose default |
| F-19 | P0 | Playground | The image exposed port 8080 but only started RESP; Studio environment variables were unused and health checked the wrong service. | Fixed; a repository-owned Rust launcher starts `ferrite-studio::studio::Studio` and the Ferrite RESP child, handles shutdown, and health checks `/api/health` |

## D-01 Resolution

`Dockerfile.moonshot` and `Dockerfile.playground` are now repository-independent, checksum-verified v0.4.0
builds using the `ferrite-ops` root as context.

Moonshot additionally:

- defaults to `FERRITE_FEATURES=forge-runtime` in both build and runtime stages;
- receives version, checksum, and features explicitly from `docker-compose.moonshot.yml`;
- uses the generated, build-time-validated, externally reachable image config instead of mounting the
  incompatible public example;
- records `FERRITE_COMPILED_FEATURES` for runtime evidence.

Playground additionally:

- compiles `playground-launcher` against `crates/ferrite-studio` from the fetched v0.4.0 source;
- binds Studio to `0.0.0.0:8080` and Ferrite RESP to `0.0.0.0:6379`;
- terminates and waits for the RESP child when the launcher receives SIGINT/SIGTERM;
- removes reliance on unused `FERRITE_STUDIO_*` variables;
- probes the real Studio endpoint at `/api/health`.

## Release Drift Resolution

Active operational defaults now agree on Ferrite v0.4.0:

- primary, Moonshot, and Playground Dockerfiles and source checksums;
- primary Helm chart version/appVersion and the Ferrite-tracking sidecar appVersion;
- quickstart Compose, production Argo CD/Flux overlays, and Terraform defaults;
- release workflow dispatch default;
- Moonshot Compose build arguments.

`version-sync.yml` prevalidates all three Dockerfiles before editing any file, updates both version and
checksum in one step, and validates the resulting lines. `tests/test_release_workflows.sh` functionally
replays both the successful three-file update and the structural-drift failure path.

`tests/test_active_release_versions.sh` checks the active release/deployment allowlist for stale v0.2.0 or
v0.3.0 defaults. Historical changelogs, migration notes, package changelogs, and explicit version-scoped
compatibility guards remain intentionally unchanged.

## Runtime Verification Completed

- Moonshot default Compose build produced `ferrite:moonshot`; the service became healthy, reported
  `ferrite 0.4.0`, exposed `FERRITE_COMPILED_FEATURES=forge-runtime`, returned `PONG`, and served `FN.HELP`.
- Playground default image produced `ferritelabs/playground:test`; `/api/health` returned v0.4.0 over a
  random published 8080 port and RESP `PING` returned `PONG` over a random published 6379 port.
- Playground process inspection showed the launcher supervising the Ferrite child; `docker stop` completed
  within the timeout and the container exited with code 0.
- The v0.4.0 source-stage checksum verification succeeded against the authoritative tarball.

## Deferred Items

| ID | Description | Reason deferred |
|----|-------------|------------------|
| D-02 | Add new Helm `values.schema.json` policy/schema coverage | This is a new chart policy contract rather than a release-drift/runtime defect. Existing `helm lint` and `helm template` validation remains active. |

D-02 is the only deferred item.
