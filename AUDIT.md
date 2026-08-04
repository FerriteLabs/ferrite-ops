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
| F-20 | P0 | Playground API | The launcher depended on placeholder `ferrite-studio::StudioApi` responses rather than the running Ferrite server. | Fixed; `/api/health`, `/api/execute`, and `/api/keys/detail/{key}` use a real internal RESP client against `127.0.0.1:6380` |
| F-21 | P1 | Playground shutdown | Shutdown used Tokio's immediate child kill instead of forwarding SIGTERM and escalating only after a grace period. | Fixed; SIGINT/SIGTERM forwards SIGTERM, allows five seconds of child grace, bounds SIGKILL/task reaping, and joins HTTP/RESP services in parallel within a seven-second total internal budget |
| F-22 | P1 | Release tags | Dispatch releases could publish only the raw `v`-prefixed input because Docker metadata ran before normalized release metadata. | Fixed; normalized metadata is derived first and stable releases publish exact, major.minor, major, and latest tags |
| F-23 | P1 | Version sync | Release workflows updated the primary chart but could leave the sidecar chart on an old Ferrite image appVersion. | Fixed; every release path updates the sidecar appVersion without changing its independently versioned chart package |
| F-24 | P0 | Playground lifecycle | The Ferrite child owned the public `0.0.0.0:6379` port, so any unauthenticated client could `SHUTDOWN`, `CONFIG`, `DEBUG`, `MODULE`, `ACL`, `SAVE`, `BGSAVE`, `BGREWRITEAOF`, or `REPLICAOF` the shared instance, and its clean `exit(0)` was treated as success. | Fixed; the child binds `127.0.0.1:6380` only, the launcher owns the public RESP port behind one shared command policy, and any unsolicited child exit is an error |
| F-25 | P1 | Playground API parity | `/api/execute` forwarded any command straight to Ferrite, so the HTTP path bypassed whatever the RESP path enforced. | Fixed; both entry points classify commands with the same `policy` module |
| F-26 | P1 | Response bounds | Replies were bounded per bulk string and per array element only, so many individually small elements could still be buffered without limit. | Fixed; one cumulative `ResponseBudget` bounds each whole reply and the unbudgeted decode path was removed |
| F-27 | P1 | Key inspection bounds | Key detail issued `LRANGE 0 -1`, `SMEMBERS`, `HGETALL`, `ZRANGE 0 -1`, and a whole-value `GET`. | Fixed; strings/lists/zsets/streams use bounded reads, while hash/set values are omitted with type/TTL/length metadata because v0.4.0 scans are not effectively bounded |
| F-28 | P2 | Release tags | `docker/metadata-action` could still add its implicit `latest` tag outside the explicit stable gate. | Fixed; `latest=false` plus functional per-trigger assertions on the effective published tag set |
| F-30 | P1 | Playground RESP3 | The launcher's decoder understood RESP2 only, so a client that negotiated RESP3 with `HELLO 3` on the public port broke on the first map/set/double reply. | Fixed; every RESP3 type is decoded, re-encoded byte-for-byte, and converted to JSON |
| F-29 | P2 | Sidecar image | `sidecar.image.tag` defaulted to the floating `latest`, so a synchronized chart appVersion did not move the injected Ferrite image. | Fixed; the default is empty and the helper falls back to `.Chart.AppVersion` |
| F-31 | P0 | Playground command policy | Ferrite v0.4.0 dotted and root/subcommand forms such as `MIGRATE.START` could bypass an exact-name-only denylist, and outward/topology/code-execution families were incomplete. | Fixed; one explicit allowlist defaults every unknown command to rejection and applies identical normalized, argument-aware bounds over HTTP and RESP |
| F-32 | P1 | Playground decoded memory | Wire bytes bounded payload data but did not bound decoded RESP node/element overhead, and aggregate declarations allowed up to one million elements. | Fixed; independent decoded-node/element budgets are charged before allocation, aggregate size is 4,096, and re-encoding has a hard output ceiling |
| F-33 | P1 | Playground concurrency | HTTP and RESP could independently create backend work without one total operation limit. | Fixed; one launcher-owned 32-permit semaphore is shared by public RESP and HTTP execute/key-detail/health, RESP permits cover bounded response writes, and overload fails fast |
| F-34 | P1 | Playground task lifecycle | A service `JoinHandle` selected after completion was polled again during common cleanup, which can panic and hide the original exit error. | Fixed; optional handles are taken exactly once, timeout aborts are reaped, and selected errors are preserved |
| F-35 | P0 | Release workflow injection | Dispatch/workflow payloads were interpolated directly into privileged shell scripts and checksums were not uniformly validated before use/output. | Fixed; GitHub expressions enter through step environments, semver is normalized/validated, every checksum is exactly 64 hex characters, and malicious substitutions are inert in functional tests |
| F-36 | P1 | Playground unbounded reads | `SCAN` variants and `XREAD` appeared bounded by syntax but are not effectively bounded in Ferrite v0.4.0; reordered arguments could bypass the validator. | Fixed; `SCAN`/`SSCAN`/`HSCAN`/`ZSCAN`, `XREAD`, and `XREADGROUP` are absent from the public allowlist over HTTP and RESP |
| F-37 | P1 | Slow clients and resources | Backend permits ended before RESP writes, HTTP limited handlers rather than accepted connections, and writes/connections lacked strict deadlines. | Fixed; RESP permits cover timed writes, public RESP and HTTP connections are lifetime-capped, HTTP connections expire, and HTTP/RESP output budgets are reduced and tested under saturation |
| F-38 | P1 | Inline RESP parsing | Inline commands used text quoting/escaping semantics that are incompatible with binary-safe Redis wire arguments. | Fixed; public RESP accepts arrays only, rejects inline input with one bounded protocol error, and closes the connection |
| F-39 | P1 | HTTP binary JSON | Invalid UTF-8 bulk replies expanded into a JSON number per byte and only hit the HTTP output cap after allocating the body. | Fixed; conversion reserves the output budget first and returns compact typed base64 data |
| F-40 | P0 | Proxy session state | A timeout, oversized reply, parse error, or upstream I/O error dropped a stateful child connection and silently reconnected the public client on default SELECT/HELLO state. | Fixed; one bounded state-loss error is returned and the public client connection closes |
| F-41 | P0 | Request memory | Declared bulk/array request sizes were only bounded per connection (up to 8 MiB) across as many as 64 simultaneous connections, and the 300-second idle timeout let a slow client hold a fully allocated buffer almost indefinitely, so worst-case unauthenticated request memory was hundreds of MiB. | Fixed; one global in-flight request-byte budget (4 MiB) is reserved from every declared bulk/array size before its payload buffer is allocated and held through backend execution and response delivery, per-client bulk/command size limits are reduced (256 KiB / 1 MiB), the idle wait for a new command is reduced to 20 seconds, and a new 5-second read deadline bounds completing an already-declared command so a slow/partial client cannot hold its reservation open indefinitely |
| F-42 | P0 | Release integration | The canonical `version-sync.yml` only triggered on a `version-sync` repository_dispatch type that core never sends; core's actual release workflow dispatches `ferrite-release`, so the comprehensive sync never ran for a real release, while `release.yml` and `release-orchestration.yml` each independently opened a competing, chart-only version bump PR on that same real event. | Fixed; `version-sync.yml` now triggers on `ferrite-release` (keeping `version-sync` only for backward compatibility), `release.yml`'s competing chart-only `bump-chart` job is removed, and `release-orchestration.yml` delegates all ferrite-ops file updates to the canonical sync while retaining cross-repository notifications. One workflow now updates `active-release.env`, all three Dockerfiles, both charts, Compose, GitOps, Terraform, packaging, and the release workflow's own dispatch default from the real release trigger |
| F-43 | P1 | Ferrite image healthchecks | `docker-compose.quickstart.yml`'s Ferrite service healthcheck ran `redis-cli`, a binary absent from the Ferrite image (only `ferrite`/`ferrite-cli` are installed), so it could never report healthy; `gitops/kustomize/base/statefulset.yaml`'s liveness/readiness probes had the same defect. | Fixed; both now exec `ferrite-cli PING`/`/usr/local/bin/ferrite-cli PING`, matching the convention already used by the primary Dockerfile, Moonshot Dockerfile, default Compose, and the Helm chart's StatefulSet probes. All other Ferrite-image healthchecks/probes in this repository were audited and already used `ferrite-cli` or an HTTP probe of the launcher's own endpoint; the remaining `redis-cli` references are either a separate `redis:7-alpine` container used deliberately as an external test client (default Compose's `redis` comparison service, the Helm chart's connection-test pod) or documentation of a manual check run from the user's own application container, not a healthcheck baked into a Ferrite image |
| F-44 | P1 | Kustomize drift | `gitops/kustomize/base/statefulset.yaml` pinned its Ferrite image to the floating `latest` tag and was not part of `version-sync.yml`'s active-release transaction or the active-release drift tests, so it silently diverged from the canonical version pinned everywhere else. | Fixed; the base StatefulSet now pins `ferritelabs/ferrite:0.4.0`, `version-sync.yml` updates it as part of the same validated transaction as every other active pin, and both `tests/test_active_release_versions.sh` and `tests/test_release_workflows.sh` assert it tracks the active release |
| F-45 | P0 | Default Compose config | `docker-compose.yml` mounted `${FERRITE_CONFIG:-./ferrite.example.toml}` over `/etc/ferrite/ferrite.toml` by default, so an ordinary `docker compose up` silently overrode the image's own generated, build-time-validated config (F-17) with the public example the packaged binary is not guaranteed to load. | Fixed; the default mount is removed so `docker compose up` uses the image's built-in config as-is, and a custom config remains available as an explicit, documented opt-in via `docker compose -f docker-compose.yml -f docker/docker-compose.custom-config.yml up`. Quickstart and Moonshot Compose already had no such default mount. `tests/test_default_compose_config.sh` statically checks every active compose file, resolves both the default and opt-in-override configs with `docker compose config`, and builds/starts the real default service to prove the running container's config is generated by `ferrite init`, not the mounted example |
| F-46 | P1 | Release registry | `release.yml` bundled the GHCR and Docker Hub images into one unconditional `docker/metadata-action` call, so Docker Hub tags were generated (and pushing them attempted) even when the `DOCKERHUB_ENABLED` repository variable was unset/false and the adjacent Docker Hub login step never ran. | Fixed; GHCR login and metadata/tags remain always-on. One eligibility step requires `DOCKERHUB_ENABLED == 'true'` plus non-empty Docker Hub username and token before either Docker Hub login or metadata extraction can run, and a dedicated combine step merges the always-present GHCR outputs with optional Docker Hub tags before `docker/build-push-action`. A disabled/missing variable or either missing credential therefore produces zero Docker Hub tags and no Docker Hub push attempt. `tests/test_release_workflows.sh` statically asserts the shared eligibility gate and functionally replays disabled, missing-variable, missing-credential, and fully configured cases plus the combined tag output |
| F-47 | P2 | GitOps registry consistency | `gitops/kustomize/base/statefulset.yaml` pinned the active Ferrite image to the Docker Hub repository (`ferritelabs/ferrite`), the only active deployment target still defaulting to the optional Docker Hub registry instead of the always-authenticated GHCR the Helm charts and quickstart Compose already use. | Fixed; the base StatefulSet now pins `ghcr.io/ferritelabs/ferrite:0.4.0`, so the Kustomize deployment path no longer depends on Docker Hub being enabled. `version-sync.yml`, `tests/test_active_release_versions.sh`, and `tests/test_release_workflows.sh` are updated to preserve the `ghcr.io/ferritelabs/ferrite` repository and only advance its version tag on every release |
| F-48 | P0 | Custom config override default | `docker/docker-compose.custom-config.yml`'s opt-in override defaulted to mounting `${FERRITE_CONFIG:-./ferrite.example.toml}` — the same invalid public example F-17/F-45 already removed as the *default* Compose file's mount — so the one documented way to opt in to a custom config still silently loaded a config the packaged binary is not guaranteed to accept. | Fixed; the override now defaults to `${FERRITE_CONFIG:-./ferrite.toml}`, a path that does not exist unless the user creates it. `docker-compose.yml`, `docker/docker-compose.custom-config.yml`, and `README.md` no longer instruct `cp ferrite.example.toml ferrite.toml`; instead they document generating a version-valid config with the exact image's own `ferrite init --minimal --force`, then rewriting its loopback-only binds for container reachability, mirroring the same generate-then-rewrite approach the Dockerfile's `runtime-config` stage already uses internally. New `tests/test_custom_config_override.sh` builds the image, generates and rewrites a config with `ferrite init`, starts the real `ferrite` service through the documented override with that generated config, and proves the container becomes healthy, answers `ferrite-cli PING` with `PONG`, and is running with the exact byte-identical generated config (not the image's own built-in default) |
| F-49 | P0 | Immutable GitOps revision | Production Argo CD and Flux pointed at the old core-style `v0.4.0` tag, whose existing ferrite-ops object predates the synchronized chart state, and no workflow created a repository-specific immutable revision after merge. | Fixed; production uses `ferrite-ops-v0.4.0`, version sync advances `ferrite-ops-v${VERSION}`, and a least-privilege main-push workflow validates canonical metadata/charts/deployment pins before creating and pushing a non-overwritable annotated tag at the merged commit |
| F-50 | P1 | Flux image registry | Base, staging, and production Flux values used the optional Docker Hub repository while other active deployments standardized on GHCR. | Fixed; all Flux manifests use `ghcr.io/ferritelabs/ferrite`, production image-tag synchronization preserves that repository, and static/YAML/rendered/drift tests cover it |
| F-51 | P1 | RPM prereleases | Version sync accepted prerelease SemVer and wrote the hyphenated value directly into RPM `Version`, which is not the repository's RPM versioning policy. | Fixed; stable `x.y.z` releases update `Version` and reset `Release` to `1%{?dist}`, while prereleases explicitly skip the RPM spec byte-for-byte; stable and `0.5.0-rc.1` functional replays pass |
| F-52 | P1 | Playground container health | `Dockerfile.playground` health depended on `/api/health`, so saturation of the public HTTP/backend path could mark a healthy private Ferrite child unhealthy. | Fixed; the image healthcheck executes `ferrite-cli -p 6380 PING` directly against the loopback child, removes the curl-only runtime dependency, and a real-image saturation probe proves the internal check still returns `PONG` when all public HTTP connection slots are occupied |
| F-53 | P1 | HTTP database selection | `/api/execute` allowed `SELECT` even though every HTTP command uses a new backend connection, so success falsely implied database selection would persist. | Fixed; HTTP `SELECT` returns `409` with a stateless-HTTP explanation before forwarding, while one persistent public RESP connection retains `SELECT` state and a fresh RESP connection remains on database 0 |
| F-54 | P1 | Release image metadata | Candidate build images relied on `docker/metadata-action`'s auto-derived `org.opencontainers.image.version` label, which for a bare `type=raw` candidate tag bakes in the throwaway `candidate-<run id>-<run attempt>` string rather than the real release SemVer, corrupting exact-tag idempotency and later reconciliation metadata checks. | Fixed; both the GHCR and Docker Hub candidate metadata steps explicitly set `org.opencontainers.image.version` to the real normalized SemVer via metadata-action's label-overwrite input |
| F-55 | P2 | Docker Hub cross-registry backfill | `promote-exact`'s optional Docker Hub backfill copied a digest from GHCR to Docker Hub with `docker buildx imagetools create`, which does not reliably copy blob content BETWEEN different registries — it can create a manifest list referencing digests that must already exist at the destination. | Fixed; the cross-registry backfill now uses a pinned `crane` (`imjasonh/setup-crane`) to perform a real all-platform blob copy, and independently re-reads the destination digest afterward to assert it is byte-identical to the verified GHCR source digest before treating the promotion as successful; the GHCR-only (same-registry) promotion is unchanged |
| F-56 | P0 | Release transaction concurrency | `release.yml` used separate same-version locks for candidate build and exact promotion, releasing the lock while verification and smoke-test jobs ran; a duplicate run could enter that gap and race the verified promotion transaction. | Fixed; one `release-transaction` job holds `ferrite-release-exact-<version>` with `cancel-in-progress: false` through existing-tag checks, build, scan, signing/attestation, verification, smoke testing, and exact-tag promotion. Floating tags are repaired separately by complete-state reconciliation |
| F-57 | P1 | Release event/ref trust | Release version validation did not pair the triggering event with its trusted ref, so a manual or repository dispatch on a historical tag/branch could reach registry login/write work, and Cosign identity allowances were broader than the accepted event/ref pairs. | Fixed; push requires the exact `refs/tags/v<normalized-version>` candidate ref, dispatch requires `refs/heads/main` or the exact configured default branch, all checks run in `prepare` before checksum retrieval or registry-capable jobs, and the version-specific Cosign identity regexp is derived from the same trusted refs |
| F-58 | P1 | Ops tag deterministic target | `tag-ops-release.yml` treated a later `main` advance as invalidating the path-triggered release-metadata push and carried a misleading compare-and-swap lease by including an unchanged `main` ref in the tag push. | Fixed; both jobs explicitly check out the push event's immutable `github.sha`, canonical metadata is validated at that commit, version-scoped concurrency serializes duplicates, and a normal non-force tag-only push plus local/remote existence checks prevents overwrite without consulting or rebinding to a later `main` |
| F-59 | P2 | SemVer validation duplication | `release-orchestration.yml` and `tag-ops-release.yml` validated versions with locally duplicated, looser inline regexes instead of the shared `scripts/release-ordering.sh` validator, silently accepting a leading zero in the core or in a numeric pre-release identifier that the shared validator rejects. | Fixed; every version-accepting step in both workflows now calls `scripts/release-ordering.sh validate`, and each workflow normalizes (strips a leading `v`) exactly once, in its own `prepare`/`resolve` job |
| F-60 | P2 | Secret-scan verification | A placeholder API-token header in `grafana/README.md` matched gitleaks curl authorization-header rule, causing the full-history CI scan to fail on known non-secret documentation. | Fixed; the live example now reads a token from `GRAFANA_API_TOKEN`, while `.gitleaks.toml` narrowly allowlists only the historical placeholder so the existing commit remains auditable without suppressing real credentials |
| F-61 | P0 | Floating release tags | Floating tags were promoted from only the triggering release event, so dropped/coalesced events or stale/missing series could leave `latest`, major, and major.minor tags incorrect indefinitely. | Fixed; `reconcile-release-tags.yml` paginates all GHCR package versions, admits only signed immutable exact stable SemVer tags with matching digest/version/source metadata, computes every maximum through the shared strict comparator, and repairs GHCR plus an eligible digest-verified Docker Hub mirror |
| F-62 | P0 | Reconciliation manual trigger | Privileged `workflow_dispatch` let a user select an arbitrary branch containing a modified reconciliation workflow, so default-branch checkout of the helper did not prevent attacker-controlled pre-checkout or workflow-defined registry steps. | Fixed; manual repair is exposed only as the narrowly named `reconcile-release-tags` `repository_dispatch`, which GitHub resolves from the default branch. An initial no-credential step validates the event type/action, default-branch ref, and exact default-branch `github.workflow_ref` before checkout, registry login, or writes; `workflow_dispatch` is absent |
| F-63 | P0 | Docker Hub exact-tag certainty | Eligible exact releases treated ambiguous Docker Hub inspection failures as optional success, and scheduled reconciliation repaired only floating tags, so auth/network/rate-limit failures or a missed initial mirror could leave exact tags absent without failing or later repair. | Fixed; eligible Docker Hub exact-tag inspection now succeeds only on a verified digest match or a positively identified missing tag, with every other state fatal. Missing exact tags are copied from the signed, metadata-verified GHCR digest using `crane copy` and digest-verified; reconciliation audits all exact stable tags plus floating tags, no-ops on matches, refuses mismatched immutable exact tags, repairs floating mismatches, and fails closed on ambiguous inspection/verification errors |

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
- runs the Ferrite child on the internal loopback address `127.0.0.1:6380` only and serves the
  public Redis-compatible `0.0.0.0:6379` port from the launcher's own policy-enforcing RESP proxy;
- forwards SIGTERM, allows five seconds of child grace, bounds post-SIGKILL reaping, and joins the
  HTTP/RESP services concurrently so the total internal shutdown budget remains seven seconds;
- removes reliance on unused `FERRITE_STUDIO_*` variables;
- probes the real RESP-backed endpoint at `/api/health`.

## Release Drift Resolution

Active operational defaults now agree on Ferrite v0.4.0:

- `active-release.env` is the machine-readable source of truth for the active
  version and verified source SHA256;
- primary, Moonshot, and Playground Dockerfiles and source checksums;
- primary Helm chart version/appVersion and the Ferrite-tracking sidecar appVersion;
- default/quickstart/Moonshot Compose, production Argo CD/Flux overlays, the Kustomize base
  StatefulSet image, and Terraform defaults;
- release workflow dispatch default;
- Moonshot Compose build arguments and source checksums.

`version-sync.yml` triggers on the real `ferrite-release` repository_dispatch event core's release
workflow emits (`ferrite/.github/workflows/release.yml` and `release-full.yml`), keeping `version-sync`
only as a backward-compatible trigger for any external caller still using it directly. It prevalidates
the canonical file and every active release pin, stages all replacements, validates the staged result,
and only then replaces the working-tree targets. It updates all three Dockerfiles, both chart
appVersions, Compose, production GitOps, Terraform defaults/examples, and the release workflow dispatch
default together, as the single workflow responsible for that comprehensive transaction.
The competing ferrite-ops update jobs are removed from both `release.yml` and
`release-orchestration.yml`; the latter still coordinates cross-repository release notifications but
delegates every local version pin to `version-sync.yml`. `tests/test_release_workflows.sh` asserts
neither workflow touches chart files, structurally guards against those jobs being reintroduced, and
functionally replays a realistic `ferrite-release` `{version, sha256}` payload end to end through
version-sync.yml's extraction and full active-release transaction. `tests/test_release_workflows.sh`
also functionally replays both the successful full transaction and a structural-drift failure that
leaves canonical metadata unchanged. Release metadata is normalized before Docker tag generation, so a
stable `v0.4.0` dispatch publishes `0.4.0`, `0.4`, `0`, and `latest`; prereleases publish only their
exact normalized tag.

`version-sync.yml` is the only active release workflow that updates the primary chart's package
version/appVersion and the sidecar chart's appVersion. The sidecar chart package remains independently
versioned.

Release tag derivation additionally disables `docker/metadata-action`'s implicit `latest` flavor, and
`tests/test_release_workflows.sh` resolves the tag template against each trigger's real derived
outputs: `push`, `repository_dispatch`, and `workflow_dispatch` of a stable release publish exactly
`0.4.0`, `0.4`, `0`, and `latest`, while a prerelease publishes only its normalized exact tag.
All privileged `run` blocks in `release.yml`, `version-sync.yml`, and
`release-orchestration.yml` receive GitHub expressions through step `env`; none interpolate expressions
inside shell source. Supplied and computed checksums are normalized and validated as exactly 64
hexadecimal characters before use or output. Functional tests replay command-substitution payloads
against every metadata script and prove no payload executes; actionlint accepts all three workflows.

The sidecar chart's `sidecar.image.tag` now defaults to empty and resolves to the chart's
`appVersion`, so the release paths that synchronize that appVersion also move the injected Ferrite
image; `tests/test_helm_charts.sh` renders the default, an explicit override, and an appVersion bump.

`tests/test_active_release_versions.sh` checks the active release/deployment allowlist for stale v0.2.0 or
v0.3.0 defaults. Historical changelogs, migration notes, package changelogs, and explicit version-scoped
compatibility guards remain intentionally unchanged.

## Immutable Ops Release and Packaging Resolution

- Production Argo CD and Flux source revisions use the repository-specific immutable
  `ferrite-ops-v0.4.0` tag convention; neither production manifest follows `main` or `HEAD`.
- `.github/workflows/tag-ops-release.yml` runs only on relevant pushes to `main`, requests only
  `contents: write`, validates `active-release.env`, all Dockerfile version/checksum defaults, both
  chart app versions, and production GitOps source/image pins, then creates an annotated
  `ferrite-ops-v${VERSION}` at the exact merged commit. It checks local and remote refs first and never
  force-tags or force-pushes.
- `tests/test_ops_release_tag_workflow.sh` statically verifies triggers/permissions/no-force behavior,
  extracts and functionally replays both workflow scripts against a temporary bare remote, verifies the
  tag is annotated and points at the merged commit, proves a remote duplicate is refused, and proves
  chart drift blocks tagging. `actionlint` accepts the workflow.
- Every Flux base/staging/production manifest uses `ghcr.io/ferritelabs/ferrite`; production keeps the
  active image tag and immutable ops revision synchronized. `tests/test_flux_manifests.sh` performs
  static checks, parses every multi-document manifest, and renders the chart with the production image.
- RPM updates are stable-only: `x.y.z` updates `Version` and resets `Release`, while prereleases leave
  the spec unchanged and log the skip. The active stable spec now tracks `0.4.0`.

## Release Registry and Custom Config Resolution (this change)

GHCR is now the always-on, authenticated registry for every release; Docker Hub is strictly optional:

- `release.yml` extracts GHCR tags/labels in an unconditional `meta` step and Docker Hub tags/labels
  in a separate `meta_dockerhub` step gated on `if: vars.DOCKERHUB_ENABLED == 'true'` — the same
  condition already used to gate the Docker Hub login step. A `meta_combined` step merges the two
  (Docker Hub contributing nothing when its step did not run) into the single tag/label list passed to
  `docker/build-push-action`, so a disabled or missing `DOCKERHUB_ENABLED` variable generates and
  pushes zero Docker Hub tags while GHCR publishing is unaffected;
- `tests/test_release_workflows.sh` statically asserts the GHCR/Docker Hub steps are split, correctly
  gated, and combined before the build-push step, and functionally replays the combine step's own
  extracted script with an empty and a populated `DOCKERHUB_TAGS` to prove the disabled case yields no
  Docker Hub tag and the enabled case yields both;
- `gitops/kustomize/base/statefulset.yaml` now pins `ghcr.io/ferritelabs/ferrite:0.4.0` instead of the
  Docker Hub `ferritelabs/ferrite:0.4.0`, matching the GHCR default already used by both Helm charts and
  quickstart Compose, so the active Kustomize deployment path no longer depends on the optional Docker
  Hub registry. `version-sync.yml`'s validation/replacement/assertion steps, `tests/test_release_workflows.sh`'s
  functional replay, and `tests/test_active_release_versions.sh` are all updated to preserve the
  `ghcr.io/ferritelabs/ferrite` repository and only ever advance its version tag.

The custom-config override no longer defaults to the invalid public example:

- `docker/docker-compose.custom-config.yml` now mounts `${FERRITE_CONFIG:-./ferrite.toml}` (a path that
  does not exist until a user creates it) instead of `${FERRITE_CONFIG:-./ferrite.example.toml}` (F-45
  removed that same default mount from the *default* Compose file, but the opt-in override itself still
  defaulted to it);
- `docker-compose.yml`, `docker/docker-compose.custom-config.yml`, and `README.md` no longer instruct
  `cp ferrite.example.toml ferrite.toml`. They document generating a version-valid config with the
  exact running image's own `ferrite init --minimal --force`, then rewriting its loopback-only
  `[server]`/`[metrics]` binds to `0.0.0.0` for container reachability — the same generate-then-rewrite
  approach the Dockerfile's `runtime-config` build stage already uses internally (F-17);
- new `tests/test_custom_config_override.sh` statically checks the override's default mount and
  documented `ferrite init` command, then, when Docker is available, builds the real image, generates
  and rewrites a config with that image's own `ferrite init`, starts the `ferrite` service through the
  documented override with `FERRITE_CONFIG` pointed at the generated file, waits for the container to
  report healthy, confirms `ferrite-cli PING` returns `PONG`, and confirms the running container's
  `/etc/ferrite/ferrite.toml` is byte-identical to the generated file — proving the override actually
  takes effect rather than the image's own built-in default silently remaining in place;
- `tests/test_default_compose_config.sh`'s existing static/resolved-config assertions are updated to
  match: the override's documented and resolved default is `./ferrite.toml`, never
  `./ferrite.example.toml`.

## Playground Lifecycle and Bounds Resolution

The launcher is split into single-responsibility modules — `policy`, `proxy`, `resp`, `command`,
`http`, `keys`, and `supervisor` — with a test-only in-process mock Ferrite that lets both entry
points be tested end to end without a Ferrite build.

Lifecycle and administrative safety:

- the Ferrite child is spawned with `--bind 127.0.0.1 --port 6380` and is never publicly reachable;
- the launcher owns `0.0.0.0:6379`, accepts only RESP array commands, classifies each one, and forwards
  only approved commands to the child, re-encoding the real reply byte-for-byte. Inline wire commands
  receive one bounded protocol error and the public connection closes; HTTP retains its separate,
  quoted/escaped command-line parser;
- `policy` is an explicit public allowlist rather than a denylist. It permits health/introspection and
  bounded Redis-compatible string, hash, list, set, sorted-set, stream, bit, HyperLogLog, key, and
  expiry operations; every other command is rejected before forwarding. This default rejection covers
  `PLUGIN`, `AUDIT`, every Ferrite-native external/admin/execution family, and both root/subcommand and
  dotted spellings such as `MIGRATE START` and `MIGRATE.START`;
- argument-aware policy validation requires list/sorted-set windows of at most 100 elements and
  `XRANGE`/`XREVRANGE` to carry `COUNT 1..100`, limits multi-key/field/member operations to 32 items, and refuses
  whole-dataset forms including `HGETALL`, `HKEYS`, `HVALS`, and `SMEMBERS`. Redis keys and values
  remain binary-safe because only policy-relevant views are normalized. `COPY DB` is constrained to
  an existing playground database, `XTRIM`/`XADD` grammar is validated before forwarding, and bit
  offsets are capped so tiny requests cannot trigger large allocations. Public `XADD` accepts only
  server-generated `*` IDs, avoiding explicit-ID overflow that can violate stream ordering;
- `SCAN`, `SSCAN`, `HSCAN`, `ZSCAN`, `XREAD`, and `XREADGROUP` are rejected by default because their
  apparent `COUNT` bounds are not effective in Ferrite v0.4.0. This also removes reordered and
  duplicate-option bypasses such as `XREAD STREAMS COUNT ...`;
- ordinary Redis-compatible commands and the public port are preserved: a rejection does not close
  the connection and subsequent `SET`/`GET` succeed;
- `/api/execute` applies the shared command policy and answers `403` for refused commands; it
  additionally answers `409` for `SELECT` because HTTP requests are stateless/new-connection, while
  persistent public RESP connections retain allowed database selection;
- any Ferrite child exit that the launcher did not initiate is an error, including `exit(0)`;
- the proxy bounds request line length, per-argument and total request size, argument count,
  concurrent connections, client idle time, and response-write time;
- RESP2 and RESP3 are both preserved: `HELLO 3` and every RESP3 reply type (`_`, `#`, `,`, `(`,
  `!`, `=`, `%`, `~`, `>`) are decoded, charged to the response budget, and re-encoded unchanged.
- one launcher-owned 32-permit semaphore limits aggregate Ferrite backend work across public RESP
  commands and HTTP execute/key-detail/health requests; acquisition never waits, overload returns
  HTTP `429` or a RESP error without forwarding, and health deliberately follows the same simple
  fail-fast rule so the API cannot deadlock. Container health is independent of this public path and
  probes the private child directly with `ferrite-cli -p 6380 PING`. RESP permits remain held until
  the bounded response write completes or its strict two-second deadline expires;
- HTTP accepts are limited to 32 live connections rather than only limiting handler execution. Each
  accepted HTTP connection owns its permit for its full lifetime and expires after 30 seconds;
- HTTP and RESP service tasks have explicit single ownership: a selected completed handle is removed
  before common cleanup, remaining handles are taken once, and timed-out aborts are awaited.

Response and resource bounds:

- a cumulative `ResponseBudget` charges every header line and payload byte of one reply (1 MiB by
  default, 1 MiB for key detail), plus at most 8,192 decoded values and 8,192 aggregate child slots;
  aggregate declarations are limited to 4,096 entries and charged before vector allocation, so
  empty-element and deeply nested replies cannot consume unbounded object overhead;
- re-encoding is fallible and checks every append against the 1 MiB public output ceiling, so a
  decoded reply cannot grow an unbounded forwarding buffer;
- JSON API bodies have an independent 64 KiB ceiling and oversized results are replaced with a
  bounded error response;
- a timeout, over-budget reply, parse failure, or upstream I/O error returns one bounded state-loss error
  and closes the public client rather than reconnecting it with default SELECT/HELLO state;
- key detail is bounded per type — `GETRANGE` with `STRLEN` for strings and 100-element `LRANGE`,
  `ZRANGE ... WITHSCORES`, and `XRANGE ... COUNT` pages. Hashes and sets return type, TTL, length,
  `value_omitted: true`, and a clear v0.4.0 scan-omission reason without invoking `HSCAN`/`SSCAN`.

Request memory bounds:

- one launcher-owned `RequestByteBudget` (4 MiB) is shared by every public RESP client on the
  instance. Each declared `$<length>` bulk header and the declared `*<count>` argument shape are
  reserved from it immediately after being parsed and *before* the corresponding buffer is
  allocated, so worst-case declared-request memory is bounded by this one budget rather than by
  the number of open connections;
- over-budget declarations are rejected immediately, without waiting, with one bounded protocol
  error, and never allocate a payload buffer;
- a command's reservation is held through policy classification, backend forwarding, and response
  delivery, and is only released when it is dropped at the end of that command's handling;
- per-client limits are reduced to conservative playground values: a single bulk argument is capped
  at 256 KiB, one whole command at 1 MiB, the idle wait for a brand new command at 20 seconds, and a
  new 5-second read deadline bounds completing an already-declared command, so a client that declares
  a bulk length and then trickles its bytes in slowly cannot hold its reservation, or the buffer it
  guards, open indefinitely.

## Runtime Verification Completed

- 76 `playground-launcher` unit tests pass (`cargo test`), run from `tests/run.sh` via
  `tests/test_playground_launcher_unit.sh` and from a dedicated CI job, including a slow-partial-client
  test proving a stalled declared bulk is disconnected and its request-byte budget reservation is
  released at the read deadline, and a concurrent-declared-bulk test proving the shared budget caps
  simultaneous reservations and is released for reuse once a prior reservation is dropped.
- The exact Playground image build, start, and probe suite passes: `SHUTDOWN`, `PLUGIN`, `AUDIT`,
  `MIGRATE.START`, unbounded `LRANGE`, and `XRANGE` without `COUNT` are refused over both HTTP and
  RESP before forwarding; bounded basics continue to work; the child is confirmed to run with
  `--bind 127.0.0.1 --port 6380`; bounded key detail returns honest totals/truncation and explicit
  hash/set omission metadata. A `HELLO 3` session returns the real RESP3 map and keeps serving
  ordinary commands.
- The exact primary image builds and reports `ferrite 0.4.0` / `ferrite-cli 0.4.0`; the exact
  Moonshot image builds with `FERRITE_COMPILED_FEATURES=forge-runtime`, answers `PONG`, and serves
  `FN.HELP`.
- Moonshot default Compose build produced `ferrite:moonshot`; the service became healthy, reported
  `ferrite 0.4.0`, exposed `FERRITE_COMPILED_FEATURES=forge-runtime`, returned `PONG`, and served `FN.HELP`.
- Playground default image produced `ferritelabs/playground:test`; `/api/health` verified RESP with `PING`
  and returned v0.4.0 over a random published 8080 port.
- Bidirectional runtime tests proved RESP writes are visible through HTTP key detail and HTTP command writes
  are visible through the public RESP port.
- Runtime saturation fills every public HTTP connection slot: a new `/api/health` request times out
  while the image's exact internal `ferrite-cli -p 6380 PING` health command still returns `PONG`.
- HTTP `SELECT` is rejected with `409` and a stateless-request explanation; a persistent public RESP
  session successfully selects database 5 across `SET`/`GET`, while a fresh connection remains on
  database 0.
- Playground process inspection showed the launcher supervising the Ferrite child; plain `docker stop`
  (without a timeout override) completed before Docker's default SIGKILL deadline, the container exited
  with code 0, and no child/container process leaked.
- The v0.4.0 source-stage checksum verification succeeded against the authoritative tarball.
- HTTP binary replies are emitted as compact base64 objects, reject conversion before their output budget
  is exceeded, and remain bounded under concurrent requests. SELECT and RESP3/HELLO state-loss regression
  tests prove a public client is closed rather than silently reconnected on database 0 or RESP2.

## Final Verification Pass (previous change)

- `cargo test` for `playground-launcher`: 74/74 pass, including the new request-byte-budget tests.
- `bash tests/run.sh`: 21/21 suites pass (added `tests/test_default_compose_config.sh`).
- `shellcheck --severity=warning` over `scripts/*.sh` and `tests/*.sh`: clean, matching CI's own gate.
- `actionlint` over every workflow in `.github/workflows/`: clean.
- `helm lint` and `helm template` for both `charts/ferrite` and `charts/ferrite-sidecar`: clean;
  `tests/test_helm_charts.sh`: 12/12 pass.
- `docker compose config` resolves cleanly for the default, quickstart, Moonshot, TLS-override,
  HA (standalone), custom-config-override, and monitoring Compose files.
- Exact image/runtime probes (local builds, no `--no-cache` unless noted): the primary image reports
  `ferrite 0.4.0` / `ferrite-cli 0.4.0`, answers `PONG`, becomes `healthy`, and its config is generated
  by `ferrite init`; the Moonshot image answers `PONG`, serves `FN.HELP`, and reports
  `FERRITE_COMPILED_FEATURES=forge-runtime`; the Playground image (rebuilt with `--no-cache` to confirm
  the new request-byte-budget code is actually compiled in, verified via the extracted binary's
  strings) serves `/api/health`, proxies `SET`/`GET` over the public RESP port, and becomes `healthy`.
  The real `docker-compose.quickstart.yml` `ferrite` service, run against a locally built image tagged
  to match its `ghcr.io/ferritelabs/ferrite:0.4.0` reference (the actual published tag was not
  pullable from this environment — `manifest unknown`), becomes `healthy` via the fixed
  `ferrite-cli PING` check and the full quickstart demo container completes successfully end to end.

## Final Verification Pass (this change)

- `bash tests/run.sh`: 22/22 suites pass (added `tests/test_custom_config_override.sh`; all other
  suites, including the updated `tests/test_release_workflows.sh`, `tests/test_active_release_versions.sh`,
  and `tests/test_default_compose_config.sh`, pass with zero regressions).
- `shellcheck --severity=warning` over `scripts/*.sh` and `tests/*.sh`: clean, matching CI's own gate.
- `actionlint` over every workflow in `.github/workflows/`: clean, including the restructured
  GHCR/Docker Hub metadata steps in `release.yml`.
- `helm lint` and `helm template` for both `charts/ferrite` and `charts/ferrite-sidecar`: clean.
- `kubectl kustomize gitops/kustomize/base`: renders `image: ghcr.io/ferritelabs/ferrite:0.4.0`.
- `docker compose config` resolves cleanly for the default, default+custom-config-override,
  default+TLS-override, quickstart, Moonshot, and HA (standalone) Compose files, and for the default
  file under the `monitoring` profile.
- Exact image/runtime probes (local builds): the primary image reports `ferrite 0.4.0` /
  `ferrite-cli 0.4.0` and answers `PONG`; the Moonshot image answers `PONG` and serves `FN.HELP`; the
  Playground image's `/api/health` reports `{"status":"ok","version":"0.4.0",...}`.
- The new documented custom-config override flow was exercised end to end via
  `tests/test_custom_config_override.sh`: the real image's own `ferrite init --minimal --force`
  generated a config, its loopback binds were rewritten to `0.0.0.0`, the `ferrite` service was started
  through `docker compose -f docker-compose.yml -f docker/docker-compose.custom-config.yml up` with
  that generated config, the container became `healthy`, `ferrite-cli PING` returned `PONG`, and the
  running container's `/etc/ferrite/ferrite.toml` was confirmed byte-identical to the generated file
  (not the image's own built-in default).
- No test/lint/build artifacts, temporary containers, or images were left behind; `git status` is
  clean after committing.

## Final Verification Pass (immutable ops and playground sessions)

- `cargo fmt --manifest-path playground-launcher/Cargo.toml --check`,
  `cargo clippy --manifest-path playground-launcher/Cargo.toml --all-targets -- -D warnings`, and
  `cargo test --manifest-path playground-launcher/Cargo.toml` pass; the Rust suite is 76/76.
- `bash tests/run.sh` passes all 24/24 discovered suites. This includes the new immutable-tag,
  Flux-rendering, stable/prerelease RPM, HTTP `SELECT`, and public-saturation/internal-health coverage;
  the exact Playground runtime suite is 93/93.
- `shellcheck --severity=warning scripts/*.sh tests/*.sh` and
  `actionlint .github/workflows/*.yml` pass with no findings.
- Helm 4.2.0 lints both charts and renders the primary default/HA and sidecar templates successfully.
  `kubectl kustomize` renders the base plus development, staging, and production overlays.
- Docker Compose 2.29.7 resolves the default, monitoring profile, custom-config override, TLS
  override, quickstart, Moonshot, HA, and standalone monitoring files. The files that deliberately
  require `GRAFANA_ADMIN_PASSWORD` were validated with a non-secret verification-only value.
- The full test suite builds and runs the default image, default Compose service, custom-config
  override, and Playground image. The default image answers `PING`, serves `SET`/`GET`, exposes
  metrics, and becomes healthy; the custom-config flow becomes healthy and mounts the exact generated
  config; the Playground image passes direct-child health under public HTTP saturation, HTTP/RESP
  policy checks, persistent RESP `SELECT`, RESP3, bounds, and clean shutdown.
- An additional exact `Dockerfile.moonshot` runtime probe builds with
  `FERRITE_COMPILED_FEATURES=forge-runtime`, becomes healthy, answers `PONG`, and serves `FN.HELP`.
  `docker-compose.moonshot.yml` then starts both primary and replica healthy; both answer `PONG` and
  the primary serves `FN.HELP`.
- Verification containers, volumes, and temporary images were removed. No required external tool was
  unavailable.

## Immutable Version Tags and Complete-State Reconciliation Resolution

Container releases now separate the exact, immutable version tag from the floating tags so an
out-of-order, retried, or concurrent release can never overwrite `latest`/`<major>`/`<major>.<minor>`
with an older image:

- `release.yml`'s version-locked transaction publishes a unique candidate digest first and creates the
  exact version tag only after verification; different versions still build concurrently without racing.
- `reconcile-release-tags.yml` runs after successful exact release workflows, on the narrowly named
  `reconcile-release-tags` repository dispatch, and on a conservative weekly repair schedule. One fixed
  `ferrite-release-tag-reconciliation` concurrency group serializes the complete enumerate/verify/plan/apply
  cycle; pending events may coalesce safely because no run depends on one event's release version.
- Manual repair uses `gh api --method POST repos/ferritelabs/ferrite-ops/dispatches
  -f event_type=reconcile-release-tags`; there is no `workflow_dispatch`. GitHub resolves the dispatch from
  the default branch, and the first step validates the event/action, default-branch ref, and exact
  default-branch workflow definition before checkout or registry authentication. GHCR package versions are
  retrieved with `gh api --paginate --slurp` at 100 records per page. Floating,
  candidate, v-prefixed, invalid, and prerelease tags are rejected as sources. Every exact stable source
  must resolve to its API digest, carry consistent exact-version and one identical source-SHA label on every platform,
  and pass the release workflow's Cosign identity verification. Selected sources are re-resolved and re-verified
  immediately before each GHCR or Docker Hub mutation, so deletion of a separate signature artifact cannot exploit
  a plan/apply time-of-check/time-of-use gap.
- `scripts/release-ordering.sh` is the shared SemVer-precedence engine (`semver-cmp`/`ge`/`classify`),
  and `scripts/reconcile-release-tags.py` delegates every validation/comparison to it while purely computing
  the maxima for stable overall (`latest`), every major, and every major.minor series.
- GHCR floating tags are applied to the selected signed digests without rebuilding and verified afterward.
  Docker Hub runs only when explicitly enabled with both credentials. It audits every exact stable tag and
  desired floating tag, copies missing exact tags and missing/stale floating tags from verified GHCR with
  `crane copy`, independently verifies every destination digest, refuses to overwrite a mismatched exact tag,
  and treats authentication, network, rate-limit, empty-digest, or other ambiguous state as fatal.

## Release Ordering and Supersession Resolution (this change)

Version-sync now refuses to move the canonical `active-release.env` backwards, and a merge-time check
stops a stale PR from doing the same:

- `version-sync.yml` gains a `Guard release ordering` step that classifies the candidate against the
  checked-out canonical `active-release.env` with the shared guard. NEWER proceeds; EQUAL with an
  identical source checksum is a no-op; EQUAL with a differing checksum fails loudly; OLDER is skipped.
  The sync, RPM, and PR steps are gated on the guard. (At the time of this change, a manual
  `workflow_dispatch`-only override existed for the `OLDER` case; it was fully removed in a later
  change — see "Downgrade Override Removal Resolution" below — and no override remains today.)
- New `version-supersession.yml` compares proposed `active-release.env` metadata against the current
  tip of `main` for normal pull requests and merge-queue candidates. Because GitHub intentionally
  suppresses `pull_request` events for the automated PRs created with `GITHUB_TOKEN`, it also
  reconciles after every Version Sync run and whenever `main` advances, writing the same required
  success/failure check directly onto each open `version-sync/*` PR head. Older versions and
  same-version checksum rewrites fail, so event suppression cannot leave a stale automated PR clean.
- `tests/test_version_sync_ordering.sh` (19 checks) functionally replays the guard for
  newer/equal-same/checksum-mismatch/older/manual-override/malicious-input cases;
  `tests/test_version_supersession.sh` (22 checks) verifies pull-request, merge-queue, post-sync, and
  main-advance enforcement wiring and replays the comparison against temporary Git remotes for
  newer/stale/equal/checksum-conflict PRs. Its batch reconciliation replay also proves malformed
  metadata fails closed without preventing later stale PRs from receiving failure checks.
  `actionlint` accepts every workflow.

## Final Verification Pass (immutable version tags and release ordering)

- `bash tests/run.sh` passes all 28/28 discovered suites, including the four new release-ordering,
  promotion, version-sync-ordering, and supersession suites.
- `actionlint .github/workflows/*.yml` passes with no findings, including the split build/promote
  `release.yml`, the guarded `version-sync.yml`, and the new `version-supersession.yml`.
- `shellcheck --severity=warning scripts/*.sh tests/*.sh` passes with no findings, including the new
  `scripts/release-ordering.sh` and its tests.
- No production behavior outside the release/version-sync workflows and the shared ordering script was
  changed; existing Docker, Helm, Compose, GitOps, Terraform, and playground coverage is unchanged and
  still green.

## Supersession Trust Boundary and Strict SemVer Resolution (this change)

Two hardening gaps remained after the prior release-ordering/supersession work: the merge-time
supersession check executed a script from the untrusted PR/merge-queue candidate checkout, and the
shared ordering engine used Bash 64-bit arithmetic and a permissive SemVer shape that both break down
at the edges.

- `version-supersession.yml`'s `supersession` job now checks out the untrusted PR/merge-queue candidate
  into its own `candidate/` directory purely to read `active-release.env` as inert data (`sed`), and
  separately checks out the trusted base branch (`main`) into `trusted/`. Only
  `trusted/scripts/release-ordering.sh` is ever invoked — a PR that replaces
  `scripts/release-ordering.sh` with a malicious script (e.g. one that always reports `NEWER` to bypass
  the guard) has that replacement never invoked, and can no longer influence its own classification,
  because that file is never read from the candidate checkout at all.
- `reconcile-automated-prs` gains a `version-supersession-reconcile` concurrency group with
  `cancel-in-progress: true`, and reads and validates `origin/main`'s `active-release.env` in a dedicated
  step immediately before the classification/posting loop, instead of relying on the job's initial
  checkout. Together these prevent an older, slower reconciliation run (e.g. an overlapping
  `workflow_run` and `push` trigger) from overwriting a newer run's correct check results with stale
  ones.
- `scripts/release-ordering.sh` now enforces strict SemVer 2.0: the `MAJOR.MINOR.PATCH` core and any
  purely-numeric pre-release identifier must not have a leading zero (a bare `0` remains valid; alphanumeric
  identifiers that merely start with a digit, e.g. `0a1`, are unaffected). Numeric comparison (core fields
  and numeric pre-release identifiers) now compares normalized digit-string length first, then lexical
  order for equal-length strings, entirely replacing the previous `((10#a < 10#b))` Bash arithmetic —
  which is bounded by 64-bit signed range and cannot correctly compare version fields with more than
  ~19 digits. A new `validate VERSION` subcommand exposes the strict check standalone.
- `tests/test_version_supersession.sh` (37 checks) adds a functional replay of a malicious PR shipping
  its own `release-ordering.sh` (always reports `NEWER`, leaves an execution marker) and proves it is
  both rejected and never executed, plus a freshness replay proving a later reconciliation read observes
  main's advanced tip rather than a value cached from an earlier checkout.
- `tests/test_release_ordering.sh` (41 checks) adds coverage for 38-40 digit numeric fields (core and
  pre-release), leading-zero rejection in the core and in pre-release identifiers, legitimate bare-zero
  fields, alphanumeric identifiers that start with a digit, and `classify`'s leading-zero rejection.

## Downgrade Override Removal Resolution (this change)

`version-sync.yml` previously accepted a manual `allow_downgrade` `workflow_dispatch` input that let an
operator force a sync backwards past the canonical `active-release.env`. This override is removed
entirely:

- The `allow_downgrade` workflow input, the `ALLOW_DOWNGRADE` environment variable, and the override
  branch of the `OLDER` case are all gone. Both automated (`repository_dispatch`) and manual
  (`workflow_dispatch`) sync runs now handle an `OLDER` classification identically: skip, with no
  override of any kind. A stray `ALLOW_DOWNGRADE=true` left in a step's environment has no effect, since
  the variable is no longer read anywhere.
- A real rollback is an intentional, human-operated decision with implications far beyond a version
  bump (registry tags, GitOps revisions, RPM `Release` bumps, downstream SDK/IDE updates, ...), so it is
  deliberately out of scope for this workflow. Rollbacks are deferred to a future, separate,
  explicitly human-driven process rather than a workflow input.
- `tests/test_version_sync_ordering.sh` (22 checks) asserts `allow_downgrade`/`ALLOW_DOWNGRADE` are
  absent from both the workflow source and the extracted guard step, and functionally replays that an
  older candidate is always skipped — including when a stray `ALLOW_DOWNGRADE=true` is present in the
  step's own environment.

## Immutable Ops Tag Trigger Scoping Resolution (this change)

`tag-ops-release.yml` previously triggered on a push to `main` touching any of ~15 release-pin paths
(Dockerfiles, both charts, Compose, GitOps, packaging, `release.yml`'s own default), which meant an
unrelated push that happened to touch, say, `docker-compose.yml` without any corresponding
`active-release.env` bump would still re-run this workflow.

- The `push` trigger's `paths` filter is now exactly `[active-release.env]` — this workflow runs only
  when the canonical release metadata itself changes, never for an unrelated pin-only push. Every other
  release pin is still cross-validated against `active-release.env` in the `Validate canonical ops
  release` step before tagging, so drift between them and the canonical version still fails loudly; it
  simply no longer re-triggers the workflow on its own.
- A new `resolve` job reads the canonical version from the exact push commit, and the `tag` job (which
  depends on it) uses a `ferrite-ops-tag-<version>` concurrency group (`cancel-in-progress: false`) keyed
  on that resolved version, so a retried or duplicate push for the same version serializes instead of
  racing a concurrent tag creation/push.
- Both jobs explicitly check out `github.sha`, and the `tag` job validates and tags that exact push commit
  without consulting the later state of `main`. The final push contains only the new annotated tag ref,
  is non-force, and is protected by local/remote existence checks; a later unrelated `main` advance cannot
  change the target, and a duplicate event cannot overwrite it.
- `tests/test_ops_release_tag_workflow.sh` (36 checks) asserts the trigger's `paths` list is exactly
  `[active-release.env]`, the `resolve`/`tag` job split and version-keyed concurrency, and functionally
  proves that a later `main` advance leaves the push-SHA target unchanged while a duplicate same-version
  event is rejected without rebinding the existing tag.

## Exact Image Immutability and Independent Floating-Tag Resolution (this change)

Two further release-integrity gaps remained: `release.yml` pushed the exact, immutable version tag
directly as part of the multi-arch build/sign/attest pipeline (so a mid-pipeline failure could leave a
signed-but-not-fully-verified exact tag, or a concurrent same-version run could race it), and floating-tag
promotion advanced `latest`/`<major>`/`<major>.<minor>` as a single bundle gated on one version (`latest`'s),
which would incorrectly skip a legitimate backport to an older series.

- `release.yml` uses one `release-transaction` job-level `ferrite-release-exact-<version>` concurrency
  group (`cancel-in-progress: false`), keyed on the normalized output of the trusted `prepare` job. The lock
  covers the complete exact-release transaction while different versions still build fully concurrently.
- The transaction's `Check existing exact GHCR tag` step runs BEFORE any build step and decides
  whether this exact version has already been fully published: it reads the existing tag's
  `org.opencontainers.image.version` and a new `dev.ferritelabs.image.source-sha256` label (now baked by
  the Dockerfile from a `FERRITE_SOURCE_SHA256` global build-arg, redeclared bare in the `source` and
  `runtime` stages so it correctly inherits any `--build-arg` override the same way `FERRITE_VERSION`
  already did) and verifies its cosign signature. A full match is treated as an idempotent no-op — every
  build/scan/sign/SBOM/attest step below is skipped entirely; a mismatched label or an unverifiable
  signature FAILS the run immediately, before any build step runs, rather than silently diverging from or
  rebuilding over a corrupted or unsigned existing release.
- When not idempotent, the transaction builds and pushes ONLY a unique, throwaway
  `candidate-<run id>-<run attempt>` tag — never the exact version tag — then scans it with Trivy
  (`CRITICAL,HIGH`, blocking) before signing it with cosign and generating/attaching/attesting its SBOM and
  SLSA provenance, all against that candidate tag/digest.
- The transaction's final exact-promotion step is the ONLY place that ever creates or touches the exact
  version tag: after signature/attestation verification and smoke testing it re-checks immediately beforehand
  whether the exact tag already exists on GHCR and, independently, on the optional Docker Hub mirror — a
  match is left untouched (idempotent no-op), and a tag pointing at a *different* digest is refused
  outright on EITHER registry rather than overwritten. Docker Hub promotion always copies from the
  signed, metadata-verified GHCR digest, so an idempotent retry can safely backfill a mirror that was
  disabled during the original release without assuming that digest already exists in Docker Hub.
  Because exact promotion runs only after every prior transaction step has succeeded, a failed run can never leave an
  unverified exact tag behind: the exact tag is the last thing this workflow ever writes, not the first.
  The throwaway candidate tag is intentionally left in the registry as a harmless, clearly-named artifact;
  registry-level retention/cleanup of `candidate-*` tags is a documented follow-up rather than implemented
  here, since it is a registry-hygiene concern, not a correctness gap — a candidate tag is never treated
  as, confused with, or promotable in place of, an exact release tag.
- Complete-state reconciliation independently computes each of `latest`, `<major>`, and `<major>.<minor>`
  from all trusted exact tags. A backport (for example `1.9.2` published after `2.0.2`) leaves `latest`,
  `2`, and `2.0` on `2.0.2` while selecting `1.9.2` for both `1` and `1.9`; a previously missing `1.8`
  series is created from its own maximum in the same run.
- `tests/test_exact_image_immutability.sh` (51 checks) functionally replays `check_existing` (first
  publish, verified idempotent match, mismatched version/checksum labels, an unsigned existing tag) and
  exact promotion (first publish, idempotent retry, a simulated concurrent same-version run, a digest
  mismatch on GHCR and independently on Docker Hub, a matching Docker Hub tag, a missing Docker Hub tag
  backfilled from verified GHCR, ambiguous Docker Hub authentication/network/rate-limit inspection,
  and invalid version/digest input) against a stateful fake registry and fake `cosign`.
  `tests/test_release_reconciliation.sh` (100 checks) covers two paginated GHCR fixture pages, three rapid
  releases, a backport, prerelease/candidate/floating rejection, missing series, unsigned exact sources,
  malicious-branch dispatch rejection, missing/matching/mismatched Docker Hub exact tags, ambiguous
  Docker Hub inspection, stale floating tags, and digest mismatches. Its functional replay deliberately
  drops every intermediate release event and proves one final reconciliation repairs all eligible tags.
  `tests/test_release_workflows.sh` is updated throughout for the candidate-tag build target.

## Final Verification Pass (trusted supersession, exact-image immutability, strict SemVer, independent floating tags)

- `bash tests/run.sh` passes all 29/29 discovered suites, including `test_exact_image_immutability.sh`,
  `test_release_reconciliation.sh`, `test_release_workflows.sh`, `test_version_sync_ordering.sh`,
  `test_ops_release_tag_workflow.sh`, `test_version_supersession.sh`, and `test_release_ordering.sh`.
- `actionlint .github/workflows/*.yml` passes with no findings, including the rewritten `release.yml`,
  `version-sync.yml`, `version-supersession.yml`, and `tag-ops-release.yml`.
- `shellcheck --severity=warning scripts/*.sh tests/*.sh` passes with no findings.
- `helm lint charts/ferrite charts/ferrite-sidecar` both pass (unchanged by this change; re-verified since
  D-02 remains the only deferred chart-related item).
- A full, uncached `docker build` of the default image (zero `--build-arg` overrides) was exercised via
  `tests/test_docker_image_defaults.sh`, confirming the `FERRITE_SOURCE_SHA256` global-ARG/bare-redeclare
  restructuring still produces a working, PING/SET/GET-responsive, health-checked container from the
  Dockerfile's own pinned defaults.
- No production behavior outside the release/version-sync/supersession workflows, the shared ordering
  script, and the Dockerfile's ARG/LABEL scoping was changed; existing Helm, Compose, GitOps, Terraform,
  and playground coverage is unchanged and still green.

## Deterministic Ops Tags, Event/Ref Trust, and Full Release Transaction Resolution

This pass supersedes the earlier split-lock and unchanged-main-lease design while retaining the candidate
metadata, cross-registry copy, strict SemVer, and secret-scan fixes from F-54/F-55/F-59/F-60.

- **F-56 (full per-version transaction lock).** `release.yml` now has only `prepare`, one
  `release-transaction`, and no event-specific floating promotion job. The transaction uses
  `ferrite-release-exact-<version>` with `cancel-in-progress: false` and keeps that one lock from the
  existing-exact-tag check through candidate build, Trivy scan, Cosign signing/SBOM/SLSA attestation,
  signature and attestation verification, live smoke testing, and the final exact-tag read/compare/write.
  There is no separate build or exact-promotion job and therefore no interval in which a duplicate run can
  enter after build serialization has ended but before a verified promotion completes. Floating tags are
  derived afterward from the complete set of verified exact stable tags, not from this transaction's event.
- **F-57 (event/ref trust pairing).** The trusted `prepare` step now validates the event/ref pair before
  checksum retrieval and before the registry-capable transaction can start. A push is accepted only when both
  the tag name and full ref are exactly `v<normalized-version>` / `refs/tags/v<normalized-version>`.
  `workflow_dispatch` and `repository_dispatch` are accepted only on `refs/heads/main` or the exact configured
  default branch; historical tags and arbitrary branches fail closed. The version-specific
  `certificate_identity_regexp` output is derived from this same repository/workflow/version/ref trust set, so
  Cosign verification cannot admit an identity that the release trigger validation itself rejects.
- **F-58 (immutable ops tag target).** `tag-ops-release.yml` remains path-triggered only by exactly
  `[active-release.env]`, but its immutable target is now the push event's exact `github.sha` (the release
  metadata merge commit). Both jobs explicitly check out that SHA, canonical metadata and every synchronized
  deployment pin are validated at that commit, and `ferrite-ops-tag-<version>` queues duplicate events without
  cancellation. The workflow never fetches or writes `origin/main`, never uses `--force-with-lease`, and pushes
  only `refs/tags/<tag>:refs/tags/<tag>` without force after local and remote non-existence checks. A later
  unrelated `main` advance therefore cannot change the deterministic target, while duplicate same-version
  events cannot overwrite or rebind the existing annotated tag.

Release-focused functional coverage now includes 200 checks in `tests/test_release_workflows.sh`, 51 checks in
`tests/test_exact_image_immutability.sh`, 36 checks in `tests/test_ops_release_tag_workflow.sh`, and 100 checks in
`tests/test_release_reconciliation.sh`. The tests extract and replay the real shell steps, including release manual
dispatch from a tag rejection before checksum access, a push-ref/candidate mismatch, non-main configured
default-branch acceptance, exact transaction step ordering, later unrelated `main` advancement, duplicate tag
non-overwrite, idempotent/mismatched exact image behavior, Docker Hub auth/network/rate-limit ambiguity,
cross-registry exact backfill, paginated exact-tag discovery, malicious-branch reconciliation rejection, and
single-run repair after coalesced/dropped release events.

## Reconciliation Dispatch and Docker Hub Exact-Tag Resolution

- **F-62 (default-branch-only manual repair).** `reconcile-release-tags.yml` no longer exposes
  `workflow_dispatch`. Operators use only the `reconcile-release-tags` repository dispatch, whose workflow
  definition GitHub loads from the default branch. Before checkout, GHCR login, Docker Hub login, or any write,
  the workflow checks the event/action, `refs/heads/<default branch>`, and the exact
  `<repository>/.github/workflows/reconcile-release-tags.yml@refs/heads/<default branch>` workflow ref. The
  extracted guard rejects a simulated malicious branch definition and unrelated dispatch action.
- **F-63 (exact mirror certainty and repair).** Once Docker Hub is enabled with complete credentials, the exact
  release can continue only after `crane digest` proves a match or positively reports the exact tag missing.
  Authentication, network, rate-limit, empty-result, and other ambiguous failures abort the release. A missing
  exact tag is copied from the already verified GHCR digest with the real cross-registry `crane copy` path and
  re-read for digest equality. Scheduled/manual/post-release reconciliation now derives a Docker Hub plan
  containing every verified exact stable tag plus all desired floating tags: matching tags no-op, missing exact
  tags are backfilled, mismatched exact tags fail without overwrite, stale floating tags are repaired, and every
  copy is digest-verified.

## Final Verification Pass (dispatch hardening and Docker Hub exact-tag repair)

- `bash tests/test_release_workflows.sh`, `bash tests/test_exact_image_immutability.sh`,
  `bash tests/test_ops_release_tag_workflow.sh`, and `bash tests/test_release_reconciliation.sh` pass
  (200, 51, 36, and 100 checks respectively); `bash tests/test_audit_status.sh` passes 96 checks.
- `bash tests/run.sh` passes all 29/29 discovered suites.
- `shellcheck --severity=warning scripts/*.sh tests/*.sh tests/lib/*.sh` and
  `actionlint .github/workflows/*.yml` pass with no findings.
- `cargo fmt --manifest-path playground-launcher/Cargo.toml --check`,
  `cargo clippy --manifest-path playground-launcher/Cargo.toml --all-targets -- -D warnings`, and
  `cargo test --manifest-path playground-launcher/Cargo.toml` pass (76/76 tests).
- `helm lint --strict` and `helm template` pass for both charts, including the primary chart HA values render;
  D-02 remains the only deferred policy/schema item.
- Docker Compose configuration rendering passes for the default, custom-config override, quickstart, Moonshot,
  HA, TLS, and monitoring variants exercised by the repository tests.
- `trivy config --severity HIGH,CRITICAL --exit-code 1` reports zero misconfigurations for all three
  Dockerfiles, the CI-equivalent Trivy image scan reports zero HIGH/CRITICAL fixed vulnerabilities, and
  `gitleaks detect --source . --verbose --redact` passes the full-history secret scan.
- `docker build -t ferrite:verification .` succeeds, and both `ferrite --version` and `ferrite-cli --version`
  execute from the resulting runtime image, preserving the CI ABI/runtime verification.

## Multi-Platform Exact-Tag Label Trust and Canonical Checksum Truth Resolution (this change)

Two related trust gaps remained even after the exact-image-immutability and reconciliation hardening
above: release.yml's own pre-build "Check existing exact GHCR tag" step only ever inspected the FIRST
platform of a multi-platform `.Image` manifest when comparing an existing exact tag's baked labels
against this run's version/checksum, silently ignoring every other platform; and three workflows that
each needed the canonical Ferrite source-archive checksum (`version-sync.yml`, `release-orchestration.yml`,
and — for its own always-computed value — `release.yml`) each duplicated their own inline
download/validate logic, and two of them (`version-sync.yml`, `release-orchestration.yml`) would use a
caller-supplied checksum from a `repository_dispatch` payload or manual `workflow_dispatch` input
directly AS the release's checksum whenever one was supplied, never downloading or comparing it against
the real tagged source at all.

- **Shared multi-platform exact-tag label verification.** `scripts/verify-exact-image-labels.sh` is a new,
  independently tested helper that normalizes `docker buildx imagetools inspect ... --format
  '{{json .Image}}'` output — a single-platform `{"config": {...}}` object OR a multi-platform map of
  `"<platform>": {"config": {...}}` — into a list of every platform's labels and requires ALL of them,
  not just the first, to satisfy one of two modes:
  - `exact <version> <sha256>`: every platform's `org.opencontainers.image.version` and
    `dev.ferritelabs.image.source-sha256` labels must equal the caller's specific known-correct values
    exactly. `release.yml`'s "Check existing exact GHCR tag" step now delegates to this mode with its own
    freshly computed version/checksum, closing the previous first-platform-only gap: a mixed-platform
    manifest (say, a correct amd64 config paired with a stale or corrupted arm64 config) now fails the
    idempotency check instead of silently passing.
  - `consistent <version>`: every platform's version label must equal the exact tag's own name, every
    platform's source-checksum label must be a well-formed 64-hex-digit value, and every platform must
    share the exact same checksum value as every other platform. `reconcile-release-tags.yml`'s "Verify
    every exact stable GHCR source" step now delegates to this mode — reconciliation has no independently
    known canonical checksum for an arbitrary historical exact tag, but still refuses one whose platforms
    disagree with each other.

  Both workflows' previously independently-written jq (one first-platform-only, one already
  all-platforms) are replaced by calls to this ONE shared script, so the two call sites can never drift
  again on what "this exact tag's labels are trustworthy" means. `tests/test_verify_exact_image_labels.sh`
  (26 checks) exercises the shared helper directly against fixtures under
  `tests/fixtures/verify-exact-image-labels/` covering a matching amd64+arm64 manifest, one platform with
  a mismatched version label, one platform with a mismatched checksum label, one platform missing its
  labels entirely, a single-platform image (both matching and mismatched), an empty (zero-platform)
  image, and malformed input JSON — for both `exact` and `consistent` modes, plus usage/argument
  validation and static wiring assertions against both workflows. `tests/test_exact_image_immutability.sh`
  and `tests/test_release_reconciliation.sh` each gained real, end-to-end multi-platform
  match/mismatched-platform/missing-label functional cases that extend their existing fake-registry
  fixtures to return a genuine multi-platform `.Image` payload and replay the real, extracted workflow
  step against it.

- **Canonical source-checksum truth.** `scripts/compute-source-checksum.sh` is a new, independently tested
  helper that is now the ONLY place any release workflow downloads and hashes the tagged Ferrite source
  archive. It ALWAYS downloads `https://github.com/<owner>/ferrite/archive/refs/tags/v<version>.tar.gz`
  and computes its SHA256 itself; a caller-supplied checksum is never trusted as truth on its own. If one
  is supplied, the helper first validates its shape (rejecting anything that is not exactly 64 lowercase
  hexadecimal characters before any network access, so a malformed or malicious value can never even reach
  the download step) and then requires it to match the freshly computed canonical value byte-for-byte;
  any mismatch fails the run loudly instead of silently accepting the supplied value, and a download
  failure fails closed rather than silently proceeding without a canonical checksum.
  `version-sync.yml`'s "Extract version and source checksum" step and `release-orchestration.yml`'s
  "Compute release metadata" step both now call this helper with their own optional supplied checksum
  input; `release.yml`'s "Determine release version and source checksum" step (which has no
  caller-supplied checksum input of its own) calls the same helper for its own always-computed value, so
  all three workflows share the exact same download/validate/compare behavior instead of three
  independently duplicated implementations.

  `tests/test_compute_source_checksum.sh` (24 checks) fakes `curl` to avoid any real network access and
  functionally proves: a correct supplied checksum is confirmed and accepted (including an uppercase
  variant, normalized to lowercase); a syntactically valid but WRONG supplied checksum is rejected with a
  clear diagnostic and nothing printed to stdout; a syntactically invalid supplied checksum is rejected
  before any download is attempted; no supplied checksum still yields the canonical computed value; a
  download failure fails closed with a clear diagnostic, including when a syntactically valid checksum WAS
  supplied (a supplied value can never substitute for a successful canonical download); malicious
  command-substitution input is treated as inert data; and static assertions confirm all three workflows
  wire in the shared helper and no longer trust a supplied checksum directly. `tests/test_release_workflows.sh`
  was updated throughout: every place it previously supplied an arbitrary, hardcoded checksum for a
  synthetic (non-existent) release tag now fakes `curl` to return deterministic content and uses THAT
  content's real SHA256 as the expected canonical value, since the new shared helper genuinely downloads
  and hashes rather than trusting a supplied literal; it also gained explicit mismatch/no-supplied/download-
  failure cases replaying the real extracted `version-sync.yml` step end to end.

## Final Verification Pass (multi-platform exact-tag labels and canonical checksum truth)

- `bash tests/test_release_workflows.sh` (208 checks), `bash tests/test_exact_image_immutability.sh`
  (55 checks), `bash tests/test_release_reconciliation.sh` (104 checks),
  `bash tests/test_verify_exact_image_labels.sh` (26 checks, new), and
  `bash tests/test_compute_source_checksum.sh` (24 checks, new) all pass; `bash tests/test_audit_status.sh`
  passes.
- `bash tests/run.sh` passes all 31/31 discovered suites (29 previous + the 2 new dedicated suites above).
- `shellcheck --severity=warning scripts/*.sh tests/*.sh tests/lib/*.sh` and
  `actionlint .github/workflows/*.yml` pass with no findings, including the two new shared scripts
  (`scripts/verify-exact-image-labels.sh`, `scripts/compute-source-checksum.sh`) and the four rewired
  workflows (`release.yml`, `reconcile-release-tags.yml`, `version-sync.yml`, `release-orchestration.yml`).
- `helm lint --strict` passes for both charts (unchanged by this change); D-02 remains the only deferred
  item.
- `gitleaks detect --source . --no-git -v` reports no leaks in the working tree.
- No production behavior outside the exact-tag label verification and source-checksum computation paths
  in these four workflows was changed; existing candidate-build, signing, attestation, smoke-test,
  Docker Hub, and floating-tag-reconciliation behavior is unchanged and still green.

## Deferred Items

| ID | Description | Reason deferred |
|----|-------------|------------------|
| D-02 | Add new Helm `values.schema.json` policy/schema coverage | This is a new chart policy contract rather than a release-drift/runtime defect. Existing `helm lint` and `helm template` validation remains active. |

D-02 is the only deferred item.
