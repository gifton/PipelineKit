import Foundation

/// Example showing how to use the MetricRecordable protocol in simulators.
///
/// This example demonstrates the migration from direct recordMetric calls
/// to using the protocol's typed helper methods.
public struct MetricRecordableExample {
    
    /// Shows various metric recording patterns using the protocol.
    static func demonstrateUsage() async {
        
        // Assuming we have a simulator that conforms to MetricRecordable
        // with MemoryMetric as its namespace type
        
        // OLD WAY (direct MetricDataPoint):
        // await recordMetric(.gauge("memory.usage.percentage", value: 75.0))
        
        // NEW WAY (using protocol helpers):
        // await recordGauge(.usagePercentage, value: 75.0)
        
        // Pattern lifecycle examples:
        
        // Starting a pattern
        // await recordPatternStart(.patternStart, tags: ["pattern": "burst"])
        
        // Completing with duration
        // await recordPatternCompletion(.patternComplete, 
        //     duration: 5.3, 
        //     tags: ["pattern": "burst"])
        
        // Recording failure
        // await recordPatternFailure(.patternFail, 
        //     error: SimulatorError.limitExceeded, 
        //     tags: ["pattern": "burst"])
        
        // Resource metrics:
        
        // Usage level (automatically converts to percentage)
        // await recordUsageLevel(.usagePercentage, percentage: 0.75)
        
        // Throttling event
        // await recordThrottle(.throttleEvent, reason: "temperature_limit")
        
        // Safety rejection
        // await recordSafetyRejection(.safetyRejection,
        //     reason: "Memory limit exceeded",
        //     requested: "500MB")
        
        // Performance metrics:
        
        // Latency (automatically converts to milliseconds)
        // await recordLatency(.allocationLatency, seconds: 0.0053)
        
        // Throughput
        // await recordThroughput(.operationsPerSecond, operationsPerSecond: 1250.5)
        
        // Generic metrics with specific types:
        
        // Gauge for current values
        // await recordGauge(.bufferCount, value: 42.0)
        
        // Counter for accumulating values
        // await recordCounter(.allocationCount, value: 1.0)
        
        // Histogram for distributions
        // await recordHistogram(.allocationSize, value: 1024.0)
        
        // Direct record for custom needs
        // await record(.customMetric, 
        //     value: 123.45, 
        //     type: .gauge,
        //     tags: ["custom": "value"])
    }
    
    /// Example of batch recording for performance
    static func demonstrateBatchRecording() async {
        // When you need to record multiple metrics at once:
        
        // await recordBatch([
        //     (.allocationCount, 1.0, ["size": "large"]),
        //     (.usageBytes, 1048576.0, [:]),
        //     (.bufferCount, 15.0, [:])
        // ])
    }
    
    /// Shows how metric types map to aggregation
    static func metricTypeMapping() {
        // Gauge (.gauge) - Point-in-time values
        // - Used for: current usage, active connections, temperature
        // - Aggregations: min, max, mean, last value
        
        // Counter (.counter) - Monotonically increasing
        // - Used for: total requests, bytes allocated, errors
        // - Aggregations: sum, rate per second
        
        // Histogram (.histogram) - Distribution of values
        // - Used for: latencies, request sizes, queue depths
        // - Aggregations: percentiles (p50, p95, p99), mean
        
        // The protocol automatically selects appropriate types:
        // - recordGauge() → .gauge
        // - recordCounter() → .counter  
        // - recordHistogram() → .histogram
        // - recordLatency() → .histogram
        // - recordPatternCompletion(duration:) → .histogram
        // - recordPatternCompletion() → .counter
    }
}