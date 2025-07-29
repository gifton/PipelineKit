import Foundation
import PipelineKit

/// Demonstrates the MetricBuffer functionality
@main
struct MetricBufferDemo {
    static func main() async {
        print("Metrics Collection Demo")
        print("======================\n")
        
        await testBasicOperations()
        await testOverflowHandling()
        await testConcurrentAccess()
        await testPerformance()
        await testMetricCollector()
        
        print("\n🎉 All demos completed!")
    }
    
    static func testBasicOperations() async {
        print("Demo 1: Basic Operations")
        print("------------------------")
        
        let buffer = MetricBuffer(capacity: 100)
        
        // Write samples
        for i in 0..<10 {
            let sample = MetricDataPoint.gauge("test.metric", value: Double(i))
            buffer.write(sample)
        }
        
        let stats = buffer.statistics()
        print("After 10 writes:")
        print("  Used: \(stats.used)")
        print("  Available: \(stats.available)")
        print("  Total writes: \(stats.totalWrites)")
        
        // Read samples
        let samples = buffer.readBatch(maxCount: 5)
        print("\nRead \(samples.count) samples:")
        for sample in samples {
            print("  \(sample.name) = \(sample.value)")
        }
        
        let finalStats = buffer.statistics()
        print("\nFinal state:")
        print("  Used: \(finalStats.used)")
        print("  Utilization: \(String(format: "%.1f%%", finalStats.utilization * 100))")
        
        print()
    }
    
    static func testOverflowHandling() async {
        print("Demo 2: Overflow Handling")
        print("-------------------------")
        
        let buffer = MetricBuffer(capacity: 8)
        
        // Fill buffer beyond capacity
        for i in 0..<12 {
            buffer.write(MetricDataPoint.counter("overflow.test", value: Double(i)))
        }
        
        let stats = buffer.statistics()
        print("After overflow:")
        print("  Capacity: \(stats.capacity)")
        print("  Used: \(stats.used)")
        print("  Dropped: \(stats.droppedSamples)")
        print("  Drop rate: \(String(format: "%.1f%%", stats.dropRate * 100))")
        
        // Read all remaining
        let samples = buffer.readBatch()
        print("\nRemaining samples: [", terminator: "")
        for (i, sample) in samples.enumerated() {
            print("\(Int(sample.value))", terminator: i < samples.count - 1 ? ", " : "")
        }
        print("]")
        print("Expected: [4, 5, 6, 7, 8, 9, 10, 11] (first 4 dropped)")
        
        print()
    }
    
    static func testConcurrentAccess() async {
        print("Demo 3: Concurrent Access")
        print("-------------------------")
        
        let buffer = MetricBuffer(capacity: 1024)
        let writerCount = 5
        let samplesPerWriter = 100
        
        // Launch concurrent writers
        await withTaskGroup(of: Void.self) { group in
            for writerID in 0..<writerCount {
                group.addTask {
                    for i in 0..<samplesPerWriter {
                        let sample = MetricDataPoint.histogram(
                            "concurrent.test",
                            value: Double(writerID * 1000 + i),
                            tags: ["writer": String(writerID)]
                        )
                        buffer.write(sample)
                        
                        // Small delay to increase contention
                        if i % 20 == 0 {
                            try? await Task.sleep(nanoseconds: 100_000) // 0.1ms
                        }
                    }
                }
            }
        }
        
        let stats = buffer.statistics()
        print("Concurrent writes completed:")
        print("  Total writes: \(stats.totalWrites)")
        print("  Expected: \(writerCount * samplesPerWriter)")
        print("  Match: \(stats.totalWrites == writerCount * samplesPerWriter ? "✅" : "❌")")
        
        // Read and verify samples by writer
        let allSamples = buffer.readBatch(maxCount: 1000)
        let samplesByWriter = Dictionary(grouping: allSamples) { sample in
            sample.tags["writer"] ?? "unknown"
        }
        
        print("\nSamples per writer:")
        for writer in 0..<writerCount {
            let count = samplesByWriter[String(writer)]?.count ?? 0
            print("  Writer \(writer): \(count) samples")
        }
        
        print()
    }
    
    static func testPerformance() async {
        print("Demo 4: Performance Test")
        print("------------------------")
        
        let buffer = MetricBuffer(capacity: 65536)
        let iterations = 100_000
        
        // Warm up
        for i in 0..<1000 {
            buffer.write(MetricDataPoint.timer("warmup", seconds: Double(i) / 1000.0))
        }
        buffer.clear()
        
        // Measure write performance
        let start = Date()
        for i in 0..<iterations {
            buffer.write(MetricDataPoint.timer("perf.test", seconds: Double(i) / 1000.0))
        }
        let elapsed = Date().timeIntervalSince(start)
        
        let writesPerSec = Double(iterations) / elapsed
        let nanosPerWrite = (elapsed * 1_000_000_000) / Double(iterations)
        
        print("Write performance:")
        print("  Iterations: \(iterations)")
        print("  Time: \(String(format: "%.3f", elapsed))s")
        print("  Throughput: \(String(format: "%.0f", writesPerSec)) writes/sec")
        print("  Latency: \(String(format: "%.0f", nanosPerWrite))ns per write")
        print("  Target: <100ns \(nanosPerWrite < 100 ? "✅" : "⚠️")")
        
        // Test buffer pool
        print("\nBuffer Pool Test:")
        let pool = MetricBufferPool(defaultCapacity: 256)
        
        let cpuBuffer = await pool.buffer(for: "cpu.usage")
        let memBuffer = await pool.buffer(for: "memory.usage")
        
        for i in 0..<50 {
            cpuBuffer.write(MetricDataPoint.gauge("cpu.usage", value: Double(i)))
            memBuffer.write(MetricDataPoint.gauge("memory.usage", value: Double(i * 2)))
        }
        
        let poolStats = await pool.allStatistics()
        for (metric, stats) in poolStats {
            print("  \(metric): \(stats.used) samples")
        }
    }
    
    static func testMetricCollector() async {
        print("\nDemo 5: Metric Collector")
        print("------------------------")
        
        // Create collector with fast collection
        let config = MetricCollector.Configuration(
            collectionInterval: 0.5,  // 500ms
            batchSize: 100,
            autoStart: true
        )
        let collector = MetricCollector(configuration: config)
        
        // Start streaming metrics
        let streamTask = Task {
            print("\nStreaming metrics:")
            var count = 0
            for await metric in await collector.stream() {
                print("  [\(metric.type)] \(metric.name) = \(metric.value)")
                count += 1
                if count >= 10 {
                    break
                }
            }
        }
        
        // Simulate metric generation
        print("\nGenerating metrics...")
        for i in 0..<5 {
            await collector.record(.gauge("system.cpu", value: 50.0 + Double(i * 5)))
            await collector.record(.counter("requests.total", value: Double(i)))
            await collector.record(.histogram("response.time", value: 100.0 + Double(i * 10)))
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        
        // Wait for streaming to complete
        await streamTask.value
        
        // Show final statistics
        let stats = await collector.statistics()
        print("\nCollection Statistics:")
        print("  State: \(stats.state)")
        print("  Total collected: \(stats.totalCollected)")
        print("  Buffer count: \(stats.bufferStatistics.count)")
        print("  Last collection: \(stats.lastCollectionTime?.formatted() ?? "N/A")")
        
        await collector.stop()
    }
}
