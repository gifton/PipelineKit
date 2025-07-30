# PipelineKit Observability Export System

The Export System provides flexible, multi-format metrics export capabilities for PipelineKit applications.

## Overview

The export system is designed to be:
- **Format-agnostic**: Easy to add new export formats
- **Thread-safe**: All exporters use actor-based concurrency
- **Resilient**: Circuit breakers and error isolation
- **Performant**: Buffering and back-pressure handling

## Architecture

```
Observability/Export/
├── MetricExporter.swift      # Core protocol
├── ExportManager.swift       # Coordinator actor
├── ExportConfiguration.swift # Configuration types
└── Exporters/
    ├── JSONExporter.swift    # JSON format export
    ├── CSVExporter.swift     # CSV format export
    └── PrometheusExporter.swift # Prometheus exposition
```

## Usage

### Basic Example

```swift
import PipelineKit

// Create exporters
let jsonExporter = try await JSONExporter(configuration: .init(
    fileConfig: .init(path: "/tmp/metrics.json")
))

let csvExporter = try await CSVExporter(configuration: .init(
    fileConfig: .init(path: "/tmp/metrics.csv")
))

// Create export manager
let exportManager = ExportManager()
await exportManager.register(jsonExporter, name: "json")
await exportManager.register(csvExporter, name: "csv")

// Export metrics
let metric = MetricDataPoint(
    name: "cpu.usage",
    value: 75.5,
    type: .gauge,
    tags: ["host": "server-01"]
)
await exportManager.export(metric)
```

### Integration with MetricCollector

```swift
// From stress testing or other modules
let collector = MetricCollector()
await collector.addExporter(jsonExporter, name: "json")

// Metrics are automatically exported as they're collected
await collector.record(.gauge("memory.used", value: 1024))
```

## Export Formats

### JSON Export
- Human-readable format
- Configurable pretty printing
- File rotation support
- Streaming writes for efficiency

### CSV Export  
- Tabular format for analysis
- Dynamic header generation
- Proper escaping and quoting
- Tag expansion to columns

### Prometheus Export
- Standard exposition format
- HTTP scraping endpoint
- Metric type mapping
- Label support

## Configuration

Each exporter has its own configuration type:

```swift
// JSON Configuration
JSONExportConfiguration(
    fileConfig: FileExportConfiguration(
        path: "/var/log/metrics.json",
        maxFileSize: 100_000_000,  // 100MB
        maxFiles: 5,
        flushInterval: 10.0
    ),
    prettyPrint: true,
    dateFormat: .iso8601
)

// Prometheus Configuration
PrometheusExportConfiguration(
    port: 9090,
    metricsPath: "/metrics",
    globalLabels: ["service": "my-app"]
)
```

## Error Handling

The export system uses a custom `ExportError` enum:

```swift
public enum ExportError: LocalizedError {
    case notConfigured
    case invalidConfiguration(String)
    case ioError(Error)
    case networkError(Error)
    case serializationError(Error)
    case destinationUnavailable(String)
    case shutdownInProgress
}
```

## Circuit Breaker

The ExportManager implements a circuit breaker pattern:
- Tracks consecutive failures per exporter
- Opens circuit after threshold (default: 5 failures)
- Waits before retry (default: 60 seconds)
- Half-open state for testing recovery

## Future Enhancements

See TODO.md for planned improvements including:
- Memory-efficient streaming
- Additional export formats (OpenTelemetry, StatsD)
- Remote destinations (S3, CloudWatch)
- Enhanced reliability features