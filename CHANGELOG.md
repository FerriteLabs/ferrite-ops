# Changelog

All notable changes to Ferrite Ops will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-03-09

### Added
- 5 new Grafana dashboards: Memory Tiers, Query Performance, Cluster & Replication, CDC & Streaming, Vector Search & AI
- 7 new Prometheus alert rules for production monitoring
- 6 operational runbooks for common failure scenarios
- Grafana provisioning configs for auto-loading dashboards and datasources
- Docker Hub publishing support in release workflow with smoke testing

### Changed
- Benchmark docker-compose: pinned Redis image to 7.4.2-alpine

## [0.2.0] - 2026-02-28

### Added
- Helm chart: NetworkPolicy template for pod traffic restriction
- Helm chart: HorizontalPodAutoscaler (HPA) template
- Helm chart: PodDisruptionBudget template
- Helm chart: RBAC (Role + RoleBinding) template
- Helm chart: Ingress template
- Helm chart: Connection test template (`helm test`)
- Helm chart: Helm repository publishing workflow (chart-releaser)
- Helm chart: Additional config values (storage limits, protocol limits, persistence paths)
- Grafana: Connection open rate, eviction/expiration, AOF write, replication event panels
- Prometheus: CPU saturation and command error rate alerts
- Dockerfile: Parameterized version label via `ARG FERRITE_VERSION`
- Security warnings in Helm NOTES.txt for disabled TLS/auth
- ShellCheck CI workflow for scripts
- Dependabot auto-merge workflow
- Chart version auto-bump on upstream release dispatch

### Changed
- Pinned `trivy-action` from `@master` to `@0.28.0`
- Added `github-actions` ecosystem to dependabot.yml

### Security
- Added SECURITY.md with vulnerability reporting guidelines

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

[Unreleased]: https://github.com/ferritelabs/ferrite-ops/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/ferritelabs/ferrite-ops/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ferritelabs/ferrite-ops/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ferritelabs/ferrite-ops/releases/tag/v0.1.0
