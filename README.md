# Ferrite Ops

[![CI](https://github.com/ferritelabs/ferrite-ops/actions/workflows/ci.yml/badge.svg)](https://github.com/ferritelabs/ferrite-ops/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Hub-2496ED)](https://hub.docker.com/r/ferritelabs/ferrite)
[![Helm](https://img.shields.io/badge/Helm-Chart-0F1689)](charts/ferrite)

Deployment, monitoring, and packaging for [Ferrite](https://github.com/ferritelabs/ferrite) — a high-performance, tiered-storage key-value store.

## Contents

- `Dockerfile` + `docker-compose.yml` — Container setup
- `charts/ferrite/` — Helm chart for Kubernetes
- `gitops/` — ArgoCD, Flux, and Kustomize examples
- `grafana/` — Grafana monitoring dashboards
- `monitoring/` — Prometheus alerting rules
- `packaging/` — deb/rpm package definitions
- `scripts/` — Install and quickstart scripts
- `ferrite.example.toml` — Example configuration

## Quick Start

```bash
# Docker (single instance)
docker compose up -d

# Docker with monitoring (Prometheus + Grafana)
docker compose --profile monitoring up -d

# Helm (Kubernetes)
helm install ferrite charts/ferrite

# Quickstart script (builds from source)
./scripts/quickstart.sh
```

## Operational Quick Reference

| Task | Command |
|------|---------|
| Start Ferrite | `docker compose up -d` |
| Stop Ferrite | `docker compose down` |
| View logs | `docker compose logs -f ferrite` |
| Health check | `docker exec ferrite ferrite-cli PING` |
| Backup data | `./scripts/backup.sh /path/to/backup` |
| Restore data | `./scripts/restore.sh /path/to/backup` |
| Smoke test | `./scripts/smoke_test.sh` |
| Metrics | `curl http://localhost:9090/metrics` |
| Grafana | `http://localhost:3000` (admin/admin) |
| Prometheus | `http://localhost:9091` |

### Ports

| Port | Service |
|------|---------|
| 6379 | Ferrite (Redis-compatible) |
| 9090 | Prometheus metrics endpoint |
| 3000 | Grafana (when monitoring profile active) |
| 9091 | Prometheus server (when monitoring profile active) |

## GitOps Deployment

Deploy Ferrite using GitOps patterns:

```bash
# ArgoCD
kubectl apply -f gitops/argocd/application.yaml

# Flux
kubectl apply -f gitops/flux/helmrelease.yaml

# Kustomize (choose your environment)
kubectl apply -k gitops/kustomize/overlays/production
```

See [`gitops/README.md`](gitops/README.md) for full examples including development, staging, and production overlays.

## High Availability Deployment

Deploy Ferrite in HA mode with 3 pods (1 primary + 2 replicas), pod anti-affinity, and a PodDisruptionBudget:

```bash
helm install ferrite charts/ferrite -f charts/ferrite/values-ha.yaml
```

After install, configure replication:

```bash
kubectl exec ferrite-1 -- ferrite-cli REPLICAOF ferrite-0.ferrite-headless 6379
kubectl exec ferrite-2 -- ferrite-cli REPLICAOF ferrite-0.ferrite-headless 6379
```

See [`charts/ferrite/values-ha.yaml`](charts/ferrite/values-ha.yaml) for the full HA configuration including memory limits, persistence, and monitoring settings.

## Grafana Dashboards

Import dashboards from `grafana/dashboards/`:

```bash
# Copy dashboards to Grafana provisioning directory
cp grafana/dashboards/*.json /var/lib/grafana/dashboards/

# Or use Docker Compose with monitoring profile
docker compose --profile monitoring up -d
```

Available dashboards:
- **Ferrite Overview** — Key metrics, memory, and throughput
- **Ferrite Operations** — Command latency and error rates
- **Memory Tier Distribution** — HybridLog hot/warm/cold tier visualization
- **Query Performance** — Command latency breakdown, slow queries, QPS
- **Cluster & Replication** — Cluster state, replication lag, failover events
- **CDC & Streaming** — Event throughput, consumer lag, pipeline latency
- **Vector Search & AI** — Search QPS, embedding rate, semantic cache hit rate

## Prometheus Alerts

Alert rules are defined in `monitoring/prometheus-alerts.yml` and `grafana/prometheus-alerts.yml`. Key alerts include:

| Alert | Severity | Trigger |
|-------|----------|---------|
| `FerriteDown` | critical | Instance unreachable for >1 min |
| `HighMemoryUsage` | warning | Memory usage >80% of limit |
| `ReplicationLag` | warning | Replica lag >10s |
| `HighCommandLatency` | warning | P99 latency >10ms |
| `BackupOverdue` | warning | No successful backup in 24h |
| `DiskIOLatency` | warning | Disk I/O latency >50ms |
| `SplitBrainDetected` | critical | Multiple primaries detected |

### Alert Runbooks

Operational runbooks are available in `monitoring/runbooks/`:

- **high-memory.md** — Memory pressure troubleshooting
- **high-latency.md** — Command latency investigation
- **replication-lag.md** — Replication delay diagnosis
- **cluster-failure.md** — Cluster recovery procedures
- **backup-failure.md** — Backup failure resolution
- **disk-full.md** — Disk space recovery

## Docker Hub Publishing

The release workflow pushes images to both GHCR and Docker Hub. To enable Docker Hub:

1. Create a Docker Hub access token at https://hub.docker.com/settings/security
2. Add these secrets to the `ferrite-ops` repository (Settings → Secrets → Actions):
   - `DOCKERHUB_USERNAME` — your Docker Hub username
   - `DOCKERHUB_TOKEN` — the access token (not your password)
3. The release workflow will automatically push to `ferritelabs/ferrite` on Docker Hub when a `v*` tag is pushed

```bash
# Verify after release:
docker pull ferritelabs/ferrite:latest
docker run -d -p 6379:6379 ferritelabs/ferrite:latest
redis-cli PING  # → PONG
```

## 🌐 FerriteLabs Ecosystem

| Repository | Description |
|-----------|-------------|
| [ferrite](https://github.com/ferritelabs/ferrite) | Core database engine (Rust, 12 crates) |
| [ferrite-docs](https://github.com/ferritelabs/ferrite-docs) | Documentation website |
| **ferrite-ops** | 📍 You are here |
| [ferrite-bench](https://github.com/ferritelabs/ferrite-bench) | Performance benchmarks |
| [vscode-ferrite](https://github.com/ferritelabs/vscode-ferrite) | VS Code extension |
| [jetbrains-ferrite](https://github.com/ferritelabs/jetbrains-ferrite) | JetBrains IDE plugin |
| [homebrew-tap](https://github.com/ferritelabs/homebrew-tap) | Homebrew formula |

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Apache-2.0

## Troubleshooting

### Container Fails to Start

Check logs with `docker compose logs ferrite` and ensure the data directory has correct permissions.

### Helm Release Stuck in Pending

Run `helm status ferrite` to check release state. If stuck, delete with `helm uninstall ferrite` and re-install.
