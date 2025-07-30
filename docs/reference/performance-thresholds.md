# Performance Thresholds Guide

This guide explains how to configure and use performance thresholds in PipelineKit for optimal observability.

## Overview

PipelineKit provides centralized performance threshold configuration to help you:
- Detect slow middleware and command execution
- Monitor memory usage
- Adapt thresholds based on your environment
- Maintain consistent performance standards

## Default Thresholds

The default thresholds are optimized for typical production workloads:

```swift
PerformanceThresholds.default = PerformanceThresholds(
    slowCommandThreshold: 1.0,        // 1 second
    slowMiddlewareThreshold: 0.01,    // 10ms
    memoryUsageThreshold: 100         // 100MB
)
```

## Pre-configured Profiles

### Development
Relaxed thresholds for debugging and development:
```swift
PerformanceThresholds.development = PerformanceThresholds(
    slowCommandThreshold: 5.0,        // 5 seconds
    slowMiddlewareThreshold: 0.1,     // 100ms
    memoryUsageThreshold: 500         // 500MB
)
```

### Strict/High Performance
For high-performance environments requiring tight constraints:
```swift
PerformanceThresholds.strict = PerformanceThresholds(
    slowCommandThreshold: 0.1,        // 100ms
    slowMiddlewareThreshold: 0.001,   // 1ms
    memoryUsageThreshold: 50          // 50MB
)
```

### High Throughput
Optimized for high-throughput scenarios:
```swift
PerformanceThresholds.highThroughput = PerformanceThresholds(
    slowCommandThreshold: 0.05,       // 50ms
    slowMiddlewareThreshold: 0.005,   // 5ms
    memoryUsageThreshold: 20          // 20MB
)
```

## Configuration

### Global Configuration

Configure thresholds globally at application startup:

```swift
// In your app initialization
PerformanceConfiguration.configure(for: .production)

// Or use a specific profile
PerformanceConfiguration.configure(for: .highPerformance)

// Or provide custom thresholds
let customThresholds = PerformanceThresholds(
    slowCommandThreshold: 0.5,
    slowMiddlewareThreshold: 0.02,
    memoryUsageThreshold: 200
)
PerformanceConfiguration.configure(for: .custom(customThresholds))
```

### Per-Middleware Configuration

Override thresholds for specific middleware:

```swift
let performanceMiddleware = PerformanceTrackingMiddleware(
    thresholds: PerformanceThresholds(
        slowCommandThreshold: 0.1,
        slowMiddlewareThreshold: 0.005,
        memoryUsageThreshold: 50
    )
)
```

## Integration with Observers

The thresholds are automatically used by observers:

```swift
// Console observer with development thresholds
let devObserver = ConsoleObserver.development()

// Production observer with stricter thresholds
let prodObserver = ConsoleObserver.production()

// Custom observer
let customObserver = OSLogObserver(configuration: Configuration(
    performanceThreshold: PerformanceThresholds.strict.slowMiddlewareThreshold
))
```

## Monitoring and Alerts

When middleware or commands exceed thresholds:

1. **Console Observer**: Logs slow operations with timing information
2. **OSLog Observer**: Logs to system logs with appropriate severity
3. **Custom Events**: Emits events for monitoring systems

Example output:
```
⚡ AuthenticationMiddleware completed in 15.2ms [SLOW]
⚠️ ProcessOrderCommand exceeded threshold: 1.5s (threshold: 1.0s)
```

## Best Practices

1. **Start with Defaults**: Use the default thresholds initially
2. **Measure Baseline**: Profile your application to understand normal performance
3. **Adjust Gradually**: Make incremental adjustments based on real data
4. **Environment-Specific**: Use different thresholds for dev/staging/production
5. **Monitor Trends**: Track performance over time, not just individual spikes

## Example: Complete Setup

```swift
import PipelineKit

// Configure at app startup
@main
struct MyApp {
    static func main() async throws {
        // Set environment-based thresholds
        #if DEBUG
        PerformanceConfiguration.configure(for: .development)
        #else
        PerformanceConfiguration.configure(for: .production)
        #endif
        
        // Create pipeline with performance tracking
        let pipeline = try await PipelineBuilder(handler: handler)
            .with(PerformanceTrackingMiddleware())
            .with(ObservabilityMiddleware(
                observer: ConsoleObserver(style: .pretty)
            ))
            .build()
        
        // Run application
        await app.run()
    }
}
```

## Performance Impact

The threshold checking itself has minimal overhead:
- Simple time comparison: ~1ns
- No allocation or async operations
- Logging only occurs when thresholds are exceeded

## Migration from 0.1s Default

The previous hardcoded 0.1s threshold for slow middleware has been replaced with:
- **Default**: 0.01s (10ms) - more appropriate for middleware
- **Development**: 0.1s (100ms) - maintains backward compatibility
- **Custom**: Configure based on your specific needs

This change provides better granularity for high-performance applications while maintaining flexibility for different environments.