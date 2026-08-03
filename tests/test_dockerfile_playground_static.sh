#!/usr/bin/env bash
# Policy-neutral static invariant checks for Dockerfile.playground
# (D-01/F-07). No Docker daemon required.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
DOCKERFILE="${REPO_ROOT}/Dockerfile.playground"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "  FAIL: ${DOCKERFILE} not found" >&2
  exit 1
fi

CONTENT="$(cat "$DOCKERFILE")"

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
assert_eq "0.4.0" "${ACTUAL_VERSION_DEFAULT:-}" "ARG FERRITE_VERSION default matches the primary Dockerfile (0.4.0)"
assert_contains "$RUNTIME_STAGE_BODY" "ARG FERRITE_VERSION" "runtime stage re-declares FERRITE_VERSION so the OCI version label is populated"
EXPECTED_SHA256="b4db8cc8eb0d3c2cef4a019a47d550c347df69fb8a4f77550c814fae463005cf"
ACTUAL_SHA256_DEFAULT="$(grep -oE '^ARG FERRITE_SOURCE_SHA256=[0-9a-fA-F]+' "$DOCKERFILE" | head -1 | cut -d= -f2)"
assert_eq "$EXPECTED_SHA256" "${ACTUAL_SHA256_DEFAULT:-}" "ARG FERRITE_SOURCE_SHA256 default matches the primary Dockerfile's verified v0.4.0 tarball SHA256"
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
LAUNCHER="${REPO_ROOT}/playground-launcher/src/main.rs"
LAUNCHER_CONTENT="$(cat "$LAUNCHER")"
MANIFEST_CONTENT="$(cat "${REPO_ROOT}/playground-launcher/Cargo.toml")"
assert_contains "$LAUNCHER_CONTENT" 'const HTTP_ADDR: &str = "0.0.0.0:8080"' "playground HTTP binds to 0.0.0.0:8080"
assert_contains "$LAUNCHER_CONTENT" '"--bind"' "launcher explicitly configures the RESP bind address"
assert_contains "$LAUNCHER_CONTENT" '"0.0.0.0"' "RESP server binds to 0.0.0.0"
assert_contains "$LAUNCHER_CONTENT" '"6379"' "RESP server listens on port 6379"
assert_contains "$LAUNCHER_CONTENT" '"/api/execute"' "launcher exposes command execution over HTTP"
assert_contains "$LAUNCHER_CONTENT" '"/api/keys/detail/{key}"' "launcher exposes real key detail over HTTP"
assert_contains "$LAUNCHER_CONTENT" "execute_resp" "HTTP handlers execute commands through the RESP server"
assert_contains "$LAUNCHER_CONTENT" "INDEX_HTML" "launcher serves an interactive HTML page"
assert_contains "$LAUNCHER_CONTENT" "shutdown_signal" "launcher handles process shutdown signals"
assert_contains "$LAUNCHER_CONTENT" "stop_child" "launcher cleans up the RESP child process"
assert_contains "$LAUNCHER_CONTENT" "Signal::SIGTERM" "launcher forwards SIGTERM before escalating"
assert_contains "$LAUNCHER_CONTENT" "start_kill" "launcher retains SIGKILL as bounded shutdown escalation"
assert_not_contains "$MANIFEST_CONTENT" "ferrite-studio" "launcher no longer depends on placeholder ferrite-studio APIs"
assert_not_contains "$RUNTIME_STAGE_BODY" "FERRITE_STUDIO_ENABLED" "runtime does not rely on unused Studio environment variables"
assert_not_contains "$RUNTIME_STAGE_BODY" "FERRITE_STUDIO_HOST" "runtime does not rely on an unused Studio host environment variable"

# 8. Distinct purpose preserved: image name, ports, and version metadata remain.
assert_contains "$CONTENT" "EXPOSE 8080 6379" "Dockerfile.playground still exposes both the studio (8080) and Redis-compatible (6379) ports"
assert_contains "$CONTENT" 'ENTRYPOINT ["/usr/local/bin/ferrite-playground-launcher"]' "Dockerfile.playground starts the dual-service launcher"
assert_contains "$CONTENT" "USER ferrite" "playground runs as an unprivileged user"
assert_contains "$CONTENT" 'org.opencontainers.image.title="Ferrite Playground"' "Dockerfile.playground keeps its distinct image title"
assert_contains "$RUNTIME_STAGE_BODY" 'org.opencontainers.image.version="${FERRITE_VERSION}"' "playground image keeps its pinned/overridden version label"

harness_summary
