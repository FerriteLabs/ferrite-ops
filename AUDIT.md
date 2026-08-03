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
| F-19 | P0 | Playground | The image exposed port 8080 but only started RESP; Studio environment variables were unused and health checked the wrong service. | Fixed; the repository-owned launcher serves an interactive HTTP playground backed by the spawned Ferrite RESP server |
| F-20 | P0 | Playground API | The launcher depended on placeholder `ferrite-studio::StudioApi` responses rather than the running Ferrite server. | Fixed; `/api/health`, `/api/execute`, and `/api/keys/detail/{key}` use a real internal RESP client against `127.0.0.1:6379` |
| F-21 | P1 | Playground shutdown | Shutdown used Tokio's immediate child kill instead of forwarding SIGTERM and escalating only after a grace period. | Fixed; SIGINT/SIGTERM forwards SIGTERM, waits up to 10 seconds, then uses SIGKILL only as escalation and reaps the child |
| F-22 | P1 | Release tags | Dispatch releases could publish only the raw `v`-prefixed input because Docker metadata ran before normalized release metadata. | Fixed; normalized metadata is derived first and stable releases publish exact, major.minor, major, and latest tags |
| F-23 | P1 | Version sync | Release workflows updated the primary chart but could leave the sidecar chart on an old Ferrite image appVersion. | Fixed; every release path updates the sidecar appVersion without changing its independently versioned chart package |

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

- compiles the repository-owned `playground-launcher` as a standalone HTTP/RESP supervisor;
- serves a minimal interactive page and JSON API on `0.0.0.0:8080`;
- verifies and executes against the actual Ferrite RESP child on `0.0.0.0:6379`;
- forwards SIGTERM and waits up to ten seconds before SIGKILL escalation, then reaps the child;
- removes reliance on unused `FERRITE_STUDIO_*` variables;
- probes the real RESP-backed endpoint at `/api/health`.

## Release Drift Resolution

Active operational defaults now agree on Ferrite v0.4.0:

- primary, Moonshot, and Playground Dockerfiles and source checksums;
- primary Helm chart version/appVersion and the Ferrite-tracking sidecar appVersion;
- quickstart Compose, production Argo CD/Flux overlays, and Terraform defaults;
- release workflow dispatch default;
- Moonshot Compose build arguments.

`version-sync.yml` prevalidates all three Dockerfiles before editing any file, updates both version and
checksum in one step, and validates the resulting lines. `tests/test_release_workflows.sh` functionally
replays both the successful three-file update and the structural-drift failure path. Release metadata is
normalized before Docker tag generation, so a stable `v0.4.0` dispatch publishes `0.4.0`, `0.4`, `0`, and
`latest`; prereleases publish only their exact normalized tag.

All chart-update release paths update the primary chart's package version/appVersion and the sidecar
chart's appVersion. The sidecar chart package remains independently versioned.

`tests/test_active_release_versions.sh` checks the active release/deployment allowlist for stale v0.2.0 or
v0.3.0 defaults. Historical changelogs, migration notes, package changelogs, and explicit version-scoped
compatibility guards remain intentionally unchanged.

## Runtime Verification Completed

- Moonshot default Compose build produced `ferrite:moonshot`; the service became healthy, reported
  `ferrite 0.4.0`, exposed `FERRITE_COMPILED_FEATURES=forge-runtime`, returned `PONG`, and served `FN.HELP`.
- Playground default image produced `ferritelabs/playground:test`; `/api/health` verified RESP with `PING`
  and returned v0.4.0 over a random published 8080 port.
- Bidirectional runtime tests proved RESP writes are visible through HTTP key detail and HTTP command writes
  are visible through the public RESP port.
- Playground process inspection showed the launcher supervising the Ferrite child; `docker stop` completed
  within the timeout, the container exited with code 0, and no child/container process leaked.
- The v0.4.0 source-stage checksum verification succeeded against the authoritative tarball.

## Deferred Items

| ID | Description | Reason deferred |
|----|-------------|------------------|
| D-02 | Add new Helm `values.schema.json` policy/schema coverage | This is a new chart policy contract rather than a release-drift/runtime defect. Existing `helm lint` and `helm template` validation remains active. |

D-02 is the only deferred item.
