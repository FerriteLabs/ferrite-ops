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
- default/quickstart/Moonshot Compose, production Argo CD/Flux overlays, and Terraform defaults;
- release workflow dispatch default;
- Moonshot Compose build arguments and source checksums.

`version-sync.yml` prevalidates the canonical file and every active release pin, stages all replacements,
validates the staged result, and only then replaces the working-tree targets. It updates all three
Dockerfiles, both chart appVersions, Compose, production GitOps, Terraform defaults/examples, and the
release workflow dispatch default together. `tests/test_release_workflows.sh` functionally replays both the
successful full transaction and a structural-drift failure that leaves canonical metadata unchanged. Release
metadata is normalized before Docker tag generation, so a stable `v0.4.0` dispatch publishes `0.4.0`, `0.4`, `0`, and
`latest`; prereleases publish only their exact normalized tag.

All chart-update release paths update the primary chart's package version/appVersion and the sidecar
chart's appVersion. The sidecar chart package remains independently versioned.

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
- `/api/execute` applies the identical policy and answers `403` for refused commands;
- any Ferrite child exit that the launcher did not initiate is an error, including `exit(0)`;
- the proxy bounds request line length, per-argument and total request size, argument count,
  concurrent connections, client idle time, and response-write time;
- RESP2 and RESP3 are both preserved: `HELLO 3` and every RESP3 reply type (`_`, `#`, `,`, `(`,
  `!`, `=`, `%`, `~`, `>`) are decoded, charged to the response budget, and re-encoded unchanged.
- one launcher-owned 32-permit semaphore limits aggregate Ferrite backend work across public RESP
  commands and HTTP execute/key-detail/health requests; acquisition never waits, overload returns
  HTTP `429` or a RESP error without forwarding, and health deliberately follows the same simple
  fail-fast rule so a saturated pool cannot deadlock a probe. RESP permits remain held until the
  bounded response write completes or its strict two-second deadline expires;
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

## Runtime Verification Completed

- 72 `playground-launcher` unit tests pass (`cargo test`), run from `tests/run.sh` via
  `tests/test_playground_launcher_unit.sh` and from a dedicated CI job.
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
- Playground process inspection showed the launcher supervising the Ferrite child; plain `docker stop`
  (without a timeout override) completed before Docker's default SIGKILL deadline, the container exited
  with code 0, and no child/container process leaked.
- The v0.4.0 source-stage checksum verification succeeded against the authoritative tarball.
- HTTP binary replies are emitted as compact base64 objects, reject conversion before their output budget
  is exceeded, and remain bounded under concurrent requests. SELECT and RESP3/HELLO state-loss regression
  tests prove a public client is closed rather than silently reconnected on database 0 or RESP2.

## Deferred Items

| ID | Description | Reason deferred |
|----|-------------|------------------|
| D-02 | Add new Helm `values.schema.json` policy/schema coverage | This is a new chart policy contract rather than a release-drift/runtime defect. Existing `helm lint` and `helm template` validation remains active. |

D-02 is the only deferred item.
