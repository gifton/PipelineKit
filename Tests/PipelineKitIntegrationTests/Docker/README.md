# PipelineKit Docker Integration Tests

This directory contains integration tests that require Docker services.

## Test Suites

### OpenTelemetryIntegrationTests
Tests the OpenTelemetry exporter against a real OpenTelemetry Collector instance.

**Coverage:**
- Basic connectivity and health checks
- Single metric export
- Batch metric export  
- Large payload handling
- Different metric types (gauge, counter, histogram/timer)

### StatsDIntegrationTests
Tests the StatsD exporter against a real StatsD server instance.

**Coverage:**
- Server connectivity verification
- Single metric export with real-time mode
- Batch export with buffering
- Different metric types and formats
- Global tags and metric-specific tags
- High volume metrics with sampling
- Connection recovery testing
- Aggregated metrics export

## Prerequisites

1. Docker and Docker Compose installed
2. Ports available: 4317 (OTLP), 8125 (StatsD UDP), 8126 (StatsD TCP), 8888 (Metrics)

## Running Tests

### Local Development

1. Start Docker services:
   ```bash
   cd docker/
   make up
   ```

2. Run specific test suite:
   ```bash
   swift test --filter "OpenTelemetryIntegrationTests"
   swift test --filter "StatsDIntegrationTests"
   ```

3. Run all integration tests:
   ```bash
   ./run-integration-tests.sh
   ```

4. Stop services:
   ```bash
   cd docker/
   make down
   ```

### Auto-start Services
Tests will automatically start Docker services if not running:
```bash
swift test --filter "IntegrationTests"
```

## Test Structure

- `DockerTestHelper.swift` - Singleton helper for Docker service management
- `OpenTelemetryIntegrationTests.swift` - OTLP exporter tests
- `StatsDIntegrationTests.swift` - StatsD exporter tests

## Test Helpers

### DockerTestHelper
Manages Docker service lifecycle:
- `ensureServicesRunning()` - Starts services if needed
- `waitForService(port:)` - Waits for service readiness
- `queryOTelMetrics()` - Queries collector metrics
- `stopServices()` - Stops all services

## Environment Variables

- `STOP_DOCKER_AFTER_TESTS=true` - Stop services after test completion
- `CI=true` - Indicates CI environment for adjusted timeouts

## Debugging

View service logs:
```bash
cd docker/
make logs                    # All services
make logs-otel-collector    # OpenTelemetry only
make logs-statsd           # StatsD only
```

Check service status:
```bash
cd docker/
make status
```

## CI Integration

Tests run automatically in GitHub Actions using either:
- GitHub Services (recommended for CI)
- Docker Compose (for consistency with local)

The `integration-tests.yml` workflow runs tests in two jobs:
1. Using GitHub Services
2. Using Docker Compose

## Troubleshooting

1. **Services not starting:** 
   - Check Docker daemon: `docker ps`
   - Check disk space: `docker system df`

2. **Port conflicts:**
   - Find conflicting process: `lsof -i :8125`
   - Stop conflicting services

3. **Timeout errors:**
   - Increase timeouts in test setUp
   - Check service health: `make health-check`

4. **Network errors:**
   - Check Docker network: `docker network ls`
   - Restart Docker daemon if needed