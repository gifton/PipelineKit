# PipelineKit Docker Test Infrastructure

This directory contains Docker configurations for integration testing PipelineKit's exporters.

## Services

1. **OpenTelemetry Collector** (v0.96.0) - Receives OTLP data on port 4317
2. **StatsD Server** (Alpine-based) - Receives StatsD metrics on UDP port 8125

## Quick Start

```bash
# Start all services
make up

# Check health
make health

# View logs
make logs

# Stop services
make down
```

## CI Usage

For CI environments, use the CI-specific commands:
```bash
# Start with CI overrides
make ci-up

# Run tests
make ci-test

# Cleanup
make ci-down
```

## Ports

- `4317` - OpenTelemetry Collector (OTLP gRPC)
- `8125/udp` - StatsD
- `8888` - OpenTelemetry Collector metrics (Prometheus format)
- `13133` - OpenTelemetry Collector health check

## Resource Limits

Services are configured with resource limits to prevent runaway consumption:
- OpenTelemetry Collector: 512MB RAM, 0.5 CPU
- StatsD: 256MB RAM, 0.25 CPU

## Testing

The services use the `debug` exporter which prints all received data to stdout. This makes it easy to verify that metrics are being received without needing persistent storage.

To see what data is being received:
```bash
make logs-otel-collector  # See OTLP data
make logs-statsd         # See StatsD data
```

## Troubleshooting

### Services won't start
1. Check if ports are already in use: `lsof -i :4317`
2. Ensure Docker is running: `docker ps`
3. Check logs: `make logs`

### Connection refused errors
1. Wait for services to be ready: `./scripts/wait-for-services.sh`
2. Check if running in CI: services may use host networking
3. Verify firewall settings

### Out of memory errors
Increase Docker's memory allocation in Docker Desktop preferences.

## Environment Variables

- `DOCKER_HOST` - Override localhost for remote Docker hosts
- `WAIT_TIMEOUT` - Change service startup timeout (default: 30s)
- `CI` - Set to true in CI environments
- `STOP_DOCKER_AFTER_TESTS` - Set to true to stop services after tests