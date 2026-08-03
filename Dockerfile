# syntax=docker/dockerfile:1

# Security: container image is scanned by Trivy in CI before push
# See .github/workflows/container-scan.yml for details
#
# ferrite-ops does not vendor the Ferrite source. This build stage fetches
# the source tarball for FERRITE_VERSION from the public FerriteLabs/ferrite
# GitHub repository and builds from it. Override the tarball location with
# --build-arg FERRITE_SOURCE_URL=... (e.g. to build from a fork or a local
# mirror) without changing the FERRITE_VERSION default.
ARG BUILDPLATFORM=linux/amd64
# Override at build time: docker build --build-arg FERRITE_VERSION=0.4.0
ARG FERRITE_VERSION=0.3.0
FROM --platform=$BUILDPLATFORM rust:1.95-slim-bookworm AS chef
ARG TARGETARCH=amd64

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

# The upstream source ships a dev-convenience .cargo/config.toml that pins
# a clang+mold linker for faster local rebuilds. Per that file's own
# comment it is not meant to affect CI/release builds, but Cargo applies
# it regardless of profile, and this minimal image intentionally doesn't
# install clang/mold. It is removed below so the container build uses the
# default toolchain linker (gcc, already present in this image).
RUN curl -fsSL "$FERRITE_SOURCE_URL" -o /tmp/ferrite-src.tar.gz \
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

# Build the application
# Note: io-uring feature is Linux-only and requires kernel 5.11+
# We enable it here, but it will gracefully fall back on other platforms
RUN cargo build --release --bin ferrite --bin ferrite-cli

# Verify the binaries were built
RUN ls -lh /app/target/release/ferrite /app/target/release/ferrite-cli

# Runtime stage: Minimal image
FROM alpine:3.23.4 AS runtime

# Re-declare to make the value available for the LABEL below: ARGs declared
# before the first FROM are not automatically visible inside build stages.
ARG FERRITE_VERSION

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    libssl3

# Create a non-root user for running the application
RUN adduser -D -u 1000 -s /bin/sh ferrite

# Create data directory with proper permissions
RUN mkdir -p /var/lib/ferrite/data && \
    chown -R ferrite:ferrite /var/lib/ferrite

WORKDIR /app

# Copy the binaries from builder
COPY --from=builder /app/target/release/ferrite /usr/local/bin/ferrite
COPY --from=builder /app/target/release/ferrite-cli /usr/local/bin/ferrite-cli

# Copy the repository's example configuration as the runtime default.
# Unlike ferrite.toml (a user-generated file that doesn't exist in this
# repo), ferrite.example.toml is always present, so this COPY cannot fail.
COPY --chown=ferrite:ferrite ferrite.example.toml /etc/ferrite/ferrite.toml

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
