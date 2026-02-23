#!/usr/bin/env bash
# Ferrite Observability Starter Kit — Quick Setup
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/ferritelabs/ferrite-ops/main/monitoring/setup.sh | bash
#
# Or locally:
#   ./setup.sh
#
# Environment variables:
#   FERRITE_HOST          Ferrite server host (default: host.docker.internal)
#   FERRITE_METRICS_PORT  Metrics port (default: 9090)
#   GRAFANA_PORT          Grafana port (default: 3000)
#   PROMETHEUS_PORT       Prometheus port (default: 9091)

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🔭 Ferrite Observability Starter Kit${NC}"
echo ""

# Check prerequisites
if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed. Install from https://docs.docker.com/get-docker/"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "Error: docker compose is not available. Install Docker Compose V2."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Starting Prometheus + Grafana..."
docker compose up -d

echo ""
echo -e "${GREEN}✅ Monitoring stack is running!${NC}"
echo ""
echo -e "  Grafana:    ${YELLOW}http://localhost:${GRAFANA_PORT:-3000}${NC}  (admin / ferrite)"
echo -e "  Prometheus: ${YELLOW}http://localhost:${PROMETHEUS_PORT:-9091}${NC}"
echo ""
echo "Pre-configured dashboards:"
echo "  • Ferrite Overview — key metrics at a glance"
echo "  • Ferrite Operations — detailed command and latency breakdown"
echo ""
echo "To stop:  docker compose -f $SCRIPT_DIR/docker-compose.yml down"
echo "To reset: docker compose -f $SCRIPT_DIR/docker-compose.yml down -v"
