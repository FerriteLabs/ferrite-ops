# 🔭 Ferrite Observability Starter Kit

Full monitoring stack for Ferrite in under 5 minutes.

## Quick Start

```bash
cd monitoring/
./setup.sh
```

Or with Docker Compose directly:

```bash
cd monitoring/
docker compose up -d
```

## What's Included

| Component | Port | Purpose |
|-----------|------|---------|
| **Prometheus** | [localhost:9091](http://localhost:9091) | Metrics collection and alerting |
| **Grafana** | [localhost:3000](http://localhost:3000) | Visualization dashboards |

Default Grafana credentials: `admin` / `ferrite`

### Pre-Configured Dashboards

- **Ferrite Overview** — connections, memory, ops/sec, hit rate, uptime
- **Ferrite Operations** — per-command latency histograms, throughput breakdown, error rates

### Alerting Rules

| Alert | Condition | Severity |
|-------|-----------|----------|
| FerriteDown | Instance unreachable for >1m | critical |
| HighMemoryUsage | Memory usage >90% of max | warning |
| HighLatency | P99 latency >10ms | warning |
| ReplicationLag | Replica lag >5s | warning |
| PersistenceError | AOF/RDB write failures | critical |
| HighConnectionCount | Connections >80% of max | warning |

## Configuration

Override defaults with environment variables:

```bash
GRAFANA_PORT=8080 PROMETHEUS_PORT=9092 docker compose up -d
```

| Variable | Default | Description |
|----------|---------|-------------|
| `GRAFANA_PORT` | 3000 | Grafana web UI port |
| `PROMETHEUS_PORT` | 9091 | Prometheus web UI port |
| `GRAFANA_ADMIN_USER` | admin | Grafana admin username |
| `GRAFANA_ADMIN_PASSWORD` | ferrite | Grafana admin password |

## Connecting to a Remote Ferrite Instance

Edit `prometheus.yml` and change the target:

```yaml
scrape_configs:
  - job_name: 'ferrite'
    static_configs:
      - targets: ['your-ferrite-host:9090']
```

Then reload Prometheus:

```bash
docker compose restart prometheus
```

## Teardown

```bash
docker compose down       # Stop containers
docker compose down -v    # Stop and delete all data
```
