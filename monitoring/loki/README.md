# Loki Log Aggregation for Ferrite

Log aggregation stack using [Grafana Loki](https://grafana.com/oss/loki/) and [Promtail](https://grafana.com/docs/loki/latest/send-data/promtail/).

## Overview

This setup collects Ferrite server logs, parses structured JSON output, and makes them searchable in Grafana alongside your existing metrics dashboards.

## Quick Start

### Docker Compose

Add the logging profile to your existing monitoring stack:

```bash
# Start the full observability stack (metrics + logs)
docker compose -f ../docker-compose.yml --profile monitoring --profile logging up -d
```

### Standalone

```bash
docker compose -f docker-compose-loki.yaml up -d
```

## Components

| Component | Port | Purpose |
|-----------|------|---------|
| Loki | 3100 | Log storage and query engine |
| Promtail | 9080 | Log collector (reads Docker/journal logs) |
| Grafana | 3000 | Visualization (Loki auto-configured as datasource) |

## Configuration

### Loki (`loki-config.yaml`)

Default configuration stores logs locally with 7-day retention. For production, consider using S3/GCS backend storage.

### Promtail (`promtail-config.yaml`)

Promtail is configured to:
- Collect Docker container logs from Ferrite containers
- Parse JSON-formatted log lines (Ferrite's default with `format = "json"`)
- Extract labels: `level`, `target` (Rust module), `span`
- Add static labels: `job=ferrite`, `environment`

### Grafana Datasource

The Loki datasource is auto-provisioned in Grafana when using the Docker Compose setup.

## Useful LogQL Queries

```logql
# All Ferrite error logs
{job="ferrite"} |= "ERROR"

# Slow command warnings
{job="ferrite"} | json | level="WARN" | message=~".*slow.*"

# Connection events
{job="ferrite"} | json | target="ferrite::server" | message=~".*connect.*"

# Replication events
{job="ferrite"} | json | target=~"ferrite::replication.*"

# Logs from last hour with rate
rate({job="ferrite"} | json | level="ERROR" [1h])
```

## Ferrite Log Configuration

Ensure Ferrite is configured to output JSON logs:

```toml
[logging]
level = "info"
format = "json"    # Required for structured log parsing
```

## Production Considerations

- **Retention**: Default 7 days. Adjust `retention_period` in `loki-config.yaml`
- **Storage**: For production, configure S3/GCS backend instead of local filesystem
- **Resources**: Loki needs ~256MB RAM for small deployments, scale with log volume
- **Indexing**: Label cardinality is key — avoid high-cardinality labels like request IDs
