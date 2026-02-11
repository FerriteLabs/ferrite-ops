# Ferrite Helm Chart

A Helm chart for deploying Ferrite - a high-performance, tiered-storage key-value store on Kubernetes.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.2.0+
- PV provisioner support (if persistence is enabled)

## Installation

### Add the Helm repository

```bash
helm repo add ferrite https://charts.ferrite.dev
helm repo update
```

### Install the chart

```bash
helm install my-ferrite ferrite/ferrite
```

### Install from local chart

```bash
helm install my-ferrite ./charts/ferrite
```

## Uninstallation

```bash
helm uninstall my-ferrite
```

## Configuration

See [values.yaml](./values.yaml) for the full list of configurable parameters.

### Common Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of Ferrite replicas | `1` |
| `image.repository` | Image repository | `ghcr.io/ferritelabs/ferrite` |
| `image.tag` | Image tag | `""` (uses appVersion) |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `service.type` | Service type | `ClusterIP` |
| `service.port` | Service port | `6379` |
| `persistence.enabled` | Enable persistence | `true` |
| `persistence.size` | PVC size | `10Gi` |
| `resources.requests.cpu` | CPU request | `500m` |
| `resources.requests.memory` | Memory request | `1Gi` |
| `resources.limits.cpu` | CPU limit | `2000m` |
| `resources.limits.memory` | Memory limit | `4Gi` |

### Ferrite Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ferrite.server.maxConnections` | Maximum connections | `10000` |
| `ferrite.storage.databases` | Number of databases | `16` |
| `ferrite.storage.maxMemory` | Maximum memory (bytes) | `1073741824` |
| `ferrite.storage.backend` | Storage backend | `memory` |
| `ferrite.persistence.aofEnabled` | Enable AOF | `true` |
| `ferrite.persistence.aofSync` | AOF sync policy | `everysec` |
| `ferrite.logging.level` | Log level | `info` |
| `ferrite.metrics.enabled` | Enable Prometheus metrics | `true` |
| `ferrite.tls.enabled` | Enable TLS | `false` |
| `ferrite.auth.enabled` | Enable authentication | `false` |

### High Availability

| Parameter | Description | Default |
|-----------|-------------|---------|
| `cluster.enabled` | Enable cluster mode | `false` |
| `cluster.port` | Cluster communication port | `16379` |
| `replication.enabled` | Enable replication | `false` |
| `replication.role` | Role (primary/replica) | `primary` |

### Monitoring

| Parameter | Description | Default |
|-----------|-------------|---------|
| `serviceMonitor.enabled` | Enable ServiceMonitor | `false` |
| `serviceMonitor.interval` | Scrape interval | `15s` |
| `prometheusRule.enabled` | Enable PrometheusRule | `false` |

## Examples

### Basic Installation

```bash
helm install ferrite ./charts/ferrite
```

### With Custom Resources

```bash
helm install ferrite ./charts/ferrite \
  --set resources.requests.memory=2Gi \
  --set resources.limits.memory=8Gi \
  --set ferrite.storage.maxMemory=6442450944
```

### With Persistence

```bash
helm install ferrite ./charts/ferrite \
  --set persistence.enabled=true \
  --set persistence.size=50Gi \
  --set persistence.storageClassName=fast-ssd
```

### With TLS

```bash
# Create TLS secret
kubectl create secret tls ferrite-tls \
  --cert=path/to/cert.pem \
  --key=path/to/key.pem

# Install with TLS enabled
helm install ferrite ./charts/ferrite \
  --set ferrite.tls.enabled=true \
  --set ferrite.tls.secretName=ferrite-tls
```

### With Authentication

```bash
# Create password secret
kubectl create secret generic ferrite-auth \
  --from-literal=password=mysecretpassword

# Install with auth enabled
helm install ferrite ./charts/ferrite \
  --set ferrite.auth.enabled=true \
  --set ferrite.auth.existingSecret=ferrite-auth
```

### With Prometheus Operator

```bash
helm install ferrite ./charts/ferrite \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.additionalLabels.release=prometheus
```

### High Availability Cluster

```bash
helm install ferrite ./charts/ferrite \
  --set replicaCount=3 \
  --set cluster.enabled=true \
  --set podDisruptionBudget.enabled=true \
  --set podDisruptionBudget.minAvailable=2
```

### Primary-Replica Setup

```bash
# Install primary
helm install ferrite-primary ./charts/ferrite \
  --set replication.enabled=true \
  --set replication.role=primary

# Install replicas
helm install ferrite-replica ./charts/ferrite \
  --set replicaCount=2 \
  --set replication.enabled=true \
  --set replication.role=replica \
  --set replication.primaryHost=ferrite-primary
```

## Upgrading

```bash
helm upgrade my-ferrite ./charts/ferrite
```

## Persistence

The chart uses a StatefulSet to maintain pod identity and persistent volumes. When persistence is enabled, each pod gets its own PersistentVolumeClaim.

To migrate data:

1. Scale down the StatefulSet
2. Backup the PVC data
3. Upgrade the chart
4. Scale up the StatefulSet

## Monitoring

### Prometheus Metrics

Ferrite exposes Prometheus metrics on port 9090 by default. Enable ServiceMonitor for automatic discovery:

```yaml
serviceMonitor:
  enabled: true
  interval: 15s
```

### Grafana Dashboard

Import the included dashboard from `grafana/ferrite-dashboard.json`.

## Troubleshooting

### Pod not starting

Check events:
```bash
kubectl describe pod ferrite-0
```

Check logs:
```bash
kubectl logs ferrite-0
```

### Connection refused

Verify the service:
```bash
kubectl get svc ferrite
kubectl describe svc ferrite
```

### Persistence issues

Check PVC status:
```bash
kubectl get pvc
kubectl describe pvc data-ferrite-0
```

## License

Apache 2.0 - See [LICENSE](../../LICENSE) for details.
