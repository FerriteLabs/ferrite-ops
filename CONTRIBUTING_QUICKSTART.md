# Contributing Quickstart — ferrite-ops

Get up and running in 5 minutes.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) 24+
- [Docker Compose](https://docs.docker.com/compose/install/) v2+
- [Helm](https://helm.sh/docs/intro/install/) 3+ (for chart changes)
- [ShellCheck](https://www.shellcheck.net/) (for script linting)

## Fork & Clone

```bash
gh repo fork ferritelabs/ferrite-ops --clone
cd ferrite-ops
```

## Build & Test Locally

```bash
# Build the Docker image (requires ferrite source alongside)
docker build -t ferrite:dev -f Dockerfile ../ferrite/

# Start the full stack
docker compose up -d

# Verify
docker compose ps
curl -s http://localhost:9090/metrics | head -5

# Run the smoke test
./scripts/smoke_test.sh
```

## Helm Chart Development

```bash
# Lint the chart
helm lint charts/ferrite

# Template render (dry run)
helm template ferrite charts/ferrite

# Test HA values
helm template ferrite charts/ferrite -f charts/ferrite/values-ha.yaml
```

## What to Work On

- Look for [good first issues](https://github.com/ferritelabs/ferrite-ops/labels/good%20first%20issue)
- Improve Grafana dashboards in `grafana/dashboards/`
- Add monitoring runbooks in `monitoring/runbooks/`
- Improve Helm chart templates in `charts/`

## Submitting Changes

1. Create a feature branch: `git checkout -b my-change`
2. Make your changes
3. Test locally with `docker compose up`
4. Commit using [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`
5. Push and open a PR

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

---

**Part of [FerriteLabs](https://github.com/ferritelabs)** — see the [core engine](https://github.com/ferritelabs/ferrite) for the full project.
