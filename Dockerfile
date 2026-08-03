# syntax=docker/dockerfile:1

# Security: container image is scanned by Trivy in CI before push
# See .github/workflows/container-scan.yml for details
#
# ferrite-ops does not vendor the Ferrite source. This build stage fetches
# the source tarball for FERRITE_VERSION from the public FerriteLabs/ferrite
# GitHub repository and builds from it. Override the tarball location with
# --build-arg FERRITE_SOURCE_URL=... (e.g. to build from a fork or a local
# mirror) without changing the FERRITE_VERSION default.
# Override at build time: docker build --build-arg FERRITE_VERSION=0.4.0
#   --build-arg FERRITE_SOURCE_SHA256=<sha256 of that version's tarball>
# FERRITE_SOURCE_SHA256 is required: any override of FERRITE_VERSION and/or
# FERRITE_SOURCE_URL must be paired with the matching tarball's SHA256, or
# the build fails during the `source` stage (see below).
ARG FERRITE_VERSION=0.4.0
FROM rust:1.95-slim-bookworm AS chef

# Install cargo-chef for caching dependencies, plus curl/ca-certificates to
# fetch the Ferrite source tarball (tar ships with the base image already).
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && cargo install cargo-chef

WORKDIR /app

# Build stage: fetch the Ferrite source tarball for FERRITE_VERSION
FROM chef AS source
ARG FERRITE_VERSION
ARG FERRITE_SOURCE_URL=https://github.com/FerriteLabs/ferrite/archive/refs/tags/v${FERRITE_VERSION}.tar.gz

# SHA256 of the fetched source tarball. Required and verified before
# extraction: a build with a missing, empty, or mismatched value fails
# loudly rather than silently trusting an unverified download. The
# default below is the real, verified SHA256 of the default
# FERRITE_VERSION's tarball (v0.4.0) at the URL above. Any override of
# FERRITE_VERSION and/or FERRITE_SOURCE_URL (e.g. a fork, a newer release,
# or a local mirror) must also pass a matching --build-arg
# FERRITE_SOURCE_SHA256=<sha256 of that exact tarball> — the v0.4.0
# default will not match a different tarball and the build will fail.
ARG FERRITE_SOURCE_SHA256=b4db8cc8eb0d3c2cef4a019a47d550c347df69fb8a4f77550c814fae463005cf

# The upstream source ships a dev-convenience .cargo/config.toml that pins
# a clang+mold linker for faster local rebuilds. Per that file's own
# comment it is not meant to affect CI/release builds, but Cargo applies
# it regardless of profile, and this minimal image intentionally doesn't
# install clang/mold. It is removed below so the container build uses the
# default toolchain linker (gcc, already present in this image).
RUN if [ -z "$FERRITE_SOURCE_SHA256" ]; then \
        echo "error: FERRITE_SOURCE_SHA256 build-arg is required to verify the fetched Ferrite source tarball; refusing to build without it." >&2; \
        exit 1; \
    fi \
    && curl -fsSL "$FERRITE_SOURCE_URL" -o /tmp/ferrite-src.tar.gz \
    && echo "${FERRITE_SOURCE_SHA256}  /tmp/ferrite-src.tar.gz" | sha256sum -c - \
    && mkdir -p /app \
    && tar -xzf /tmp/ferrite-src.tar.gz -C /app --strip-components=1 \
    && rm -f /tmp/ferrite-src.tar.gz \
    && test -f /app/Cargo.toml \
    && rm -f /app/.cargo/config.toml

# Build stage: Compute a recipe file
FROM chef AS planner

COPY --from=source /app /app

# Analyze dependencies
RUN cargo chef prepare --recipe-path recipe.json

# Build stage: Build dependencies (cached layer)
FROM chef AS builder

# Install system dependencies needed for building (Debian bookworm)
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the recipe from planner
COPY --from=planner /app/recipe.json recipe.json

# Build dependencies only (this layer is cached)
RUN cargo chef cook --release --recipe-path recipe.json

# Copy the fetched source code
COPY --from=source /app /app

# Preserve the Dockerfile's explicit Rust toolchain instead of allowing the
# fetched contributor toolchain file to replace it. Ferrite v0.3.0 and v0.4.0
# expose the Linux io_uring module when the optional feature is disabled, so
# gate it consistently. Both releases also need mutable Linux eBPF fields.
ARG FERRITE_VERSION
RUN rm -f rust-toolchain rust-toolchain.toml \
    && if [ "$FERRITE_VERSION" = "0.3.0" ] || [ "$FERRITE_VERSION" = "0.4.0" ]; then \
        sed -i \
          -e 's/#\[cfg(target_os = "linux")\]/#[cfg(all(target_os = "linux", feature = "io-uring"))]/g' \
          -e 's/#\[cfg(not(target_os = "linux"))\]/#[cfg(any(not(target_os = "linux"), not(feature = "io-uring")))]/g' \
          crates/ferrite-core/src/io/mod.rs; \
    fi \
    && if [ "$FERRITE_VERSION" = "0.3.0" ] || [ "$FERRITE_VERSION" = "0.4.0" ]; then \
        sed -i 's/let fields = vec!\[/let mut fields = vec![/g' \
          src/commands/handlers/ebpf.rs; \
    fi

# Build the application
RUN cargo build --release --bin ferrite --bin ferrite-cli

# Verify the binaries were built
RUN ls -lh /app/target/release/ferrite /app/target/release/ferrite-cli

# Build stage: generate the container-specific runtime config with the
# exact freshly built `ferrite` binary from the `builder` stage above,
# instead of packaging the repository's documented example
# (ferrite.example.toml) into the image. Two independent problems this
# fixes at once:
#
#   1. Reachability: containers are only ever reached through Docker's
#      published-port mapping into the container's network namespace; a
#      loopback-only bind (127.0.0.1, correct for local/native installs)
#      never accepts that forwarded traffic.
#   2. Loadability (F-17): the packaged ferrite.example.toml documents
#      `max_memory = "1GB"` (a quoted string) and
#      `eviction_policy = "noeviction"` — neither of which the real
#      legacy v0.3.0 binary's config parser actually accepts (it wants a raw
#      byte count and the hyphenated "no-eviction"/omitted-default,
#      respectively). Rather than special-case those values by hand
#      (fragile, and drifts the moment the example or parser changes
#      again), this stage asks the exact binary that will ship in the
#      image to generate its own config via `ferrite init --minimal`,
#      then only rewrites the bind addresses. The generated config is
#      then verified by asking that same binary to load it
#      (`ferrite --test-config`), so the build fails loudly rather than
#      shipping a config the packaged binary can't actually start with.
#
# The public ferrite.example.toml file itself — its schema, defaults, and
# documentation — is never read or modified by this stage.
FROM debian:bookworm-slim AS runtime-config

# Only the runtime shared libraries the compiled binary needs to execute
# at all (matches the final `runtime` stage below); no compilers or
# headers. `ferrite init`/`--test-config` do not open a network connection
# but the binary still dynamically links against these at process start.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# The exact freshly built binary from this same build — not a separately
# downloaded or previously published binary — so the generated/verified
# config is guaranteed to match what actually ships in the final image.
COPY --from=builder /app/target/release/ferrite /usr/local/bin/ferrite

RUN mkdir -p /etc/ferrite \
    # Generate a fresh config with the real binary's own generator
    # (schema-guaranteed to match this exact binary's parser) instead of
    # packaging the public example's values.
    && /usr/local/bin/ferrite init --minimal --force \
        -o /etc/ferrite/ferrite.toml -d /var/lib/ferrite/data \
    # Rewrite both the [server] and [metrics] loopback-only binds to
    # 0.0.0.0 so the container is reachable through Docker's
    # published-port mapping.
    && sed -i 's/^bind = "127\.0\.0\.1"$/bind = "0.0.0.0"/' \
        /etc/ferrite/ferrite.toml \
    # Build-time assertion #1: fail the build rather than ship an
    # unreachable container if the substitution above didn't take effect
    # (e.g. `ferrite init`'s output format changes) or if both the
    # [server] and [metrics] binds weren't both rewritten.
    && test "$(grep -c '^bind = "0\.0\.0\.0"$' /etc/ferrite/ferrite.toml)" -eq 2 \
    && ! grep -q '127\.0\.0\.1' /etc/ferrite/ferrite.toml \
    # Build-time assertion #2 (resolves F-17): fail the build rather than
    # ship a config the packaged binary can't actually load. This runs the
    # exact binary that will be copied into the final image against the
    # exact config that will be copied into the final image.
    && /usr/local/bin/ferrite --test-config --config /etc/ferrite/ferrite.toml \
        --data-dir /var/lib/ferrite/data

# Runtime stage: Minimal image
#
# Uses debian-slim (glibc) rather than Alpine (musl) so the runtime's C
# library ABI matches the `rust:1.95-slim-bookworm` builder stage above.
# The builder compiles and dynamically links against glibc (Debian
# bookworm); this build does not target or statically link musl, so
# running those binaries on an Alpine (musl) runtime is not guaranteed to
# work and can fail at startup with a missing dynamic linker/library
# error. bookworm-slim uses the same Debian release as the builder for a
# matching glibc ABI, while remaining a minimal image: no compilers,
# headers, or build tooling are installed, only the shared libraries the
# compiled binaries actually link against at runtime.
FROM debian:bookworm-slim AS runtime

# Re-declare to make the value available for the LABEL below: ARGs declared
# before the first FROM are not automatically visible inside build stages.
ARG FERRITE_VERSION

# Install only the runtime shared libraries the compiled binaries need:
# CA roots for outbound TLS connections, and libssl3 for the OpenSSL
# dynamic linkage the builder compiled against (libssl-dev, at build
# time). No compilers, headers, or package build tooling are installed.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user for running the application. Same UID/GID (1000)
# as the previous Alpine image, so existing volumes/data ownership from
# prior deployments remain valid.
RUN groupadd --gid 1000 ferrite \
    && useradd --uid 1000 --gid ferrite --no-create-home --shell /bin/sh ferrite

# Create data directory with proper permissions
RUN mkdir -p /var/lib/ferrite/data && \
    chown -R ferrite:ferrite /var/lib/ferrite

WORKDIR /app

# Copy the binaries from builder
COPY --from=builder /app/target/release/ferrite /usr/local/bin/ferrite
COPY --from=builder /app/target/release/ferrite-cli /usr/local/bin/ferrite-cli

# Copy the container-specific runtime config generated and verified above
# (see the runtime-config stage comment) with the exact freshly built
# binary via `ferrite init --minimal`, then bind-transformed and
# `--test-config`-checked with that same binary. This is baked into the
# image as its default CMD config below — no volume mount or config
# substitution is required for the image to start successfully. The
# repository's own ferrite.example.toml is never read or modified by this
# stage.
COPY --from=runtime-config --chown=ferrite:ferrite /etc/ferrite/ferrite.toml /etc/ferrite/ferrite.toml

# Switch to non-root user
USER ferrite

# Expose Redis-compatible port
EXPOSE 6379

# Expose metrics endpoint
EXPOSE 9090

# Set default environment variables
ENV RUST_LOG=ferrite=info
ENV FERRITE_DATA_DIR=/var/lib/ferrite/data

# Configure volume for persistent data
VOLUME ["/var/lib/ferrite/data"]

# Health check (shell form: exec-form CMD arrays cannot use shell operators
# like `||`, so this must not be written as a JSON array)
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD ferrite-cli PING || exit 1

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/ferrite"]

# Default command (can be overridden)
CMD ["--config", "/etc/ferrite/ferrite.toml"]

# Build information labels
LABEL org.opencontainers.image.title="Ferrite"
LABEL org.opencontainers.image.description="High-performance, tiered-storage key-value store (Redis-compatible)"
LABEL org.opencontainers.image.version="${FERRITE_VERSION}"
LABEL org.opencontainers.image.authors="Jose David Baena"
LABEL org.opencontainers.image.source="https://github.com/ferritelabs/ferrite"
LABEL org.opencontainers.image.licenses="Apache-2.0"
