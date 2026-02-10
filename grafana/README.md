# Ferrite Grafana Dashboards

This directory contains pre-built Grafana dashboards for monitoring Ferrite.

## Available Dashboards

### ferrite-dashboard.json

A comprehensive dashboard for monitoring Ferrite instances with:

- **Overview Row**: Memory usage, operations/sec, connected clients, total keys, cache hit rate, P99 latency
- **Performance Row**: Operations rate by command, latency percentiles (P50, P95, P99, P99.9)
- **Memory & Storage Row**: Memory usage trends, HybridLog tier distribution
- **Connections & Network Row**: Client connections, network I/O, cache hit/miss rate
- **Persistence & Replication Row**: AOF size, connected replicas, replication lag

## Quick Start

### Import via Grafana UI

1. Open Grafana and go to **Dashboards** > **Import**
2. Click **Upload JSON file** and select `ferrite-dashboard.json`
3. Select your Prometheus datasource when prompted
4. Click **Import**

### Import via API

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d @ferrite-dashboard.json \
  http://localhost:3000/api/dashboards/import
```

### Using with Docker Compose

The dashboard is automatically provisioned when using the included `docker-compose.yml` with the monitoring profile:

```bash
docker-compose --profile monitoring up
```

Then access Grafana at http://localhost:3000 (default credentials: admin/admin).

## Prerequisites

### Prometheus Configuration

Ensure Prometheus is scraping Ferrite metrics. Add to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'ferrite'
    static_configs:
      - targets: ['ferrite:9090']
    scrape_interval: 5s
```

### Ferrite Configuration

Ensure metrics are enabled in your `ferrite.toml`:

```toml
[metrics]
enabled = true
port = 9090
path = "/metrics"
```

## Available Metrics

The dashboard uses these Ferrite Prometheus metrics:

| Metric | Type | Description |
|--------|------|-------------|
| `ferrite_memory_used_bytes` | Gauge | Current memory usage |
| `ferrite_memory_max_bytes` | Gauge | Maximum memory limit |
| `ferrite_commands_total` | Counter | Total commands processed |
| `ferrite_command_duration_seconds` | Histogram | Command latency |
| `ferrite_connected_clients` | Gauge | Number of connected clients |
| `ferrite_blocked_clients` | Gauge | Number of blocked clients |
| `ferrite_db_keys` | Gauge | Number of keys per database |
| `ferrite_keyspace_hits_total` | Counter | Cache hits |
| `ferrite_keyspace_misses_total` | Counter | Cache misses |
| `ferrite_net_input_bytes_total` | Counter | Network input bytes |
| `ferrite_net_output_bytes_total` | Counter | Network output bytes |
| `ferrite_hybridlog_mutable_bytes` | Gauge | Hot tier size |
| `ferrite_hybridlog_readonly_bytes` | Gauge | Warm tier size |
| `ferrite_hybridlog_disk_bytes` | Gauge | Cold tier size |
| `ferrite_aof_current_size_bytes` | Gauge | AOF file size |
| `ferrite_connected_replicas` | Gauge | Number of replicas |
| `ferrite_replication_lag` | Gauge | Replication offset lag |

## Customization

### Variables

The dashboard supports the following template variables when configured:

- `$instance` - Filter by Ferrite instance (for multi-instance setups)
- `$job` - Filter by Prometheus job name

### Alert Rules

Consider adding these Grafana alerts:

```yaml
# High Memory Usage
- alert: FerriteHighMemory
  expr: (ferrite_memory_used_bytes / ferrite_memory_max_bytes) > 0.9
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Ferrite memory usage above 90%"

# High Latency
- alert: FerriteHighLatency
  expr: histogram_quantile(0.99, rate(ferrite_command_duration_seconds_bucket[5m])) > 0.005
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Ferrite P99 latency above 5ms"

# Low Cache Hit Rate
- alert: FerriteLowHitRate
  expr: |
    (rate(ferrite_keyspace_hits_total[5m]) /
    (rate(ferrite_keyspace_hits_total[5m]) + rate(ferrite_keyspace_misses_total[5m]))) < 0.8
  for: 10m
  labels:
    severity: info
  annotations:
    summary: "Ferrite cache hit rate below 80%"
```

## Troubleshooting

### No Data Showing

1. Verify Ferrite metrics endpoint: `curl http://ferrite:9090/metrics`
2. Check Prometheus targets: Go to Prometheus UI > Status > Targets
3. Verify datasource configuration in Grafana

### Metrics Missing

Ensure your Ferrite version supports all metrics. Some metrics may only be available with specific features enabled (e.g., HybridLog metrics require the hybridlog storage backend).

## Contributing

To update the dashboard:

1. Make changes in Grafana UI
2. Export the dashboard JSON (Share > Export > Export for sharing externally)
3. Replace `ferrite-dashboard.json` with the exported file
4. Submit a pull request

## More Information

- [Ferrite Documentation](https://ferrite.dev/docs)
- [Monitoring Guide](https://ferrite.dev/docs/operations/monitoring)
- [Observability Guide](https://ferrite.dev/docs/operations/observability)
