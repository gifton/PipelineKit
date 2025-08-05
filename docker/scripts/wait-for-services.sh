#!/bin/bash
# wait-for-services.sh - Wait for Docker services to be ready

set -e

# Colors for output (disabled if not interactive)
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
else
    GREEN=''
    RED=''
    YELLOW=''
    NC=''
fi

# Configuration
MAX_WAIT_TIME="${WAIT_TIMEOUT:-30}"
SLEEP_INTERVAL=1
HOST="${DOCKER_HOST:-localhost}"

# Check dependencies
check_dependencies() {
    local missing=()
    
    # Check for required commands
    for cmd in curl docker docker-compose; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}Error: Missing required commands: ${missing[*]}${NC}" >&2
        echo "Please install the missing dependencies and try again." >&2
        exit 1
    fi
}

# Run dependency check
check_dependencies

echo "Waiting for services to be ready..."

# Function to check if a TCP port is open using curl
check_port() {
    local host=$1
    local port=$2
    # Use curl with telnet protocol to check TCP port
    curl -s telnet://"$host":"$port" --connect-timeout 1 >/dev/null 2>&1
}

# Function to check HTTP endpoint
check_http() {
    local url=$1
    curl -s -f -o /dev/null "$url" 2>/dev/null
}

# Wait for OpenTelemetry Collector
echo -n "Waiting for OpenTelemetry Collector..."
elapsed=0
while ! check_port "$HOST" 4317 || ! check_http "http://$HOST:13133/"; do
    if [ $elapsed -ge $MAX_WAIT_TIME ]; then
        echo -e " ${RED}TIMEOUT${NC}"
        echo "OpenTelemetry Collector did not start within $MAX_WAIT_TIME seconds"
        exit 1
    fi
    echo -n "."
    sleep $SLEEP_INTERVAL
    elapsed=$((elapsed + SLEEP_INTERVAL))
done
echo -e " ${GREEN}OK${NC}"

# Wait for StatsD
echo -n "Waiting for StatsD..."
elapsed=0
while ! check_port "$HOST" 8125; do
    if [ $elapsed -ge $MAX_WAIT_TIME ]; then
        echo -e " ${RED}TIMEOUT${NC}"
        echo "StatsD did not start within $MAX_WAIT_TIME seconds"
        exit 1
    fi
    echo -n "."
    sleep $SLEEP_INTERVAL
    elapsed=$((elapsed + SLEEP_INTERVAL))
done
echo -e " ${GREEN}OK${NC}"

# Final health check
echo -e "\n${GREEN}All services are ready!${NC}"
echo ""
echo "Service endpoints:"
echo "  - OpenTelemetry Collector (OTLP gRPC): $HOST:4317"
echo "  - OpenTelemetry Collector (Health):    http://$HOST:13133/"
echo "  - OpenTelemetry Collector (Metrics):   http://$HOST:8888/metrics"
echo "  - StatsD (UDP):                       $HOST:8125"
echo ""