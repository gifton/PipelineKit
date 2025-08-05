#!/bin/bash
# test-services.sh - Send test data to verify services are working

set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=== Testing PipelineKit Docker Services ==="
echo ""

# Test StatsD
echo -e "${BLUE}Testing StatsD...${NC}"
echo "Sending test metric: pipelinekit.test.counter:1|c"
echo "pipelinekit.test.counter:1|c" | nc -u -w1 localhost 8125
echo -e "${GREEN}✓ Sent test metric to StatsD${NC}"

echo ""
echo "To see if the services received the data:"
echo "  - StatsD: make logs-statsd"
echo "  - OpenTelemetry: make logs-otel-collector"
echo ""
echo "Note: OpenTelemetry test requires a gRPC client (will be added with integration tests)"