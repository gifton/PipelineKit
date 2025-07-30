# MetricRecordable Protocol Migration Guide

This guide explains how to migrate existing simulators to use the new `MetricRecordable` protocol.

## Quick Reference

### Old Pattern → New Pattern

```swift
// Pattern lifecycle
await recordMetric(.gauge("memory.pressure.pattern", value: 1.0, tags: ["pattern": "gradual"]))
→ await recordPatternStart(.patternStart, tags: ["pattern": "gradual"])

await recordMetric(.counter("memory.pressure.pattern.completed", value: 1.0, tags: ["pattern": "gradual"]))
→ await recordPatternCompletion(.patternComplete, duration: elapsed, tags: ["pattern": "gradual"])

await recordMetric(.counter("memory.pressure.pattern.failed", value: 1.0, tags: ["error": error.localizedDescription]))
→ await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "gradual"])

// Resource metrics
await recordMetric(.gauge("memory.usage.percentage", value: percent * 100))
→ await recordUsageLevel(.usagePercentage, percentage: percent)

// Safety metrics
await recordMetric(.counter("cpu.load.throttle", value: 1.0, tags: ["reason": "safety_limit"]))
→ await recordThrottle(.throttleEvent, reason: "safety_limit")

// Performance metrics
await recordMetric(.histogram("memory.allocation.latency", value: duration * 1000))
→ await recordLatency(.allocationLatency, seconds: duration)

// Generic metrics (use record directly)
await recordMetric(.gauge("memory.buffers.active", value: Double(count)))
→ await recordGauge(.bufferCount, value: Double(count))
```

## Migration Steps

### 1. Add Protocol Conformance

```swift
public actor MemoryPressureSimulator: MetricRecordable {
    // Add these lines
    public typealias Namespace = MemoryMetric
    public let namespace = "memory"
    
    // Existing properties...
}
```

### 2. Remove Old recordMetric Function

Delete the private `recordMetric` helper:
```swift
// DELETE THIS:
private func recordMetric(_ dataPoint: MetricDataPoint) async {
    await metricCollector?.record(dataPoint)
}
```

### 3. Update Metric Calls

Replace all `recordMetric` calls with appropriate protocol methods:

#### Pattern Lifecycle
```swift
// Start
await recordPatternStart(.patternStart, tags: ["pattern": "burst"])

// Complete
await recordPatternCompletion(.patternComplete, 
    duration: elapsed, 
    tags: ["pattern": "burst"])

// Fail
await recordPatternFailure(.patternFail, 
    error: error, 
    tags: ["pattern": "burst"])
```

#### Resource Metrics
```swift
// Usage levels (0-100%)
await recordUsageLevel(.usagePercentage, percentage: 0.75)

// Throttling
await recordThrottle(.throttleEvent, reason: "temperature_limit")

// Safety rejections
await recordSafetyRejection(.safetyRejection, 
    reason: "Memory limit exceeded",
    requested: "500MB")
```

#### Performance Metrics
```swift
// Latencies (automatically converted to milliseconds)
await recordLatency(.allocationLatency, seconds: duration)

// Throughput
await recordThroughput(.operationsPerSecond, operationsPerSecond: ops)
```

#### Generic Metrics
```swift
// Gauges
await recordGauge(.bufferCount, value: Double(buffers.count))

// Counters
await recordCounter(.allocationCount, value: 1.0)

// Histograms
await recordHistogram(.cycleDuration, value: durationMs)
```

## Complete Example

### Before
```swift
private func performAllocation(size: Int) async throws {
    let start = Date()
    
    await recordMetric(.gauge("memory.allocation.size", value: Double(size)))
    
    let buffer = try allocate(size)
    let duration = Date().timeIntervalSince(start)
    
    await recordMetric(.histogram("memory.allocation.latency", value: duration * 1000))
    await recordMetric(.counter("memory.allocation.count", value: 1.0))
}
```

### After
```swift
private func performAllocation(size: Int) async throws {
    let start = Date()
    
    await recordGauge(.allocationSize, value: Double(size))
    
    let buffer = try allocate(size)
    let duration = Date().timeIntervalSince(start)
    
    await recordLatency(.allocationLatency, seconds: duration)
    await recordCounter(.allocationCount)
}
```

## Benefits

1. **Type Safety**: Metric names are now enum cases, preventing typos
2. **Consistency**: All simulators use the same metric patterns
3. **Less Boilerplate**: Helper methods reduce repetitive code
4. **Better Documentation**: Each method clearly indicates its purpose
5. **Performance**: `@inlinable` methods with early-exit guards

## Notes

- The protocol maintains backward compatibility with optional `MetricCollector`
- All methods are no-ops when `metricCollector` is nil
- The namespace is automatically prefixed to all metric names
- Tags are merged intelligently (new protocol methods add standard tags)