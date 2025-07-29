import Foundation
import PipelineKit

// Demo of the Metric Aggregation System
@main
struct AggregationDemo {
    static func main() async {
        print("PipelineKit Metric Aggregation Demo")
        print("====================================\n")
        
        // Create collector with aggregation
        let collector = MetricCollector(
            configuration: MetricCollector.Configuration(
                collectionInterval: 1.0,
                autoStart: true
            )
        )
        
        await collector.start()
        
        // Demo 1: Basic Aggregation
        print("Demo 1: Basic Aggregation")
        print("-------------------------")
        await demoBasicAggregation(collector)
        print()
        
        // Demo 2: Multi-Window Aggregation  
        print("Demo 2: Multi-Window Aggregation")
        print("--------------------------------")
        await demoMultiWindowAggregation(collector)
        print()
        
        // Demo 3: Query Patterns
        print("Demo 3: Query Patterns")
        print("----------------------")
        await demoQueryPatterns(collector)
        print()
        
        // Demo 4: Real-Time Monitoring
        print("Demo 4: Real-Time Monitoring")
        print("----------------------------")
        await demoRealTimeMonitoring(collector)
        print()
        
        await collector.stop()
    }
    
    static func demoBasicAggregation(_ collector: MetricCollector) async {
        // Generate sample metrics
        print("Generating metrics...")
        
        for i in 0..<20 {
            // CPU varies between 40-80%
            let cpu = 60.0 + 20.0 * sin(Double(i) * 0.5)
            await collector.record(.gauge("system.cpu", value: cpu))
            
            // Requests increase monotonically
            await collector.record(.counter("api.requests", value: Double(i * 10)))
            
            // Response times vary
            let responseTime = 100.0 + Double.random(in: -20...50)
            await collector.record(.histogram("api.response_time", value: responseTime))
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        
        // Query aggregated data
        let query = MetricQuery(
            namePattern: "*",
            timeRange: Date().addingTimeInterval(-60)...Date(),
            windows: [60]
        )
        
        if let result = await collector.query(query) {
            print("\nAggregated Metrics (1-minute window):")
            for metric in result.metrics {
                print("  \(metric)")
            }
            print("\nQuery completed in \(String(format: "%.3f", result.queryTime))s")
            print("Processed \(result.pointsProcessed) data points")
        }
    }
    
    static func demoMultiWindowAggregation(_ collector: MetricCollector) async {
        guard let aggregator = await collector.getAggregator() else { return }
        
        print("Generating metrics over time...")
        
        // Generate metrics for 2 minutes
        for minute in 0..<2 {
            print("  Minute \(minute + 1)...")
            
            for second in 0..<60 {
                let value = Double(minute * 60 + second)
                await collector.record(.counter("throughput.bytes", value: value * 1000))
                
                if second % 10 == 0 {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
                }
            }
        }
        
        // Query different time windows
        let windows: [TimeInterval] = [60, 300, 900]
        
        for window in windows {
            if let metric = await aggregator.get(
                metric: "throughput.bytes",
                window: window
            ) {
                print("\nThroughput (\(Int(window))s window):")
                if case .counter(let stats) = metric.statistics {
                    print("  Rate: \(String(format: "%.2f", stats.rate)) bytes/s")
                    print("  Total increase: \(stats.increase) bytes")
                }
            }
        }
    }
    
    static func demoQueryPatterns(_ collector: MetricCollector) async {
        // Generate various metrics
        let services = ["auth", "api", "db", "cache"]
        let operations = ["read", "write", "delete"]
        
        print("Generating service metrics...")
        
        for service in services {
            for operation in operations {
                for _ in 0..<10 {
                    let latency = Double.random(in: 10...100)
                    await collector.record(
                        .histogram("\(service).\(operation).latency", value: latency)
                    )
                }
            }
        }
        
        // Wait for aggregation
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Query patterns
        let patterns = [
            ("All metrics", "*"),
            ("Auth service only", "auth.*"),
            ("All read operations", "*.read.*"),
            ("Database operations", "db.*")
        ]
        
        for (description, pattern) in patterns {
            let query = MetricQuery(
                namePattern: pattern,
                timeRange: Date().addingTimeInterval(-300)...Date(),
                windows: [60]
            )
            
            if let result = await collector.query(query) {
                print("\n\(description) (pattern: '\(pattern)'):")
                let uniqueMetrics = Set(result.metrics.map { $0.name })
                for metric in uniqueMetrics.sorted() {
                    print("  - \(metric)")
                }
            }
        }
    }
    
    static func demoRealTimeMonitoring(_ collector: MetricCollector) async {
        guard let aggregator = await collector.getAggregator() else { return }
        
        print("Starting real-time monitoring for 10 seconds...")
        print("(Simulating system metrics)\n")
        
        let startTime = Date()
        var iteration = 0
        
        while Date().timeIntervalSince(startTime) < 10 {
            iteration += 1
            
            // Simulate system metrics
            let cpu = 50.0 + 30.0 * sin(Double(iteration) * 0.2)
            let memory = 2048.0 + 512.0 * cos(Double(iteration) * 0.15)
            let diskIO = Double.random(in: 1000...5000)
            let networkTx = Double(iteration * 1000)
            
            // Record metrics
            await collector.record(.gauge("system.cpu_percent", value: cpu))
            await collector.record(.gauge("system.memory_mb", value: memory))
            await collector.record(.histogram("system.disk_io_kb", value: diskIO))
            await collector.record(.counter("network.tx_bytes", value: networkTx))
            
            // Display current values every 2 seconds
            if iteration % 20 == 0 {
                print("[\(String(format: "%02d", iteration/10))s] Current metrics:")
                
                if let cpuValue = await aggregator.latestGauge("system.cpu_percent") {
                    print("  CPU: \(String(format: "%.1f", cpuValue))%")
                }
                
                if let memValue = await aggregator.latestGauge("system.memory_mb") {
                    print("  Memory: \(String(format: "%.0f", memValue)) MB")
                }
                
                if let diskStats = await aggregator.histogramPercentiles("system.disk_io_kb") {
                    print("  Disk I/O p95: \(String(format: "%.0f", diskStats.p95)) KB")
                }
                
                if let netRate = await aggregator.counterRate("network.tx_bytes") {
                    print("  Network TX: \(String(format: "%.0f", netRate)) bytes/s")
                }
                
                print()
            }
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        
        // Final statistics
        let stats = await aggregator.statistics()
        print("Monitoring completed:")
        print("  Total metrics processed: \(stats.totalProcessed)")
        print("  Active metrics: \(stats.metricCount)")
        print("  Time windows: \(stats.configuredWindows.sorted().map { "\(Int($0))s" }.joined(separator: ", "))")
    }
}