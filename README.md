# Ferrite Ops

[![CI](https://github.com/ferritelabs/ferrite-ops/actions/workflows/ci.yml/badge.svg)](https://github.com/ferritelabs/ferrite-ops/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

Deployment, monitoring, and packaging for [Ferrite](https://github.com/ferritelabs/ferrite).

## Contents

- `Dockerfile` + `docker-compose.yml` — Container setup
- `charts/ferrite/` — Helm chart for Kubernetes
- `grafana/` — Grafana monitoring dashboards
- `packaging/` — deb/rpm package definitions
- `scripts/` — Install and quickstart scripts
- `ferrite.example.toml` — Example configuration

## Quick Start

```bash
# Docker
docker-compose up

# Helm
helm install ferrite charts/ferrite

# Script
./scripts/quickstart.sh
```

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

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Apache-2.0

## Troubleshooting

### Container Fails to Start

Check logs with `docker compose logs ferrite` and ensure the data directory has correct permissions.

### Helm Release Stuck in Pending

Run `helm status ferrite` to check release state. If stuck, delete with `helm uninstall ferrite` and re-install.
