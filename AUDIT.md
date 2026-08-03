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

## Immutable Version Tags and Serialized Promotion Resolution (this change)

Container releases now separate the exact, immutable version tag from the floating tags so an
out-of-order, retried, or concurrent release can never overwrite `latest`/`<major>`/`<major>.<minor>`
with an older image:

- `release.yml`'s `build-and-push` job publishes ONLY the exact version tag (e.g. `0.4.1`) plus its
  digest, for every trigger and channel. Exact tags are unique per version, so this expensive multi-arch
  build is no longer serialized and independent releases build concurrently without racing.
- A new serialized `promote-stable` job advances the floating tags to the freshly built digest with
  `docker buildx imagetools create` — no rebuild, and the existing cosign signature/attestations remain
  valid because the promoted tags reference the same signed digest. It runs only for stable releases
  (prereleases stay exact-only) and only when the candidate is `>=` the current promoted stable version.
- The current promoted stable version is read from trustworthy registry metadata (the `latest` tag's
  `org.opencontainers.image.version` label), never from mutable workflow input; a missing `latest` is
  treated as the first promotion, and any other read failure aborts rather than promoting blindly.
- The fixed `ferrite-floating-tag-promotion` concurrency group (`cancel-in-progress: false`) serializes
  the read-compare-write, and the `>=` gate (via `scripts/release-ordering.sh`) makes an older release
  skip promotion instead of regressing `latest`.
- `scripts/release-ordering.sh` is the shared SemVer-precedence engine (`semver-cmp`/`ge`/`classify`),
  with strict input validation so untrusted payloads cannot inject shell metacharacters.
  `tests/test_release_ordering.sh` (24 checks) covers numeric and pre-release precedence, the `ge`
  contract, all four `classify` outcomes, and injection rejection. `tests/test_release_promotion.sh`
  (22 checks) statically verifies the split/serialized/imagetools architecture and functionally replays
  promotion for `0.4.1` then a late `0.4.0`, equal retries, serialized concurrent candidates,
  dual-registry promotion, and prerelease rejection.

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

## Deferred Items

| ID | Description | Reason deferred |
|----|-------------|------------------|
| D-02 | Add new Helm `values.schema.json` policy/schema coverage | This is a new chart policy contract rather than a release-drift/runtime defect. Existing `helm lint` and `helm template` validation remains active. |

D-02 is the only deferred item.
