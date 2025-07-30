import Foundation

/// Demonstrates metrics integration with MemoryPressureSimulator.
///
/// This example shows how the MemoryPressureSimulator automatically
/// records detailed metrics during various memory pressure patterns.
public struct MemoryMetricsDemo {
    public static func main() async throws {
        print("🎯 Memory Pressure Metrics Demo")
        print("=" * 50)
        
        // Create components
        let resourceManager = ResourceManager()
        let safetyMonitor = DefaultSafetyMonitor(
            maxMemoryUsage: 0.8,
            maxCPUUsagePerCore: 0.9
        )
        
        // Create metric collector with exporters
        let collector = MetricCollector(configuration: .init(
            collectionInterval: 0.5,  // Collect every 500ms
            autoStart: true
        ))
        await collector.start()
        
        // Add CSV exporter for analysis
        let csvExporter = try await CSVExporter(configuration: .init(
            fileConfig: .init(path: "/tmp/memory-metrics.csv"),
            includeHeaders: true
        ))
        await collector.addExporter(csvExporter, name: "csv")
        
        // Create simulator with metrics
        let simulator = MemoryPressureSimulator(
            resourceManager: resourceManager,
            safetyMonitor: safetyMonitor,
            metricCollector: collector
        )
        
        print("\n📊 Running memory pressure patterns with metrics...")
        
        // 1. Gradual Pressure Pattern
        print("\n1️⃣ Gradual Pressure Pattern")
        print("   Target: 40% memory usage over 10 seconds")
        
        do {
            try await simulator.applyGradualPressure(
                targetUsage: 0.4,
                duration: 10.0,
                stepSize: 5_000_000  // 5MB steps
            )
            print("   ✅ Completed successfully")
        } catch {
            print("   ❌ Failed: \(error)")
        }
        
        // Release and wait
        await simulator.releaseAll()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // 2. Burst Pattern
        print("\n2️⃣ Burst Allocation Pattern")
        print("   Size: 100MB, Hold time: 5 seconds")
        
        do {
            try await simulator.burst(
                size: 100_000_000,
                holdTime: 5.0
            )
            print("   ✅ Completed successfully")
        } catch {
            print("   ❌ Failed: \(error)")
        }
        
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // 3. Oscillating Pattern
        print("\n3️⃣ Oscillating Memory Pattern")
        print("   Range: 20% - 50%, Period: 15 seconds, Cycles: 2")
        
        do {
            try await simulator.oscillate(
                minUsage: 0.2,
                maxUsage: 0.5,
                period: 15.0,
                cycles: 2
            )
            print("   ✅ Completed successfully")
        } catch {
            print("   ❌ Failed: \(error)")
        }
        
        await simulator.releaseAll()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // 4. Stepped Pattern
        print("\n4️⃣ Stepped Memory Pattern")
        print("   Steps: 10%, 20%, 30%, 40%, Hold: 3 seconds each")
        
        do {
            try await simulator.stepped(
                steps: [0.1, 0.2, 0.3, 0.4],
                holdTime: 3.0
            )
            print("   ✅ Completed successfully")
        } catch {
            print("   ❌ Failed: \(error)")
        }
        
        await simulator.releaseAll()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // 5. Memory Fragmentation
        print("\n5️⃣ Memory Fragmentation Pattern")
        print("   Total: 50MB in 100 fragments")
        
        do {
            try await simulator.createFragmentation(
                totalSize: 50_000_000,
                fragmentCount: 100
            )
            print("   ✅ Created 100 fragments successfully")
        } catch {
            print("   ❌ Failed: \(error)")
        }
        
        await simulator.releaseAll()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // 6. Memory Leak Simulation
        print("\n6️⃣ Memory Leak Simulation")
        print("   Rate: 1MB/second for 10 seconds")
        
        do {
            try await simulator.simulateLeak(
                rate: 1_000_000,
                duration: 10.0
            )
            print("   ✅ Leak simulation completed")
        } catch {
            print("   ❌ Failed: \(error)")
        }
        
        // Final cleanup
        await simulator.releaseAll()
        
        // Get final statistics
        let stats = await collector.statistics()
        print("\n📈 Metrics Collection Summary")
        print("   Total metrics collected: \(stats.totalCollected)")
        print("   Unique metrics: \(stats.bufferStatistics.count)")
        print("   Exporters active: \(stats.exporterCount)")
        
        // Show some buffer statistics
        print("\n📊 Top Metrics:")
        let bufferStats = stats.bufferStatistics
        var metricsList: [(String, BufferStatistics)] = []
        for (metric, stats) in bufferStats {
            metricsList.append((metric, stats))
        }
        
        // Sort by total writes
        metricsList.sort { (lhs: (String, BufferStatistics), rhs: (String, BufferStatistics)) in
            lhs.1.totalWrites > rhs.1.totalWrites
        }
        
        // Show top 5
        for (metric, bufferStats) in metricsList.prefix(5) {
            print("   \(metric): \(bufferStats.totalWrites) samples written")
        }
        
        // Ensure export completes
        try await csvExporter.flush()
        await csvExporter.shutdown()
        
        print("\n💾 Metrics exported to: /tmp/memory-metrics.csv")
        print("\n🏁 Demo completed!")
        
        // Stop components
        await collector.stop()
    }
}

// String multiplication helper
fileprivate func *(lhs: String, rhs: Int) -> String {
    String(repeating: lhs, count: rhs)
}