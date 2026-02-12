# Ferrite Sidecar Helm Chart

Deploy Ferrite as a sidecar cache container alongside your application pods. This chart provides a lightweight, memory-only Ferrite instance that runs in the same pod as your application for ultra-low-latency caching.

## Overview

The sidecar pattern co-locates a Ferrite cache instance with each application pod. Your application connects to `localhost:6379` -- no network hop, no service discovery, no shared cache contention.

```
+----------------------------------+
|             Pod                  |
|  +-----------+  +--------------+ |
|  |    App    |--|   Ferrite    | |
|  | Container |  |   Sidecar   | |
|  +-----------+  +--------------+ |
|    localhost:6379                 |
+----------------------------------+
```

With auto-injection enabled, the chart deploys a mutating admission webhook that automatically injects Ferrite sidecar containers into annotated pods in labeled namespaces -- no manual pod spec changes required.

## Quick Start

### Manual Sidecar Injection

Add the Ferrite sidecar configuration to your deployment:

```bash
# Install the chart (creates the ConfigMap and webhook)
helm install ferrite-cache ./charts/ferrite-sidecar \
  --set webhook.enabled=false
```

Then add the sidecar container to your pod spec:

```yaml
spec:
  containers:
    - name: my-app
      image: my-app:latest
      # ... your app config
    - name: ferrite-sidecar
      image: ghcr.io/ferritelabs/ferrite:0.1.0
      ports:
        - containerPort: 6379
          name: ferrite
      resources:
        limits:
          cpu: 250m
          memory: 256Mi
        requests:
          cpu: 50m
          memory: 64Mi
      volumeMounts:
        - name: ferrite-config
          mountPath: /etc/ferrite
  volumes:
    - name: ferrite-config
      configMap:
        name: ferrite-cache-ferrite-sidecar
```

### Automatic Injection (Webhook)

The recommended approach. The chart deploys a mutating admission webhook that automatically injects a Ferrite sidecar container into pods that opt in.

#### Step 1: Install the chart with the webhook enabled

```bash
# Self-signed certificates (default, no cert-manager required)
helm install ferrite-cache ./charts/ferrite-sidecar

# Or with cert-manager for certificate management
helm install ferrite-cache ./charts/ferrite-sidecar \
  --set webhook.certManager.enabled=true \
  --set webhook.certManager.issuerRef.name=my-cluster-issuer \
  --set webhook.certManager.issuerRef.kind=ClusterIssuer
```

#### Step 2: Label the target namespace

Only namespaces with the `ferrite.dev/inject: enabled` label are in scope for injection. This prevents accidental injection in system namespaces.

```bash
kubectl label namespace my-app ferrite.dev/inject=enabled
```

#### Step 3: Annotate pods for injection

Add the `ferrite.dev/inject: "true"` annotation to pods (or pod templates in Deployments, StatefulSets, etc.) that should receive a Ferrite sidecar:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
      annotations:
        ferrite.dev/inject: "true"
    spec:
      containers:
        - name: my-app
          image: my-app:latest
          ports:
            - containerPort: 8080
```

When the pod is created, the webhook intercepts the request and adds:
- A Ferrite sidecar container with the configured image, resources, and ports
- A volume mount for the Ferrite configuration ConfigMap
- The `ferrite-config` volume referencing the chart's ConfigMap

#### Step 4: Verify injection

```bash
# Check that the pod has two containers
kubectl get pods -n my-app
# NAME                      READY   STATUS    RESTARTS   AGE
# my-app-6d8f9b7c4-x2k9p   2/2     Running   0          30s

# Inspect the injected sidecar
kubectl describe pod -n my-app my-app-6d8f9b7c4-x2k9p

# Test connectivity from inside the app container
kubectl exec -n my-app my-app-6d8f9b7c4-x2k9p -c my-app -- \
  redis-cli -h 127.0.0.1 -p 6379 PING
# PONG
```

## Certificate Management

The webhook requires TLS certificates. Two options are supported:

### Option A: Self-signed certificates (default)

When `webhook.certManager.enabled=false` (the default), a Helm pre-install/pre-upgrade hook runs a Job using `kube-webhook-certgen` to:
1. Generate a self-signed CA and TLS certificate
2. Store them in a Kubernetes Secret
3. Patch the MutatingWebhookConfiguration with the CA bundle

This requires no external dependencies. Certificates are regenerated on each `helm upgrade`.

### Option B: cert-manager

When `webhook.certManager.enabled=true`, the chart creates a cert-manager `Certificate` resource that automates certificate lifecycle management including rotation.

Prerequisites:
- [cert-manager](https://cert-manager.io/) installed in the cluster
- A `ClusterIssuer` or `Issuer` resource configured

```bash
helm install ferrite-cache ./charts/ferrite-sidecar \
  --set webhook.certManager.enabled=true \
  --set webhook.certManager.issuerRef.name=letsencrypt-prod \
  --set webhook.certManager.issuerRef.kind=ClusterIssuer
```

## Configuration

### Webhook Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `webhook.enabled` | Enable the mutating admission webhook | `true` |
| `webhook.port` | Webhook server listen port | `8443` |
| `webhook.certManager.enabled` | Use cert-manager for TLS certificates | `false` |
| `webhook.certManager.issuerRef.name` | cert-manager issuer name | `selfsigned-issuer` |
| `webhook.certManager.issuerRef.kind` | cert-manager issuer kind | `ClusterIssuer` |
| `webhook.namespaceSelector.matchLabels` | Namespace labels for injection scope | `ferrite.dev/inject: enabled` |
| `webhook.failurePolicy` | Webhook failure policy (Ignore or Fail) | `Ignore` |

### Injector Deployment Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `injector.image.repository` | Injector image repository | `ghcr.io/ferritelabs/ferrite-sidecar-injector` |
| `injector.image.tag` | Injector image tag | `latest` |
| `injector.replicas` | Number of injector replicas | `1` |
| `injector.resources.requests.cpu` | Injector CPU request | `50m` |
| `injector.resources.requests.memory` | Injector memory request | `64Mi` |
| `injector.resources.limits.cpu` | Injector CPU limit | `100m` |
| `injector.resources.limits.memory` | Injector memory limit | `128Mi` |

### Injected Sidecar Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `sidecar.image.repository` | Sidecar Ferrite image repository | `ghcr.io/ferritelabs/ferrite` |
| `sidecar.image.tag` | Sidecar Ferrite image tag | `latest` |
| `sidecar.resources.requests.cpu` | Sidecar CPU request | `100m` |
| `sidecar.resources.requests.memory` | Sidecar memory request | `256Mi` |
| `sidecar.resources.limits.cpu` | Sidecar CPU limit | `500m` |
| `sidecar.resources.limits.memory` | Sidecar memory limit | `512Mi` |
| `sidecar.port` | Ferrite listen port in injected sidecar | `6379` |
| `sidecar.metricsPort` | Prometheus metrics port in injected sidecar | `9090` |

### Ferrite Cache Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ferrite.port` | Ferrite listen port (ConfigMap) | `6379` |
| `ferrite.maxMemory` | Maximum memory in bytes | `134217728` (128MB) |
| `ferrite.maxConnections` | Maximum connections | `128` |
| `ferrite.evictionPolicy` | Eviction policy | `allkeys-lru` |
| `ferrite.logLevel` | Log level | `warn` |
| `ferrite.databases` | Number of databases | `4` |

### General Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `image.repository` | Ferrite image repository (manual sidecar) | `ghcr.io/ferritelabs/ferrite` |
| `image.tag` | Ferrite image tag (manual sidecar) | Chart appVersion |
| `resources.limits.cpu` | CPU limit (manual sidecar) | `250m` |
| `resources.limits.memory` | Memory limit (manual sidecar) | `256Mi` |
| `resources.requests.cpu` | CPU request (manual sidecar) | `50m` |
| `resources.requests.memory` | Memory request (manual sidecar) | `64Mi` |
| `persistence.enabled` | Enable persistence | `false` |

## Per-Pod Overrides via Annotations

The injector supports per-pod overrides through annotations on the pod spec:

| Annotation | Description | Example |
|------------|-------------|---------|
| `ferrite.dev/inject` | Trigger sidecar injection | `"true"` |
| `ferrite.dev/sidecar-cpu-request` | Override CPU request | `"200m"` |
| `ferrite.dev/sidecar-cpu-limit` | Override CPU limit | `"1000m"` |
| `ferrite.dev/sidecar-memory-request` | Override memory request | `"512Mi"` |
| `ferrite.dev/sidecar-memory-limit` | Override memory limit | `"1Gi"` |
| `ferrite.dev/sidecar-port` | Override Ferrite listen port | `"6380"` |

Example with overrides:

```yaml
metadata:
  annotations:
    ferrite.dev/inject: "true"
    ferrite.dev/sidecar-memory-limit: "1Gi"
    ferrite.dev/sidecar-cpu-limit: "1000m"
```

## Architecture

```
+---------------------------------------------+
|          Kubernetes API Server               |
|  +---------------------------------------+   |
|  | MutatingWebhookConfiguration          |   |
|  |  (intercepts Pod CREATE requests)     |   |
|  +------------------+--------------------+   |
|                     |                        |
|                     v                        |
|  +---------------------------------------+   |
|  | Ferrite Sidecar Injector (Deployment) |   |
|  |  - Validates namespace labels         |   |
|  |  - Checks pod annotations             |   |
|  |  - Generates JSON patch               |   |
|  |  - Injects sidecar container + volume |   |
|  +---------------------------------------+   |
|                     |                        |
|        Pod with injected sidecar:            |
|  +---------------------------------------+   |
|  | +-------------+  +-----------------+  |   |
|  | | App         |  | Ferrite Sidecar |  |   |
|  | | Container   |--| Container       |  |   |
|  | +-------------+  +-----------------+  |   |
|  |   localhost:6379                      |   |
|  +---------------------------------------+   |
+---------------------------------------------+
```

## Troubleshooting

### Sidecar not being injected

1. **Check namespace labels:**
   ```bash
   kubectl get namespace my-app --show-labels
   # Ensure ferrite.dev/inject=enabled is present
   ```

2. **Check pod annotations:**
   ```bash
   kubectl get pod <pod-name> -o jsonpath='{.metadata.annotations}'
   # Ensure ferrite.dev/inject: "true" is present
   ```

3. **Verify the webhook is registered:**
   ```bash
   kubectl get mutatingwebhookconfigurations
   # Should list the ferrite-sidecar-webhook entry
   ```

4. **Check the injector logs:**
   ```bash
   kubectl logs -n <chart-namespace> -l app.kubernetes.io/component=webhook
   ```

### Webhook server not starting

1. **Check the TLS secret exists:**
   ```bash
   kubectl get secret -n <chart-namespace> <release>-ferrite-sidecar-webhook-tls
   ```

2. **Check cert generation job status:**
   ```bash
   kubectl get jobs -n <chart-namespace>
   kubectl logs -n <chart-namespace> job/<release>-ferrite-sidecar-webhook-cert-gen
   ```

3. **Verify RBAC permissions:**
   ```bash
   kubectl auth can-i get secrets \
     --as=system:serviceaccount:<namespace>:<release>-ferrite-sidecar-webhook \
     -n <namespace>
   ```

### Pods failing to start after injection

1. **Check the injected sidecar container:**
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   # Look for the ferrite-sidecar container in the Events section
   ```

2. **Check Ferrite sidecar logs:**
   ```bash
   kubectl logs <pod-name> -c ferrite-sidecar -n <namespace>
   ```

3. **Verify the ConfigMap exists:**
   ```bash
   kubectl get configmap -n <chart-namespace> | grep ferrite
   ```

### cert-manager certificate not ready

1. **Check Certificate status:**
   ```bash
   kubectl get certificate -n <chart-namespace>
   kubectl describe certificate <release>-ferrite-sidecar-webhook -n <chart-namespace>
   ```

2. **Check the Issuer/ClusterIssuer:**
   ```bash
   kubectl get clusterissuer
   kubectl describe clusterissuer <issuer-name>
   ```

## Migration from v0.1.x

The v0.2.0 chart replaces the legacy `injector.enabled` configuration with the new `webhook.*` configuration tree. To migrate:

1. Replace `injector.enabled=true` with `webhook.enabled=true`
2. Move `injector.namespaceSelector` to `webhook.namespaceSelector`
3. Move `injector.failurePolicy` to `webhook.failurePolicy`
4. The namespace label changed from `ferrite-sidecar-injection: enabled` to `ferrite.dev/inject: enabled`
5. The pod annotation changed from `ferrite.dev/inject-sidecar: "true"` to `ferrite.dev/inject: "true"`

Update namespace labels:
```bash
kubectl label namespace my-app ferrite-sidecar-injection-
kubectl label namespace my-app ferrite.dev/inject=enabled
```

## Use Cases

- **Session cache** -- Store user sessions locally for stateless app replicas
- **Rate limiting** -- Per-pod rate limit counters with no shared state
- **Feature flags** -- Cache feature flag evaluations at the pod level
- **Request deduplication** -- Track recent request IDs locally
- **Computed value cache** -- Cache expensive computation results

## Documentation

See the full documentation at [ferrite.dev/docs/deployment/kubernetes-sidecar](https://ferrite.dev/docs/deployment/kubernetes-sidecar).
