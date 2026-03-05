# GitOps Examples

Deploy and manage Ferrite using GitOps patterns with popular tools.

## Contents

| Tool | File | Description |
|------|------|-------------|
| **ArgoCD** | `argocd/application.yaml` | ArgoCD Application manifest |
| **Flux** | `flux/helmrelease.yaml` | Flux HelmRelease for automated Helm deployments |
| **Kustomize** | `kustomize/` | Kustomize base + overlays for dev/staging/production |

## ArgoCD

```bash
kubectl apply -f argocd/application.yaml
```

The ArgoCD Application watches the Ferrite Helm chart and auto-syncs when chart values change. Configure sync policies, health checks, and notifications in the manifest.

## Flux

```bash
kubectl apply -f flux/helmrelease.yaml
```

The Flux HelmRelease installs Ferrite from the Helm chart with configurable values. Flux automatically reconciles drift and rolls out updates on new chart versions.

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
