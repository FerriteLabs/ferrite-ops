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

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Apache-2.0

## Troubleshooting

### Container Fails to Start

Check logs with `docker compose logs ferrite` and ensure the data directory has correct permissions.

### Helm Release Stuck in Pending

Run `helm status ferrite` to check release state. If stuck, delete with `helm uninstall ferrite` and re-install.
