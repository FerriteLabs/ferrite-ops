# GitOps Examples

Deploy and manage Ferrite using GitOps patterns with popular tools.

## Contents

| Tool | Path | Description |
|------|------|-------------|
| **ArgoCD** | `argocd/application.yaml` | ArgoCD Application manifest (single-env quickstart) |
| **ArgoCD** | `argocd/overlays/staging.yaml` | ArgoCD staging Application |
| **ArgoCD** | `argocd/overlays/production.yaml` | ArgoCD production Application (HA, pinned tag) |
| **Flux** | `flux/helmrelease.yaml` | Flux HelmRelease (single-env quickstart) |
| **Flux** | `flux/overlays/staging.yaml` | Flux staging HelmRelease |
| **Flux** | `flux/overlays/production.yaml` | Flux production HelmRelease (HA, pinned tag) |
| **Kustomize** | `kustomize/` | Kustomize base + overlays for dev/staging/production |

## ArgoCD

### Quick Start (single environment)

```bash
kubectl apply -f argocd/application.yaml
```

### Multi-Environment

```bash
# Staging — follows HEAD, auto-syncs, 1 replica, 4Gi memory
kubectl apply -f argocd/overlays/staging.yaml

# Production — pinned to release tag, manual prune, 3 replicas, 16Gi, PDB
kubectl apply -f argocd/overlays/production.yaml
```

Key differences in production:
- `targetRevision` pinned to a release tag (not HEAD)
- `prune: false` — requires manual approval for resource deletion
- HA values file included (`values-ha.yaml`)
- Pod Disruption Budget enabled (`minAvailable: 2`)
- Notification annotations (commented; enable for Slack alerts)

## Flux

### Quick Start (single environment)

```bash
kubectl apply -f flux/helmrelease.yaml
```

### Multi-Environment

```bash
# Staging — follows main branch, auto-reconciles every 10m
kubectl apply -f flux/overlays/staging.yaml

# Production — pinned to release tag, reconciles every 30m, HA
kubectl apply -f flux/overlays/production.yaml
```

Key differences in production:
- Git source pinned to a release tag
- Longer reconciliation interval (30m vs 10m)
- Rollback remediation strategy on upgrade failure
- Pod Disruption Budget enabled

## Kustomize

```bash
# Development
kubectl apply -k kustomize/overlays/development

# Staging
kubectl apply -k kustomize/overlays/staging

# Production
kubectl apply -k kustomize/overlays/production
```

Kustomize overlays provide environment-specific configuration without duplicating YAML. The base defines common resources, overlays customize for each environment.

## Prerequisites

- Kubernetes cluster (1.25+)
- One of: ArgoCD, Flux v2, or Kustomize
- `kubectl` configured for your cluster
