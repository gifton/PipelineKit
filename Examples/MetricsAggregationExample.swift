import Foundation
import PipelineKitObservability

/// Demonstrates metric aggregation to reduce network traffic.
@main
struct MetricsAggregationExample {
    static func main() async {
        print("=== Metric Aggregation Example ===\n")
        
        // MARK: - Without Aggregation (Default)
        
        print("1. WITHOUT AGGREGATION:")
        print("-----------------------")
        
        let basicExporter = StatsDExporter()
        
        // Each call sends immediately
        await basicExporter.counter("api.requests")
        await basicExporter.counter("api.requests")
        await basicExporter.counter("api.requests")
        
        print("  • Sent 3 separate packets for counter increments")
        print("  • Network packets: 3")
        print("  • Good for: Low-volume metrics, real-time updates\n")
        
        // MARK: - With Aggregation
        
        print("2. WITH AGGREGATION:")
        print("--------------------")
        
        let aggregatedConfig = StatsDExporter.Configuration(
            aggregation: AggregationConfiguration(
                enabled: true,
                flushInterval: 10.0,  // Flush every 10 seconds
                maxUniqueMetrics: 1000,
                maxTotalValues: 10000,
                flushJitter: 0.1  // ±10% jitter
            )
        )
        
        let aggregatedExporter = StatsDExporter(configuration: aggregatedConfig)
        
        // Simulate high-frequency metrics
        print("  Sending 1000 counter increments...")
        for _ in 0..<1000 {
            await aggregatedExporter.counter("api.requests")
        }
        
        print("  • Metrics aggregated locally")
        print("  • Will send as single value: api.requests:1000|c")
        print("  • Network packets: 1 (after flush)")
        print("  • Reduction: 1000x\n")
        
        // MARK: - Different Metric Types
        
        print("3. AGGREGATION BY TYPE:")
        print("------------------------")
        
        // Counters: Sum all increments
        await aggregatedExporter.counter("errors", value: 1.0)
        await aggregatedExporter.counter("errors", value: 2.0)
        await aggregatedExporter.counter("errors", value: 3.0)
        print("  Counters: Sum values → errors:6|c")
        
        // Gauges: Keep latest value
        await aggregatedExporter.gauge("memory.usage", value: 50.0)
        await aggregatedExporter.gauge("memory.usage", value: 75.0)
        await aggregatedExporter.gauge("memory.usage", value: 60.0)
        print("  Gauges: Keep latest → memory.usage:60|g")
        
        // Timers: Preserve all values (no loss)
        await aggregatedExporter.timer("db.query", duration: 100.0)
        await aggregatedExporter.timer("db.query", duration: 150.0)
        await aggregatedExporter.timer("db.query", duration: 200.0)
        print("  Timers: Keep all → sends 3 separate values\n")
        
        // MARK: - With Sampling
        
        print("4. AGGREGATION + SAMPLING:")
        print("---------------------------")
        
        let sampledConfig = StatsDExporter.Configuration(
            sampleRate: 0.1,  // 10% sampling
            aggregation: AggregationConfiguration(enabled: true)
        )
        
        let sampledExporter = StatsDExporter(configuration: sampledConfig)
        
        // Send 10000 metrics, sample 10%, aggregate to 1
        for i in 0..<10000 {
            await sampledExporter.counter("high.volume.metric")
        }
        
        print("  • 10,000 metrics → ~1,000 sampled → 1 aggregated packet")
        print("  • Value pre-scaled: ~10,000 (maintains accuracy)")
        print("  • Reduction: 10,000x\n")
        
        // MARK: - Production Patterns
        
        print("5. PRODUCTION PATTERNS:")
        print("------------------------")
        
        // Pattern 1: Request metrics in web server
        print("\n  Web Server Pattern:")
        for endpoint in ["/api/users", "/api/posts", "/api/comments"] {
            for _ in 0..<100 {
                await aggregatedExporter.counter("requests", tags: ["endpoint": endpoint])
            }
        }
        print("    • 300 requests → 3 aggregated metrics (by endpoint tag)")
        
        // Pattern 2: Background job metrics
        print("\n  Background Job Pattern:")
        for _ in 0..<50 {
            await aggregatedExporter.counter("jobs.processed")
            await aggregatedExporter.gauge("jobs.queue_size", value: Double.random(in: 0...100))
            await aggregatedExporter.timer("jobs.duration", duration: Double.random(in: 100...500))
        }
        print("    • 150 metrics → ~52 packets (1 counter, 1 gauge, 50 timers)")
        
        // Pattern 3: Error tracking
        print("\n  Error Tracking Pattern:")
        let errorTypes = ["timeout", "not_found", "internal", "bad_request"]
        for errorType in errorTypes {
            let count = Int.random(in: 0...10)
            for _ in 0..<count {
                await aggregatedExporter.counter("errors", tags: ["type": errorType])
            }
        }
        print("    • Errors aggregated by type")
        print("    • Critical errors bypass sampling (contains 'timeout')")
        
        // MARK: - Force Flush
        
        print("\n6. MANUAL FLUSH:")
        print("-----------------")
        await aggregatedExporter.forceFlush()
        print("  • All aggregated metrics sent immediately")
        print("  • Useful for: Graceful shutdown, testing, critical metrics\n")
        
        // MARK: - Configuration Examples
        
        print("7. CONFIGURATION OPTIONS:")
        print("--------------------------")
        
        print("""
        // Aggressive aggregation (1 minute window)
        AggregationConfiguration(
            enabled: true,
            flushInterval: 60.0,
            maxUniqueMetrics: 5000
        )
        
        // Balanced (10 seconds, default)
        AggregationConfiguration(
            enabled: true,
            flushInterval: 10.0
        )
        
        // Real-time (disabled)
        AggregationConfiguration(
            enabled: false
        )
        """)
        
        print("\n=== Benefits Summary ===")
        print("• 10x-1000x reduction in network packets")
        print("• Reduced UDP packet loss")
        print("• Lower StatsD server load")
        print("• Maintained statistical accuracy")
        print("• Backward compatible (opt-in)")
        print("• Memory bounded (configurable limits)")
    }
}