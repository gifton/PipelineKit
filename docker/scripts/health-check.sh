#!/bin/bash
# health-check.sh - Check health of all Docker services

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== PipelineKit Docker Services Health Check ==="
echo ""

# Check if docker-compose is running
if ! docker-compose ps 2>/dev/null | grep -q "Up"; then
    echo -e "${RED}ERROR:${NC} No services are running. Run 'make up' first."
    exit 1
fi

# Function to check service health
check_service() {
    local service_name=$1
    local check_command=$2
    local description=$3
    
    echo -n "Checking $service_name ($description)... "
    
    if eval "$check_command" >/dev/null 2>&1; then
        echo -e "${GREEN}HEALTHY${NC}"
        return 0
    else
        echo -e "${RED}UNHEALTHY${NC}"
        return 1
    fi
}

# Track overall health
all_healthy=true

# Check OpenTelemetry Collector
check_service "OpenTelemetry Collector" \
    "curl -s -f http://localhost:13133/" \
    "Health endpoint" || all_healthy=false

check_service "OpenTelemetry Collector" \
    "nc -z localhost 4317" \
    "OTLP gRPC port" || all_healthy=false

check_service "OpenTelemetry Collector" \
    "curl -s -f http://localhost:8888/metrics | grep -q otelcol" \
    "Metrics endpoint" || all_healthy=false

# Check StatsD
check_service "StatsD" \
    "nc -z -u localhost 8125" \
    "UDP port" || all_healthy=false

# Container status
echo ""
echo "=== Container Status ==="
docker-compose ps

# Show recent logs if any service is unhealthy
if [ "$all_healthy" = false ]; then
    echo ""
    echo -e "${YELLOW}=== Recent Logs (last 20 lines) ===${NC}"
    docker-compose logs --tail=20
    exit 1
else
    echo ""
    echo -e "${GREEN}All services are healthy!${NC}"
fi