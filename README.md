# Ferrite Ops

[![CI](https://github.com/ferritelabs/ferrite-ops/actions/workflows/ci.yml/badge.svg)](https://github.com/ferritelabs/ferrite-ops/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Hub-2496ED)](https://hub.docker.com/r/ferritelabs/ferrite)
[![Helm](https://img.shields.io/badge/Helm-Chart-0F1689)](charts/ferrite)

Deployment, monitoring, and packaging for [Ferrite](https://github.com/ferritelabs/ferrite) — a high-performance, tiered-storage key-value store.

## Contents

- `Dockerfile` + `docker-compose.yml` — Container setup
- `charts/ferrite/` — Helm chart for Kubernetes
- `terraform/` — Infrastructure-as-code modules for AWS ECS and EKS
- `gitops/` — ArgoCD, Flux, and Kustomize examples
- `grafana/` — Grafana monitoring dashboards
- `monitoring/` — Prometheus alerting rules
- `packaging/` — deb/rpm package definitions
- `scripts/` — Install and quickstart scripts
- `ferrite.example.toml` — Documentation-only example config (schema reference; generate a real runtime config via the image's own `ferrite init` instead — see `docker/docker-compose.custom-config.yml`)

## Quick Start

```bash
# Docker (single instance) — uses the image's own generated, validated config
docker compose up -d

# Docker with monitoring (Prometheus + Grafana)
docker compose --profile monitoring up -d

# Helm (Kubernetes)
helm install ferrite charts/ferrite

# Quickstart script (builds from source)
./scripts/quickstart.sh
```

### External Tester Quick Start

For a non-production candidate/hardening campaign cohort, follow the
[canonical Tester Program](https://github.com/ferritelabs/ferrite/blob/main/TESTER_PROGRAM.md).
Check out the exact campaign commit before running the isolated,
volume-preserving tester environment — there is no default branch or image;
both must be supplied by the campaign owner. Docker, Docker Compose v2, and
Python 3 (standard library only) are required:

```bash
git clone https://github.com/ferritelabs/ferrite-ops.git
cd ferrite-ops
git checkout --detach <CAMPAIGN_OPS_COMMIT>   # full 40-character lowercase commit SHA; never a tag, a branch, or main
test "$(git rev-parse HEAD)" = "<CAMPAIGN_OPS_COMMIT>" || {
  echo "HEAD is not <CAMPAIGN_OPS_COMMIT>; stop and re-request the campaign commit" >&2
  exit 1
}
test -x scripts/tester.sh && ./scripts/tester.sh --help >/dev/null || {
  echo "scripts/tester.sh is missing or not runnable at <CAMPAIGN_OPS_COMMIT>" >&2
  exit 1
}
export FERRITE_TEST_IMAGE='ghcr.io/ferritelabs/ferrite@sha256:<CAMPAIGN_DIGEST>' # complete repository-qualified digest the campaign owner supplied; never latest or a tag
./scripts/tester.sh start
./scripts/tester.sh smoke
./scripts/tester.sh diagnostics
./scripts/tester.sh stop
```

`FERRITE_TEST_IMAGE` has no default: `tester.sh` and `docker-compose.tester.yml`
both fail fast with an actionable error, before any Docker call, if it is
unset, an implicit/floating `latest` reference, a tag, or not the complete
repository-qualified sha256 digest form (`repository/path@sha256:<64
lowercase hex characters>`). `tester.sh` also verifies, before every
command that talks to the container, that the running container's image
still matches `FERRITE_TEST_IMAGE` exactly.

Docker reporting a container healthy only proves the in-container healthcheck
passed, so `start` additionally verifies host reachability with
`scripts/tester-host-probe.py` (Python 3 standard library only, bounded
timeouts) after health and image verification, and before claiming the
deployment is available on localhost. The probe sends a RESP `PING` to
`127.0.0.1:${FERRITE_TEST_PORT}` and requires `+PONG`, then performs an HTTP
`GET /metrics` against `127.0.0.1:${FERRITE_TEST_METRICS_PORT}` and requires a
2xx status with a non-empty body. Tune it with `FERRITE_TEST_PROBE_TIMEOUT`
(seconds, default 5) and `FERRITE_TEST_PROBE_RETRIES` (default 5); both
tester ports stay bound to loopback only.

`./scripts/tester.sh diagnostics` records the exact ops tooling commit from
`git -C <repo root> rev-parse HEAD` in `versions.txt`, `image.txt`, and
`report.md`. If that commit cannot be determined (for example the tooling was
copied out of its Git checkout), diagnostics fails instead of producing an
archive that misattributes its provenance.

Only run `./scripts/tester.sh durability` if the campaign owner has explicitly
enabled it (`FERRITE_TEST_ENABLE_DURABILITY=1`); it is an optional,
campaign-specific diagnostic track, not part of the core tester path, and the
script refuses to run it otherwise. Current candidate images may not persist
data across restart, so durability is not a core expected pass.

Use `./scripts/tester.sh reset` only when you are ready to delete the tester
volume. General deployment and operations guidance below remains authoritative
outside the tester program.

### Custom runtime configuration

By default `docker compose up` mounts nothing over `/etc/ferrite/ferrite.toml`,
so the container uses the image's own generated, build-time-validated config.
`ferrite.example.toml` is a documentation-only reference and is **not**
guaranteed to load in any specific packaged binary (its schema/defaults can
drift from a given release) — never copy it in directly as a runtime config.

To opt in to a custom `ferrite.toml`, generate one that is actually valid for
the exact image you're running with that image's own `ferrite init`, then
layer the custom-config override on top:

```bash
docker compose build ferrite   # or: docker pull <image>

mkdir -p ./ferrite-config
docker run --rm --entrypoint ferrite \
  -v "$(pwd)/ferrite-config:/etc/ferrite" \
  ferrite:0.4.0 \
  init --minimal --force -o /etc/ferrite/ferrite.toml -d /var/lib/ferrite/data

# ferrite init defaults to loopback-only binds; rewrite them so the
# container is reachable through Docker's published ports.
sed -i.bak 's/^bind = "127\.0\.0\.1"$/bind = "0.0.0.0"/' ./ferrite-config/ferrite.toml
rm -f ./ferrite-config/ferrite.toml.bak

cp ./ferrite-config/ferrite.toml ferrite.toml
docker compose -f docker-compose.yml -f docker/docker-compose.custom-config.yml up -d
```

Point at a different file without editing the override by setting `FERRITE_CONFIG`:

```bash
FERRITE_CONFIG=./ferrite-config/ferrite.toml \
  docker compose -f docker-compose.yml -f docker/docker-compose.custom-config.yml up -d
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

### HA with Docker Compose

For local development or non-Kubernetes environments:

```bash
docker compose -f docker/docker-compose.ha.yml up -d
```

This starts a 3-node cluster (1 primary + 2 replicas) with Prometheus and Grafana monitoring.

## Terraform Deployment

Deploy Ferrite on AWS using Terraform modules:

```bash
# AWS ECS Fargate (serverless containers)
module "ferrite" {
  source     = "github.com/ferritelabs/ferrite-ops//terraform/aws-ecs"
  name       = "ferrite-prod"
  vpc_id     = "vpc-abc123"
  subnet_ids = ["subnet-1", "subnet-2"]
}

# AWS EKS (Kubernetes via Helm)
module "ferrite" {
  source       = "github.com/ferritelabs/ferrite-ops//terraform/aws-eks"
  cluster_name = "my-cluster"
  enable_ha    = true
}
```

See [`terraform/README.md`](terraform/README.md) for full documentation.

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

If an eligible Docker Hub mirror or a stable floating tag needs repair, request
the default-branch reconciliation workflow with the narrowly scoped repository
dispatch event:

```bash
gh api --method POST \
  repos/ferritelabs/ferrite-ops/dispatches \
  -f event_type=reconcile-release-tags
```

This workflow intentionally has no `workflow_dispatch` trigger. GitHub resolves
`repository_dispatch` workflows from the default branch, and the job validates
the event, ref, and workflow definition before any registry login or write.

```bash
# Verify after release:
docker pull ferritelabs/ferrite:latest
docker run -d -p 6379:6379 ferritelabs/ferrite:latest
redis-cli PING  # → PONG
```

## 🌐 FerriteLabs Ecosystem

| Repository | Description |
|-----------|-------------|
| [ferrite](https://github.com/ferritelabs/ferrite) | Core database engine (Rust, 19 crates) |
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
