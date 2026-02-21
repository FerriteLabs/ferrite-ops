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

## License

Apache-2.0
