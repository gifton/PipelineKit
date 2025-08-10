#!/usr/bin/env swift

import Foundation
import PipelineKitMetrics

// Type-Safe Metrics Example
// Demonstrates the compile-time safety and ergonomics of the new metric system

@main
struct TypeSafeMetricsExample {
    static func main() async throws {
        print("Type-Safe Metrics Example")
        print(String(repeating: "=", count: 50))
        
        // MARK: - Basic Usage
        
        print("\n1. Creating Type-Safe Metrics")
        print("-" * 30)
        
        // Counter - only increases
        let requestCounter = Metric<Counter>.counter(
            "api.requests",
            tags: ["endpoint": "/users", "method": "GET"]
        )
        print("Counter: \(requestCounter.name.value) = \(requestCounter.value.value)")
        
        // Gauge - can go up or down
        let memoryGauge = Metric<Gauge>.gauge(
            "memory.usage",
            value: 75.5,
            unit: .percentage,
            tags: ["host": "server1"]
        )
        print("Gauge: \(memoryGauge.name.value) = \(memoryGauge.value.value)%")
        
        // Histogram - for distributions
        let latencyHistogram = Metric<Histogram>.histogram(
            "request.latency",
            value: 125.5,
            unit: .milliseconds,
            tags: ["service": "api"]
        )
        print("Histogram: \(latencyHistogram.name.value) = \(latencyHistogram.value.value)ms")
        
        // Timer - specialized for durations
        let queryTimer = Metric<Timer>.timer(
            "db.query.time",
            duration: 45.2,
            unit: .milliseconds,
            tags: ["query": "SELECT * FROM users"]
        )
        print("Timer: \(queryTimer.name.value) = \(queryTimer.value.value)ms")
        
        // MARK: - Type-Specific Operations
        
        print("\n2. Type-Specific Operations (Compile-Time Safe)")
        print("-" * 30)
        
        // Counter operations
        let incremented = requestCounter.increment(by: 5)
        print("Counter after increment: \(incremented.value.value)")
        
        let counter2 = Metric<Counter>.counter("api.requests", value: 10)
        let summed = incremented + counter2
        print("Sum of counters: \(summed.value.value)")
        
        // Gauge operations
        let adjusted = memoryGauge.adjust(by: -10)
        print("Gauge after adjustment: \(adjusted.value.value)%")
        
        let clamped = memoryGauge.clamped(min: 0, max: 100)
        print("Clamped gauge: \(clamped.value.value)%")
        
        // These would NOT compile (type safety!):
        // requestCounter.adjust(by: 10)  // ❌ Counters can't adjust
        // memoryGauge.increment()         // ❌ Gauges can't increment
        
        // MARK: - Timing Operations
        
        print("\n3. Timing Operations")
        print("-" * 30)
        
        // Time a closure
        let (timedMetric, result) = Metric<Timer>.time("expensive.operation") {
            // Simulate expensive operation
            Thread.sleep(forTimeInterval: 0.1)
            return "Operation completed"
        }
        print("Operation took: \(timedMetric.value.value)ms")
        print("Result: \(result)")
        
        // Create timer from dates
        let startTime = Date()
        // ... do work ...
        Thread.sleep(forTimeInterval: 0.05)
        let endTime = Date()
        
        let duration = Metric<Timer>.duration(
            "work.duration",
            from: startTime,
            to: endTime,
            unit: .milliseconds
        )
        print("Work duration: \(duration.value.value)ms")
        
        // MARK: - Semantic Types
        
        print("\n4. Semantic Types Prevent Confusion")
        print("-" * 30)
        
        // MetricName with namespace
        let metricName = MetricName("requests", namespace: "api.v2")
        print("Fully qualified name: \(metricName.fullyQualified)")
        
        // MetricValue with units
        let temperature = MetricValue(22.5, unit: .celsius)
        if let fahrenheit = temperature.unit?.convert(temperature.value, to: .fahrenheit) {
            print("Temperature: \(temperature.value)°C = \(fahrenheit)°F")
        }
        
        // Automatic sanitization
        let dirtyName = MetricName("my metric/name-test")
        print("Sanitized name: \(dirtyName.value)")
        
        // MARK: - Collections and Aggregations
        
        print("\n5. Collection Operations")
        print("-" * 30)
        
        let counters = [
            Metric<Counter>.counter("errors", value: 5),
            Metric<Counter>.counter("errors", value: 3),
            Metric<Counter>.counter("errors", value: 7)
        ]
        
        if let totalErrors = counters.sum() {
            print("Total errors: \(totalErrors.value.value)")
        }
        
        let temperatures = [
            Metric<Gauge>.gauge("temp", value: 20.5),
            Metric<Gauge>.gauge("temp", value: 21.0),
            Metric<Gauge>.gauge("temp", value: 22.5),
            Metric<Gauge>.gauge("temp", value: 19.5)
        ]
        
        if let avgTemp = temperatures.average() {
            print("Average temperature: \(avgTemp.value.value)°")
        }
        if let minTemp = temperatures.minimum() {
            print("Min temperature: \(minTemp.value.value)°")
        }
        if let maxTemp = temperatures.maximum() {
            print("Max temperature: \(maxTemp.value.value)°")
        }
        
        // MARK: - Integration with Exporters
        
        print("\n6. Integration with Existing System")
        print("-" * 30)
        
        // Convert to MetricSnapshot for exporters
        let snapshot = MetricSnapshot(from: requestCounter)
        print("Snapshot: \(snapshot.name) (\(snapshot.type)) = \(snapshot.value)")
        
        // Use with existing exporters
        let exporter = StatsDExporter()
        let adapter = MetricExporterAdapter(exporter: exporter)
        
        // Record type-safe metrics
        await adapter.record(requestCounter)
        await adapter.record(memoryGauge)
        await adapter.record(latencyHistogram)
        
        // Batch recording
        await adapter.recordBatch(counters)
        
        // Flush to exporter
        try await adapter.flush()
        print("Metrics exported successfully")
        
        // MARK: - Advanced Patterns
        
        print("\n7. Advanced Patterns")
        print("-" * 30)
        
        // Rate calculation from counter
        let rateGauge = requestCounter.rate(over: 60, unit: .perMinute)
        print("Request rate: \(rateGauge.value.value) req/min")
        
        // Tag filtering
        let taggedMetric = requestCounter
            .with(tags: ["status": "200"])
            .with(tags: ["region": "us-west"])
        
        if taggedMetric.hasAllTags(["status": "200", "method": "GET"]) {
            print("Metric has required tags")
        }
        
        // Unit conversion
        let bytesGauge = Metric<Gauge>.gauge("data.size", value: 1024, unit: .kilobytes)
        if let megabytes = bytesGauge.value.unit?.convert(
            bytesGauge.value.value, 
            to: .megabytes
        ) {
            print("Data size: \(bytesGauge.value.value) KB = \(megabytes) MB")
        }
        
        // MARK: - Benefits Summary
        
        print("\n8. Benefits of Type-Safe Metrics")
        print("-" * 30)
        print("✓ Compile-time safety - impossible to misuse")
        print("✓ No runtime type checks needed")
        print("✓ Clear, self-documenting API")
        print("✓ Zero runtime overhead (phantom types)")
        print("✓ Seamless integration with existing exporters")
        print("✓ Rich type-specific operations")
        print("✓ Semantic types prevent confusion")
        
        await exporter.shutdown()
    }
}

// Helper extension
extension String {
    static func *(lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}