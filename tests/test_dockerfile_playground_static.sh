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

# 3. HEALTHCHECK must still be present and functional. The pinned v0.3.0
#    executable does not serve the previously assumed studio HTTP endpoint,
#    so probe the actual RESP service using the CLI built from the same
#    verified source instead of depending on curl or a nonexistent route.
assert_contains "$CONTENT" "HEALTHCHECK" "Dockerfile.playground defines a HEALTHCHECK"
RUNTIME_STAGE_BODY="$(sed -n '/^FROM debian:bookworm-slim AS runtime$/,$p' "$DOCKERFILE")"
assert_contains "$CONTENT" "--features ferrite-studio" "builder enables the playground's ferrite-studio dependency directly"
assert_contains "$CONTENT" "--bin ferrite --bin ferrite-cli" "builder produces ferrite-cli alongside the server for the runtime healthcheck"
assert_not_contains "$CONTENT" "2>/dev/null ||" "builder does not hide feature-build errors behind a silent fallback"
assert_contains "$RUNTIME_STAGE_BODY" "COPY --from=builder /app/target/release/ferrite-cli" "runtime stage includes the healthcheck client built from the same source"
assert_contains "$RUNTIME_STAGE_BODY" "CMD ferrite-cli PING || exit 1" "HEALTHCHECK probes the actual RESP service rather than an unavailable HTTP endpoint"
assert_not_contains "$RUNTIME_STAGE_BODY" "localhost:8080/api/v1/health" "HEALTHCHECK does not assume an HTTP endpoint absent from pinned Ferrite v0.3.0"
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

# 7. Reachability: the RESP port must not be left on its loopback-only
#    built-in default (127.0.0.1) — the same class of defect as F-13,
#    since this Dockerfile passes no config file at all.
assert_contains "$CONTENT" "FERRITE_BIND=0.0.0.0" "playground's Redis-compatible port is bound to 0.0.0.0, reachable through Docker's published-port mapping"
assert_contains "$CONTENT" "FERRITE_STUDIO_HOST=0.0.0.0" "playground's studio HTTP port remains bound to 0.0.0.0"

# 8. Distinct purpose preserved: playground-specific ports, entrypoint,
#    default command, and version default are unchanged.
assert_contains "$CONTENT" "EXPOSE 8080 6379" "Dockerfile.playground still exposes both the studio (8080) and Redis-compatible (6379) ports"
assert_contains "$CONTENT" 'ENTRYPOINT ["ferrite"]' "Dockerfile.playground entrypoint is unchanged"
assert_contains "$CONTENT" 'CMD ["--port", "6379"]' "Dockerfile.playground default CMD is unchanged"
assert_contains "$CONTENT" "FERRITE_STUDIO_ENABLED=true" "Dockerfile.playground still enables ferrite-studio"
assert_contains "$CONTENT" 'org.opencontainers.image.title="Ferrite Playground"' "Dockerfile.playground keeps its distinct image title"
assert_contains "$RUNTIME_STAGE_BODY" 'org.opencontainers.image.version="${FERRITE_VERSION}"' "playground image keeps its pinned/overridden version label"

harness_summary
