# syntax=docker/dockerfile:1

# Build stage 1: Compute a recipe file
ARG BUILDPLATFORM=linux/amd64
ARG FERRITE_VERSION=0.2.0
FROM --platform=$BUILDPLATFORM rust:1.93-slim-bookworm AS chef
ARG TARGETARCH=amd64

# Install cargo-chef for caching dependencies
RUN cargo install cargo-chef

WORKDIR /app

# Build stage 2: Cache dependencies
FROM chef AS planner

# Copy all source files to plan the build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY crates ./crates
COPY benches ./benches

# Analyze dependencies
RUN cargo chef prepare --recipe-path recipe.json

# Build stage 3: Build dependencies (cached layer)
FROM chef AS builder

# Install system dependencies needed for building
RUN apk add --no-cache \
    pkg-config \
    libssl-dev \

WORKDIR /app

# Copy the recipe from planner
COPY --from=planner /app/recipe.json recipe.json

# Build dependencies only (this layer is cached)
RUN cargo chef cook --release --recipe-path recipe.json

# Copy source code
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY crates ./crates
COPY benches ./benches

# Build the application
# Note: io-uring feature is Linux-only and requires kernel 5.11+
# We enable it here, but it will gracefully fall back on other platforms
RUN cargo build --release --bin ferrite --bin ferrite-cli

# Verify the binaries were built
RUN ls -lh /app/target/release/ferrite /app/target/release/ferrite-cli

# Runtime stage: Minimal image
FROM alpine:3.23.3 AS runtime

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

# Copy default configuration if it exists
COPY --chown=ferrite:ferrite ferrite.toml /etc/ferrite/ferrite.toml 2>/dev/null || true

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

# Health check
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/ferrite-cli", "PING"] || exit 1

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
