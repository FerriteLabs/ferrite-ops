#!/usr/bin/env bash
# Policy-neutral static invariant checks for the Dockerfile. These run with
# plain grep/awk against the Dockerfile text — no Docker daemon required —
# so they catch structural regressions (e.g. re-introducing a COPY of
# nonexistent source paths, or invalid HEALTHCHECK/COPY syntax) even in
# environments without Docker installed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
DOCKERFILE="${REPO_ROOT}/Dockerfile"
# shellcheck source=tests/lib/harness.sh
source "${HERE}/lib/harness.sh"

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "  FAIL: ${DOCKERFILE} not found" >&2
  exit 1
fi

CONTENT="$(cat "$DOCKERFILE")"

# 1. No COPY/ADD of a local (non --from=, non URL) path that doesn't exist
#    in the repository. This is what broke the original Dockerfile, which
#    tried to COPY src/crates/benches that only exist in the core ferrite repo.
BAD_COPY=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Strip a leading COPY/ADD and any --flag=value tokens (e.g. --chown, --from).
  rest="$(echo "$line" | sed -E 's/^(COPY|ADD)[[:space:]]+//')"
  [[ "$rest" == *"--from="* ]] && continue  # multi-stage copies are exempt
  src="$(echo "$rest" | sed -E 's/--[a-zA-Z-]+=[^ ]+[[:space:]]*//g' | awk '{print $1}')"
  [[ -z "$src" ]] && continue
  case "$src" in
    http://*|https://*) continue ;;  # ADD may fetch URLs directly
  esac
  if [[ ! -e "${REPO_ROOT}/${src}" ]]; then
    echo "  offending line: ${line}" >&2
    BAD_COPY=1
  fi
done < <(grep -E '^\s*(COPY|ADD)\s' "$DOCKERFILE" || true)
assert_eq 0 "$BAD_COPY" "Dockerfile does not COPY/ADD any local path missing from the repository"

# 2. No shell operators (redirection, ||, &&) inside COPY/ADD instructions:
#    these are not valid Dockerfile syntax regardless of intent.
INVALID_COPY_SYNTAX=0
if grep -E '^\s*(COPY|ADD)\s.*(\|\||&&|[0-9]?>)' "$DOCKERFILE" >/dev/null; then
  INVALID_COPY_SYNTAX=1
fi
assert_eq 0 "$INVALID_COPY_SYNTAX" "no COPY/ADD instruction embeds shell operators (||, &&, redirection)"

# 3. HEALTHCHECK must not combine an exec-form CMD array with a shell
#    operator like `|| exit 1`: exec-form arrays don't invoke a shell.
INVALID_HEALTHCHECK=0
if grep -A2 '^HEALTHCHECK' "$DOCKERFILE" | grep -E 'CMD\s*\[.*\]\s*(\|\||&&)' >/dev/null; then
  INVALID_HEALTHCHECK=1
fi
assert_eq 0 "$INVALID_HEALTHCHECK" "HEALTHCHECK does not mix exec-form CMD array with shell operators"

# 4. HEALTHCHECK must still be present with a PING check.
assert_contains "$CONTENT" "HEALTHCHECK" "Dockerfile defines a HEALTHCHECK"
assert_contains "$CONTENT" "PING" "HEALTHCHECK exercises PING"

# 5. The build must fetch Ferrite source rather than assume it's already in
#    the build context (self-containment for this source-less ops repo).
assert_contains "$CONTENT" "FERRITE_SOURCE_URL" "Dockerfile fetches Ferrite source via an overridable FERRITE_SOURCE_URL"
assert_contains "$CONTENT" "github.com/FerriteLabs/ferrite" "Dockerfile's default source points at the public FerriteLabs/ferrite repository"

# 6. FERRITE_VERSION default must not be silently bumped by future edits.
ACTUAL_DEFAULT="$(grep -oE '^ARG FERRITE_VERSION=[0-9A-Za-z.+-]+' "$DOCKERFILE" | head -1 | cut -d= -f2)"
assert_eq "0.4.0" "${ACTUAL_DEFAULT:-}" "ARG FERRITE_VERSION defaults to the current Ferrite release 0.4.0"
assert_contains "$CONTENT" "rm -f rust-toolchain rust-toolchain.toml" \
  "fetched contributor toolchain cannot override the Docker build toolchain"
assert_contains "$CONTENT" 'if [ "$FERRITE_VERSION" = "0.3.0" ]' \
  "legacy v0.3.0 source compatibility fix remains scoped to that explicit override"
assert_contains "$CONTENT" 'feature = "io-uring"' \
  "v0.3.0 Linux io_uring module follows its optional Cargo feature"
assert_contains "$CONTENT" 'let mut fields = vec!' \
  "v0.3.0 Linux eBPF fields remain mutable when platform fields are appended"
assert_not_contains "$CONTENT" 'BUILDPLATFORM=linux/amd64' \
  "Docker build does not force host builds through amd64 emulation"

# 7. Preserve required public ports and image entrypoint contract.
assert_contains "$CONTENT" "EXPOSE 6379" "Dockerfile still exposes the Redis-compatible port 6379"
assert_contains "$CONTENT" "EXPOSE 9090" "Dockerfile still exposes the metrics port 9090"
assert_contains "$CONTENT" 'ENTRYPOINT ["/usr/local/bin/ferrite"]' "Dockerfile entrypoint is unchanged"

# 8. Runtime stage must use a glibc-based (Debian) image, not Alpine
#    (musl), to match the glibc ABI of the `rust:1.95-slim-bookworm`
#    builder stage. Building with a Debian/glibc toolchain and then running
#    under an Alpine/musl runtime is an ABI mismatch that risks a missing
#    dynamic linker/library failure at container startup.
RUNTIME_STAGE_FROM="$(grep -E '^FROM .* AS runtime$' "$DOCKERFILE" | head -1)"
assert_contains "$RUNTIME_STAGE_FROM" "debian" "runtime stage is based on a Debian (glibc) image"
assert_not_contains "$CONTENT" "FROM alpine" "no build stage uses an Alpine (musl) base image"

# 9. The non-root UID 1000 contract must be preserved regardless of which
#    user-management tool (Alpine's adduser vs. Debian's useradd/groupadd)
#    is used to create it.
assert_contains "$CONTENT" "1000" "runtime stage still creates its non-root user with UID/GID 1000"
assert_contains "$CONTENT" "USER ferrite" "runtime stage still switches to the non-root 'ferrite' user"

# 10. Container reachability: the runtime's default config must be a
#     generated, container-specific copy with server/metrics binds
#     rewritten to 0.0.0.0 — never a verbatim copy of the loopback-only
#     public example (which is unreachable through Docker's published-port
#     mapping) — and the public example file itself must be untouched.
assert_contains "$CONTENT" "AS runtime-config" \
  "Dockerfile has a dedicated stage that generates the container runtime config"
assert_contains "$CONTENT" 'sed ' \
  "runtime config generation uses a sed transform rather than a verbatim copy"
assert_contains "$CONTENT" 'bind = "0.0.0.0"' \
  "runtime config generation targets a 0.0.0.0 bind replacement"
assert_contains "$CONTENT" "COPY --from=runtime-config" \
  "final runtime stage copies the generated config from the runtime-config stage"
assert_not_contains "$CONTENT" 'COPY --chown=ferrite:ferrite ferrite.example.toml /etc/ferrite/ferrite.toml' \
  "final runtime stage no longer copies the public example verbatim as the container default"

# 10b. F-17/D-03: the runtime config must be generated and self-verified by
#      the exact freshly built binary (never read from ferrite.example.toml,
#      whose max_memory/eviction_policy values the real v0.3.0 parser
#      rejects), so the image starts successfully with zero mounted or
#      substituted config.
RUNTIME_CONFIG_STAGE_BODY="$(sed -n '/^FROM debian:bookworm-slim AS runtime-config$/,/^FROM debian:bookworm-slim AS runtime$/p' "$DOCKERFILE")"
assert_contains "$RUNTIME_CONFIG_STAGE_BODY" "COPY --from=builder" \
  "runtime-config stage copies the exact freshly built binary from the builder stage (not a separately fetched/published binary)"
assert_contains "$RUNTIME_CONFIG_STAGE_BODY" "ferrite init --minimal" \
  "runtime-config stage generates the baked-in config with the real binary's own \`ferrite init --minimal\`"
assert_contains "$RUNTIME_CONFIG_STAGE_BODY" "ferrite --test-config" \
  "runtime-config stage asserts the resulting config actually loads, using the exact freshly built binary (resolves F-17)"
assert_not_contains "$RUNTIME_CONFIG_STAGE_BODY" "ferrite.example.toml" \
  "runtime-config stage does not read the public ferrite.example.toml at all (F-17/D-03 resolved without editing it)"

# The public example file's own default (127.0.0.1, correct for local/native
# installs) must remain unmodified by this audit's container-reachability fix.
EXAMPLE_TOML="${REPO_ROOT}/ferrite.example.toml"
if [[ -f "$EXAMPLE_TOML" ]]; then
  EXAMPLE_BIND_COUNT="$(grep -c '^bind = "127\.0\.0\.1"$' "$EXAMPLE_TOML" || true)"
  assert_eq "2" "${EXAMPLE_BIND_COUNT:-0}" \
    "ferrite.example.toml keeps its documented 127.0.0.1 default for server and metrics binds"
fi

# 11. Source integrity: FERRITE_SOURCE_SHA256 must be declared, default to
#     the verified v0.4.0 tarball digest, and be checked before extraction
#     (i.e. the sha256sum verification must appear before the `tar`
#     extraction step in the source stage).
EXPECTED_SHA256="b4db8cc8eb0d3c2cef4a019a47d550c347df69fb8a4f77550c814fae463005cf"
ACTUAL_SHA256_DEFAULT="$(grep -oE '^ARG FERRITE_SOURCE_SHA256=[0-9a-fA-F]+' "$DOCKERFILE" | head -1 | cut -d= -f2)"
assert_eq "$EXPECTED_SHA256" "${ACTUAL_SHA256_DEFAULT:-}" \
  "ARG FERRITE_SOURCE_SHA256 defaults to the verified v0.4.0 tarball SHA256"

SOURCE_STAGE_BODY="$(sed -n '/^FROM chef AS source$/,/^FROM chef AS planner$/p' "$DOCKERFILE")"
assert_contains "$SOURCE_STAGE_BODY" "sha256sum -c -" \
  "source stage verifies the fetched tarball with sha256sum"
assert_contains "$SOURCE_STAGE_BODY" 'if [ -z "$FERRITE_SOURCE_SHA256" ]' \
  "source stage refuses to build when FERRITE_SOURCE_SHA256 is empty (required, not optional)"

SHA_CHECK_LINE="$(grep -n 'sha256sum -c -' "$DOCKERFILE" | head -1 | cut -d: -f1)"
TAR_EXTRACT_LINE="$(grep -n 'tar -xzf /tmp/ferrite-src.tar.gz' "$DOCKERFILE" | head -1 | cut -d: -f1)"
if [[ -n "$SHA_CHECK_LINE" && -n "$TAR_EXTRACT_LINE" ]]; then
  assert_true "$( [[ "$SHA_CHECK_LINE" -lt "$TAR_EXTRACT_LINE" ]]; echo $? )" \
    "checksum verification happens before tarball extraction"
fi

harness_summary
