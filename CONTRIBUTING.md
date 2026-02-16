# Contributing to Ferrite Ops

Thank you for your interest in contributing! This repository contains deployment, monitoring, and packaging tools for [Ferrite](https://github.com/ferritelabs/ferrite).

## Getting Started

- Familiarize yourself with the [main Ferrite contributing guide](https://github.com/ferritelabs/ferrite/blob/main/CONTRIBUTING.md) for general project standards
- Review the repository structure in [README.md](README.md)

## How to Contribute

### Reporting Issues

- Use [GitHub Issues](https://github.com/ferritelabs/ferrite-ops/issues) for bug reports and feature requests
- Include your Docker/Kubernetes version and platform details

### Submitting Changes

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-change`)
3. Make your changes following the guidelines below
4. Test your changes locally
5. Commit with a clear message (`git commit -m "feat: description"`)
6. Push and open a Pull Request

## Development Guidelines

### Docker
- Use multi-stage builds to minimize image size
- Pin base image versions (e.g., `rust:1.88-bookworm`, not `rust:latest`)
- Include health checks in Dockerfiles and compose files

### Helm Charts
- Follow [Helm best practices](https://helm.sh/docs/chart_best_practices/)
- Validate templates with `helm lint` and `helm template`
- Document all values in `values.yaml` with comments

### Grafana Dashboards
- Export dashboards as JSON provisioning files
- Use template variables for data source and namespace
- Include both overview and detail panels

### Scripts
- Use `#!/usr/bin/env bash` and `set -euo pipefail`
- Support both macOS and Linux
- Include `--help` output for CLI scripts

## Commit Message Format

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <description>

Types: feat, fix, docs, chore, refactor, test
```

## Code of Conduct

Please be respectful, inclusive, and constructive in all interactions. See the [main project Code of Conduct](https://github.com/ferritelabs/ferrite/blob/main/CONTRIBUTING.md#code-of-conduct).

## License

By contributing, you agree that your contributions will be licensed under Apache-2.0.
