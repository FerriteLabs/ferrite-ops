#!/usr/bin/env bash
# Policy-neutral static invariant checks for Dockerfile.playground
# (D-01/F-07). No Docker daemon required.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
DOCKERFILE="${REPO_ROOT}/Dockerfile.playground"
ACTIVE_RELEASE="${REPO_ROOT}/active-release.env"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

if [[ ! -f "$DOCKERFILE" || ! -f "$ACTIVE_RELEASE" ]]; then
  echo "  FAIL: Dockerfile.playground or active-release.env not found" >&2
  exit 1
fi

CONTENT="$(cat "$DOCKERFILE")"
EXPECTED_VERSION="$(sed -n 's/^FERRITE_VERSION=//p' "$ACTIVE_RELEASE")"
EXPECTED_SHA256="$(sed -n 's/^FERRITE_SOURCE_SHA256=//p' "$ACTIVE_RELEASE")"

# 1. No COPY/ADD of a local path that doesn't exist in the repository.
#    This is what F-07 flagged: the original file did `COPY . .`, assuming
#    a full Ferrite source checkout as its own build context, which
#    ferrite-ops (a source-independent ops repo) never provides.
BAD_COPY=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  rest="$(echo "$line" | sed -E 's/^(COPY|ADD)[[:space:]]+//')"
  [[ "$rest" == *"--from="* ]] && continue
  src="$(echo "$rest" | sed -E 's/--[a-zA-Z-]+=[^ ]+[[:space:]]*//g' | awk '{print $1}')"
  [[ -z "$src" ]] && continue
  case "$src" in
    http://*|https://*) continue ;;
  esac
  if [[ ! -e "${REPO_ROOT}/${src}" ]]; then
    echo "  offending line: ${line}" >&2
    BAD_COPY=1
  fi
done < <(grep -E '^\s*(COPY|ADD)\s' "$DOCKERFILE" || true)
assert_eq 0 "$BAD_COPY" "Dockerfile.playground does not COPY/ADD any local path missing from the repository"
assert_not_contains "$CONTENT" $'COPY . .\n' "Dockerfile.playground no longer copies the entire build context as a source checkout"

# 2. No shell operators inside COPY/ADD instructions.
INVALID_COPY_SYNTAX=0
if grep -E '^\s*(COPY|ADD)\s.*(\|\||&&|[0-9]?>)' "$DOCKERFILE" >/dev/null; then
  INVALID_COPY_SYNTAX=1
fi
assert_eq 0 "$INVALID_COPY_SYNTAX" "no COPY/ADD instruction embeds shell operators (||, &&, redirection)"

# 3. The repository-owned launcher must provide its own RESP-backed HTTP
#    server and the healthcheck must probe its real HTTP endpoint.
assert_contains "$CONTENT" "HEALTHCHECK" "Dockerfile.playground defines a HEALTHCHECK"
RUNTIME_STAGE_BODY="$(sed -n '/^FROM debian:bookworm-slim AS runtime$/,$p' "$DOCKERFILE")"
assert_contains "$CONTENT" "COPY playground-launcher /app/playground-launcher" "builder includes the repository-owned runtime launcher"
assert_contains "$CONTENT" "--manifest-path /app/playground-launcher/Cargo.toml" "builder compiles the launcher crate against fetched source"
assert_contains "$RUNTIME_STAGE_BODY" "ferrite-playground-launcher" "runtime stage includes the compiled launcher"
assert_contains "$RUNTIME_STAGE_BODY" "curl --fail --silent --show-error http://127.0.0.1:8080/api/health" "HEALTHCHECK probes the actual playground HTTP endpoint"
INVALID_HEALTHCHECK=0
if grep -A2 '^HEALTHCHECK' "$DOCKERFILE" | grep -E 'CMD\s*\[.*\]\s*(\|\||&&)' >/dev/null; then
  INVALID_HEALTHCHECK=1
fi
assert_eq 0 "$INVALID_HEALTHCHECK" "HEALTHCHECK does not mix exec-form CMD array with shell operators"

# 4. Repository-independent source fetch, pinned to the same version and
#    checksum as the primary Dockerfile.
assert_contains "$CONTENT" "FERRITE_SOURCE_URL" "Dockerfile.playground fetches Ferrite source via an overridable FERRITE_SOURCE_URL"
assert_contains "$CONTENT" "github.com/FerriteLabs/ferrite" "Dockerfile.playground's default source points at the public FerriteLabs/ferrite repository"
ACTUAL_VERSION_DEFAULT="$(grep -oE '^ARG FERRITE_VERSION=[0-9A-Za-z.+-]+' "$DOCKERFILE" | head -1 | cut -d= -f2)"
assert_eq "$EXPECTED_VERSION" "${ACTUAL_VERSION_DEFAULT:-}" "ARG FERRITE_VERSION matches active-release.env"
assert_contains "$RUNTIME_STAGE_BODY" "ARG FERRITE_VERSION" "runtime stage re-declares FERRITE_VERSION so the OCI version label is populated"
ACTUAL_SHA256_DEFAULT="$(grep -oE '^ARG FERRITE_SOURCE_SHA256=[0-9a-fA-F]+' "$DOCKERFILE" | head -1 | cut -d= -f2)"
assert_eq "$EXPECTED_SHA256" "${ACTUAL_SHA256_DEFAULT:-}" "ARG FERRITE_SOURCE_SHA256 matches active-release.env"
assert_contains "$CONTENT" "sha256sum -c -" "source stage verifies the fetched tarball with sha256sum"
assert_contains "$CONTENT" 'if [ -z "$FERRITE_SOURCE_SHA256" ]' "source stage refuses to build when FERRITE_SOURCE_SHA256 is empty"

# 5. Same version-scoped build compatibility fixes as the primary Dockerfile.
assert_contains "$CONTENT" '[ "$FERRITE_VERSION" = "0.4.0" ]' "v0.4.0 Linux io_uring compatibility gate is applied"
assert_contains "$CONTENT" 'feature = "io-uring"' "Linux io_uring module follows its optional Cargo feature"
assert_contains "$CONTENT" 'let mut fields = vec!' "v0.4.0 Linux eBPF fields remain mutable when platform fields are appended"

# 6. ABI compatibility: builder and runtime stages must both be
#    glibc-based (Debian), so the compiled binary's dynamic linkage
#    matches at runtime.
BUILDER_STAGE_FROM="$(grep -E '^FROM .* AS base$' "$DOCKERFILE" | head -1)"
RUNTIME_STAGE_FROM="$(grep -E '^FROM .* AS runtime$' "$DOCKERFILE" | head -1)"
assert_contains "$BUILDER_STAGE_FROM" "bookworm" "builder base stage is Debian bookworm (glibc)"
assert_contains "$RUNTIME_STAGE_FROM" "bookworm" "runtime stage is Debian bookworm (glibc), matching the builder's ABI"
assert_not_contains "$CONTENT" "FROM alpine" "no build stage uses an Alpine (musl) base image"

# 7. Reachability and lifecycle are owned by the launcher rather than unused
#    environment variables that the upstream executable does not consume.
#    The launcher is split into single-responsibility modules, so the checks
#    below scan the whole crate source rather than one file.
LAUNCHER_SRC="${REPO_ROOT}/playground-launcher/src"
LAUNCHER_CONTENT="$(cat "${LAUNCHER_SRC}"/*.rs)"
MANIFEST_CONTENT="$(cat "${REPO_ROOT}/playground-launcher/Cargo.toml")"
assert_contains "$LAUNCHER_CONTENT" 'const HTTP_ADDR: &str = "0.0.0.0:8080"' "playground HTTP binds to 0.0.0.0:8080"
assert_contains "$LAUNCHER_CONTENT" '"--bind"' "launcher explicitly configures the RESP bind address"
assert_contains "$LAUNCHER_CONTENT" '"/api/execute"' "launcher exposes command execution over HTTP"
assert_contains "$LAUNCHER_CONTENT" '"/api/keys/detail/{key}"' "launcher exposes real key detail over HTTP"
assert_contains "$LAUNCHER_CONTENT" "resp::execute" "HTTP handlers execute commands through the RESP server"
assert_contains "$LAUNCHER_CONTENT" "INDEX_HTML" "launcher serves an interactive HTML page"
assert_contains "$LAUNCHER_CONTENT" "shutdown_signal" "launcher handles process shutdown signals"
assert_contains "$LAUNCHER_CONTENT" "supervisor::stop" "launcher cleans up the RESP child process"
assert_contains "$LAUNCHER_CONTENT" "Signal::SIGTERM" "launcher forwards SIGTERM before escalating"
assert_contains "$LAUNCHER_CONTENT" "start_kill" "launcher retains SIGKILL as bounded shutdown escalation"
assert_not_contains "$MANIFEST_CONTENT" "ferrite-studio" "launcher no longer depends on placeholder ferrite-studio APIs"
assert_not_contains "$RUNTIME_STAGE_BODY" "FERRITE_STUDIO_ENABLED" "runtime does not rely on unused Studio environment variables"
assert_not_contains "$RUNTIME_STAGE_BODY" "FERRITE_STUDIO_HOST" "runtime does not rely on an unused Studio host environment variable"

# 7b. The Ferrite child is never the public listener: it is bound to an
#     internal loopback port, and the launcher owns the public RESP port with
#     one shared command policy for both RESP and HTTP entry points.
SUPERVISOR_CONTENT="$(cat "${LAUNCHER_SRC}/supervisor.rs")"
PROXY_CONTENT="$(cat "${LAUNCHER_SRC}/proxy.rs")"
POLICY_CONTENT="$(cat "${LAUNCHER_SRC}/policy.rs")"
HTTP_CONTENT="$(cat "${LAUNCHER_SRC}/http.rs")"
assert_contains "$SUPERVISOR_CONTENT" 'INTERNAL_RESP_BIND: &str = "127.0.0.1"' "Ferrite child binds to internal loopback only"
assert_contains "$SUPERVISOR_CONTENT" 'INTERNAL_RESP_PORT: &str = "6380"' "Ferrite child listens on the internal port 6380"
assert_not_contains "$SUPERVISOR_CONTENT" '"0.0.0.0"' "Ferrite child is never bound to a publicly reachable address"
assert_contains "$PROXY_CONTENT" 'PUBLIC_RESP_ADDR: &str = "0.0.0.0:6379"' "launcher owns the public Redis-compatible port 6379"
assert_contains "$PROXY_CONTENT" "policy::classify_bytes" "public RESP proxy classifies every command before forwarding"
assert_contains "$HTTP_CONTENT" "policy::classify_arguments" "HTTP /api/execute classifies every command with the same policy"
assert_contains "$POLICY_CONTENT" "const POLICIES:" "shared command policy is an explicit allowlist"
assert_contains "$POLICY_CONTENT" "the command is not on the explicit safe-command allowlist" \
  "commands outside the explicit allowlist are rejected by default"
assert_not_contains "$POLICY_CONTENT" "ADMINISTRATIVE_COMMANDS" \
  "the shared policy no longer relies on an administrative-command denylist"
assert_not_contains "$POLICY_CONTENT" "ADMINISTRATIVE_FAMILIES" \
  "the shared policy no longer relies on a privileged-family denylist"
for allowed_command in PING ECHO GET SET LRANGE ZRANGE XRANGE; do
  assert_contains "$POLICY_CONTENT" "\"${allowed_command}\"" \
    "shared command policy explicitly allows bounded/basic ${allowed_command}"
done
for removed_command in SCAN HSCAN SSCAN ZSCAN XREAD XREADGROUP; do
  assert_not_contains "$POLICY_CONTENT" "policy(&[\"${removed_command}\"]" \
    "shared command policy does not allow unbounded ${removed_command}"
done
assert_contains "$POLICY_CONTENT" "MAX_COLLECTION_PAGE: usize = 100" \
  "collection and stream pages are capped at 100"
assert_contains "$POLICY_CONTENT" "MAX_MULTI_ITEMS: usize = 32" \
  "multi-key/field/member commands use a conservative item cap"
assert_contains "$POLICY_CONTENT" "removed_scan_and_stream_read_commands_cannot_bypass_the_allowlist" \
  "policy tests cover removed scan/read bypass attempts"
assert_contains "$POLICY_CONTENT" '"XREAD", "STREAMS", "COUNT"' \
  "policy tests cover the reordered XREAD STREAMS COUNT bypass"
assert_contains "$LAUNCHER_CONTENT" "unexpected_exit_error" "any unsolicited Ferrite child exit is treated as a launcher error"

# 7c. Response and resource bounds: replies are bounded by one cumulative
#     byte budget, and key inspection never issues an unbounded collection
#     read.
RESP_MODULE_CONTENT="$(cat "${LAUNCHER_SRC}/resp.rs")"
KEYS_CONTENT="$(cat "${LAUNCHER_SRC}/keys.rs")"
assert_contains "$RESP_MODULE_CONTENT" "MAX_RESPONSE_BYTES" "the RESP codec defines a cumulative response byte budget"
assert_contains "$RESP_MODULE_CONTENT" "struct ResponseBudget" "the cumulative budget is an explicit type, not a per-element check"
assert_contains "$RESP_MODULE_CONTENT" "read_value_budgeted" "every decoded reply is charged to a budget"
assert_not_contains "$RESP_MODULE_CONTENT" "pub fn read_value<" "no unbudgeted reply decoding entry point remains"
assert_contains "$PROXY_CONTENT" "ResponseBudget::default()" "public RESP replies are bounded by the cumulative budget"
assert_not_contains "$KEYS_CONTENT" 'execute(addr, &["SSCAN"' "set key detail never invokes SSCAN"
assert_not_contains "$KEYS_CONTENT" 'execute(addr, &["HSCAN"' "hash key detail never invokes HSCAN"
assert_contains "$KEYS_CONTENT" '"SCARD"' "set key detail reports the real set length"
assert_contains "$KEYS_CONTENT" '"HLEN"' "hash key detail reports the real hash length"
assert_contains "$KEYS_CONTENT" '"value_omitted"' "hash/set key detail clearly marks omitted values"
assert_contains "$KEYS_CONTENT" '"GETRANGE"' "string key detail returns a bounded preview"
assert_contains "$KEYS_CONTENT" 'PAGE_LIMIT: i64 = 100' "list/zset/stream key detail pages are limited to 100 elements"
assert_contains "$KEYS_CONTENT" '"truncated"' "key detail reports truncation metadata"
for unbounded in SMEMBERS HGETALL; do
  assert_not_contains "$KEYS_CONTENT" "&[\"${unbounded}\"" "key detail never issues the unbounded read ${unbounded}"
done
assert_not_contains "$KEYS_CONTENT" '"LRANGE", key, "0", "-1"' "list key detail never reads the whole list"
assert_not_contains "$KEYS_CONTENT" '"ZRANGE", key, "0", "-1"' "sorted set key detail never reads the whole zset"
assert_contains "$KEYS_CONTENT" '"XRANGE"' "stream key detail uses a bounded XRANGE"
assert_contains "$KEYS_CONTENT" '"COUNT"' "stream key detail passes an explicit COUNT bound"
assert_contains "$PROXY_CONTENT" "CLIENT_WRITE_TIMEOUT" "public RESP writes have a strict timeout"
assert_contains "$PROXY_CONTENT" "write_backend_response" \
  "backend permits are held through public RESP response writes"
assert_contains "$HTTP_CONTENT" "MAX_HTTP_CONNECTIONS" \
  "HTTP accepts have a real connection-lifetime limit"
assert_contains "$HTTP_CONTENT" "HTTP_CONNECTION_LIFETIME" \
  "HTTP connections have a strict lifetime deadline"
assert_contains "$HTTP_CONTENT" "MAX_RESPONSE_BODY_BYTES" \
  "HTTP API output bodies have a fixed byte ceiling"

# 8. Distinct purpose preserved: image name, ports, and version metadata remain.
assert_contains "$CONTENT" "EXPOSE 8080 6379" "Dockerfile.playground still exposes both the studio (8080) and Redis-compatible (6379) ports"
assert_contains "$CONTENT" 'ENTRYPOINT ["/usr/local/bin/ferrite-playground-launcher"]' "Dockerfile.playground starts the dual-service launcher"
assert_contains "$CONTENT" "USER ferrite" "playground runs as an unprivileged user"
assert_contains "$CONTENT" 'org.opencontainers.image.title="Ferrite Playground"' "Dockerfile.playground keeps its distinct image title"
assert_contains "$RUNTIME_STAGE_BODY" 'org.opencontainers.image.version="${FERRITE_VERSION}"' "playground image keeps its pinned/overridden version label"

harness_summary
