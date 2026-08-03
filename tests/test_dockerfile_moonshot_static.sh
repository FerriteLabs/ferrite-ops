#!/usr/bin/env bash
# Policy-neutral static invariant checks for Dockerfile.moonshot (D-01/F-07).
# Mirrors tests/test_dockerfile_static.sh's checks for the primary
# Dockerfile — no Docker daemon required — so structural regressions are
# caught even in environments without Docker installed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
DOCKERFILE="${REPO_ROOT}/Dockerfile.moonshot"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "  FAIL: ${DOCKERFILE} not found" >&2
  exit 1
fi

CONTENT="$(cat "$DOCKERFILE")"

# 1. No COPY/ADD of a local (non --from=, non URL) path that doesn't exist
#    in the repository (this is exactly what F-07 flagged: the original
#    file COPYd src/crates/benches, which only exist in the core ferrite
#    repo, not here).
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
assert_eq 0 "$BAD_COPY" "Dockerfile.moonshot does not COPY/ADD any local path missing from the repository"

# 2. No shell operators inside COPY/ADD instructions (invalid Dockerfile
#    syntax regardless of intent) — this is exactly the invalid
#    `COPY ... 2>/dev/null || true` "optional COPY" pattern F-07 flagged.
INVALID_COPY_SYNTAX=0
if grep -E '^\s*(COPY|ADD)\s.*(\|\||&&|[0-9]?>)' "$DOCKERFILE" >/dev/null; then
  INVALID_COPY_SYNTAX=1
fi
assert_eq 0 "$INVALID_COPY_SYNTAX" "no COPY/ADD instruction embeds shell operators (||, &&, redirection)"
assert_not_contains "$CONTENT" 'ferrite.toml /etc/ferrite/ferrite.toml 2>/dev/null' \
  "no optional/invalid COPY of a nonexistent local ferrite.toml"

# 3. HEALTHCHECK must not combine an exec-form CMD array with a shell
#    operator like `|| exit 1`.
INVALID_HEALTHCHECK=0
if grep -A2 '^HEALTHCHECK' "$DOCKERFILE" | grep -E 'CMD\s*\[.*\]\s*(\|\||&&)' >/dev/null; then
  INVALID_HEALTHCHECK=1
fi
assert_eq 0 "$INVALID_HEALTHCHECK" "HEALTHCHECK does not mix exec-form CMD array with shell operators"
assert_contains "$CONTENT" "HEALTHCHECK" "Dockerfile.moonshot defines a HEALTHCHECK"
assert_contains "$CONTENT" "PING" "HEALTHCHECK exercises PING"

# 4. Repository-independent source fetch, pinned to the same version and
#    checksum as the primary Dockerfile.
assert_contains "$CONTENT" "FERRITE_SOURCE_URL" "Dockerfile.moonshot fetches Ferrite source via an overridable FERRITE_SOURCE_URL"
assert_contains "$CONTENT" "github.com/FerriteLabs/ferrite" "Dockerfile.moonshot's default source points at the public FerriteLabs/ferrite repository"
ACTUAL_VERSION_DEFAULT="$(grep -oE '^ARG FERRITE_VERSION=[0-9A-Za-z.+-]+' "$DOCKERFILE" | head -1 | cut -d= -f2)"
assert_eq "0.3.0" "${ACTUAL_VERSION_DEFAULT:-}" "ARG FERRITE_VERSION default matches the primary Dockerfile (0.3.0)"
EXPECTED_SHA256="42cc9cd06b85fac0a09d6e1770d3eda61375324211be168dfb6dc7eab5825979"
ACTUAL_SHA256_DEFAULT="$(grep -oE '^ARG FERRITE_SOURCE_SHA256=[0-9a-fA-F]+' "$DOCKERFILE" | head -1 | cut -d= -f2)"
assert_eq "$EXPECTED_SHA256" "${ACTUAL_SHA256_DEFAULT:-}" "ARG FERRITE_SOURCE_SHA256 default matches the primary Dockerfile's verified v0.3.0 tarball SHA256"
assert_contains "$CONTENT" "sha256sum -c -" "source stage verifies the fetched tarball with sha256sum"
assert_contains "$CONTENT" 'if [ -z "$FERRITE_SOURCE_SHA256" ]' "source stage refuses to build when FERRITE_SOURCE_SHA256 is empty"

# 5. Same v0.3.0 build-compatibility fix as the primary Dockerfile (F-10):
#    without it, this file would fetch the identical broken source and
#    fail to compile.
assert_contains "$CONTENT" 'if [ "$FERRITE_VERSION" = "0.3.0" ]' "v0.3.0 source compatibility fix is scoped to the default release"
assert_contains "$CONTENT" 'feature = "io-uring"' "v0.3.0 Linux io_uring module follows its optional Cargo feature"
assert_contains "$CONTENT" 'let mut fields = vec!' "v0.3.0 Linux eBPF fields remain mutable when platform fields are appended"

# 6. Repository-independence: build must not force cross-platform QEMU
#    emulation via a hardcoded BUILDPLATFORM.
assert_not_contains "$CONTENT" 'BUILDPLATFORM=linux/amd64' "Dockerfile.moonshot does not force host builds through amd64 emulation"

# 7. ABI compatibility: runtime stage must be glibc-based (Debian), not
#    Alpine (musl), matching the glibc builder — same F-12-style fix as
#    the primary Dockerfile.
RUNTIME_STAGE_FROM="$(grep -E '^FROM .* AS runtime$' "$DOCKERFILE" | head -1)"
assert_contains "$RUNTIME_STAGE_FROM" "debian" "runtime stage is based on a Debian (glibc) image"
assert_not_contains "$CONTENT" "FROM alpine" "no build stage uses an Alpine (musl) base image"
assert_contains "$CONTENT" "1000" "runtime stage creates its non-root user with UID/GID 1000"
assert_contains "$CONTENT" "USER ferrite" "runtime stage switches to the non-root 'ferrite' user"

# 8. Container reachability + loadability: the runtime's default config
#    must be generated and self-verified by the exact freshly built
#    binary (never an optional/invalid copy of a local ferrite.toml).
assert_contains "$CONTENT" "AS runtime-config" "Dockerfile.moonshot has a dedicated stage that generates the container runtime config"
assert_contains "$CONTENT" "ferrite init --minimal" "runtime-config stage generates the baked-in config with the real binary's own ferrite init --minimal"
assert_contains "$CONTENT" "ferrite --test-config" "runtime-config stage asserts the resulting config actually loads with the exact freshly built binary"
assert_contains "$CONTENT" 'bind = "0.0.0.0"' "runtime config generation targets a 0.0.0.0 bind replacement"
assert_contains "$CONTENT" "COPY --from=runtime-config" "final runtime stage copies the generated config from the runtime-config stage"

# 9. Distinct purpose preserved: moonshot-specific ports, entrypoint,
#    default command, and feature-flag plumbing must be unchanged.
assert_contains "$CONTENT" "EXPOSE 6379" "Dockerfile.moonshot still exposes the Redis-compatible port 6379"
assert_contains "$CONTENT" "EXPOSE 9090" "Dockerfile.moonshot still exposes the metrics port 9090"
assert_contains "$CONTENT" 'ENTRYPOINT ["/usr/local/bin/ferrite"]' "Dockerfile.moonshot entrypoint is unchanged"
assert_contains "$CONTENT" 'CMD ["--config", "/etc/ferrite/ferrite.toml"]' "Dockerfile.moonshot default CMD is unchanged"
assert_contains "$CONTENT" 'ARG FERRITE_FEATURES="default"' "Dockerfile.moonshot's configurable FERRITE_FEATURES build-arg is preserved"
assert_contains "$CONTENT" "FERRITE_COMPILED_FEATURES" "Dockerfile.moonshot still records compiled-in features at runtime"
assert_contains "$CONTENT" 'org.opencontainers.image.title="Ferrite (Moonshot)"' "Dockerfile.moonshot keeps its distinct image title"

harness_summary
