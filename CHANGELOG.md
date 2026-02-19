# Changelog

All notable changes to Ferrite Ops will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-01-23

### Added

- **Docker**: Multi-stage Dockerfile with cargo-chef dependency caching (Rust 1.88)
- **Docker**: Security-hardened runtime — non-root user (UID 1000), read-only filesystem, capabilities dropped
- **Docker**: Built-in HEALTHCHECK via PING (30s interval, 3s timeout)
- **Docker Compose**: Multi-profile support (base, monitoring, Redis comparison, benchmarking)
- **Helm Chart** (v0.1.0): StatefulSet-based Kubernetes deployment with persistent volume claims
- **Helm Chart**: ConfigMap, Service, ServiceAccount, ServiceMonitor, TLS Secret, Certificate, Backup CronJob templates
- **Helm Chart**: Security context enforcement — non-root, read-only filesystem, resource limits
- **Grafana**: Pre-built dashboard (ferrite-dashboard.json) with 6 metric rows (overview, performance, memory/storage, connections, persistence, replication)
- **Grafana**: 14+ Prometheus metrics: memory, ops rate, latency percentiles (P50/P95/P99/P99.9), cache hit rate, HybridLog tier distribution
- **Packaging**: Debian (.deb) package with systemd integration
- **Packaging**: RPM package for RHEL/CentOS/Fedora with SELinux configuration
- **Scripts**: `quickstart.sh` (source build with dependency validation), `install.sh` (binary installation with platform detection)
- **Scripts**: `backup.sh` / `restore.sh` for data persistence, `smoke_test.sh` for health validation
- **Scripts**: `quickstart.ps1` for Windows (PowerShell)
- **Configuration**: Example TOML configuration with server, storage, persistence, metrics, logging, TLS, cluster, and replication sections
- **CI/CD**: Docker build + Helm lint + gitleaks secret scanning + Trivy container security scanning
- **CI/CD**: Multi-platform release builds (amd64 + arm64) with Cosign keyless signing
- **CI/CD**: SBOM generation (SPDX + CycloneDX) with SLSA provenance attestation

[Unreleased]: https://github.com/ferritelabs/ferrite-ops/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ferritelabs/ferrite-ops/releases/tag/v0.1.0
