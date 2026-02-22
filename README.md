# Ferrite Ops

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

## License

Apache-2.0
