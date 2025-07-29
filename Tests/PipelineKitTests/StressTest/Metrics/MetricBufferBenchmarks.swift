import XCTest
import Foundation
import os
@testable import PipelineKit

/// Performance benchmarks for MetricBuffer.
///
/// These benchmarks verify that the lock-free ring buffer meets
/// our performance targets:
/// - Write: <100ns per operation
/// - Read: Proportional to batch size
/// - Minimal memory allocation
final class MetricBufferBenchmarks: XCTestCase {
    
    // MARK: - Write Performance
    
    func testSingleWriteLatency() throws {
        let buffer = MetricBuffer(capacity: 65536) // Large buffer to avoid overflow
        let iterations = 1_000_000
        
        // Warm up
        for i in 0..<1000 {
            buffer.write(MetricDataPoint.gauge("warmup", value: Double(i)))
        }
        buffer.clear()
        
        // Measure individual write latency
        var totalNanos: UInt64 = 0
        var maxNanos: UInt64 = 0
        var minNanos: UInt64 = UInt64.max
        
        for i in 0..<iterations {
            let sample = MetricDataPoint.gauge("test.metric", value: Double(i))
            
            let start = DispatchTime.now()
            buffer.write(sample)
            let end = DispatchTime.now()
            
            let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
            totalNanos += nanos
            maxNanos = max(maxNanos, nanos)
            minNanos = min(minNanos, nanos)
        }
        
        let avgNanos = Double(totalNanos) / Double(iterations)
        
        print("[Write Latency Benchmark]")
        print("  Average: \(String(format: "%.1f", avgNanos))ns")
        print("  Min: \(minNanos)ns")
        print("  Max: \(maxNanos)ns")
        print("  Total writes: \(iterations)")
        
        // Verify we meet <100ns average target
        XCTAssertLessThan(avgNanos, 100, "Average write latency should be <100ns")
    }
    
    func testBulkWriteThroughput() throws {
        let buffer = MetricBuffer(capacity: 32768)
        let duration: TimeInterval = 5.0
        
        // Pre-create samples
        let samples = (0..<1000).map { i in
            MetricDataPoint.counter("throughput.test", value: Double(i))
        }
        
        let start = Date()
        var writeCount = 0
        
        while Date().timeIntervalSince(start) < duration {
            for sample in samples {
                buffer.write(sample)
                writeCount += 1
            }
        }
        
        let elapsed = Date().timeIntervalSince(start)
        let writesPerSecond = Double(writeCount) / elapsed
        let nanosPerWrite = (elapsed * 1_000_000_000) / Double(writeCount)
        
        print("[Bulk Write Throughput]")
        print("  Total writes: \(writeCount)")
        print("  Duration: \(String(format: "%.2f", elapsed))s")
        print("  Throughput: \(String(format: "%.0f", writesPerSecond)) writes/sec")
        print("  Average latency: \(String(format: "%.1f", nanosPerWrite))ns")
        
        // Should achieve at least 10M writes/sec
        XCTAssertGreaterThan(writesPerSecond, 10_000_000)
    }
    
    // MARK: - Read Performance
    
    func testBatchReadScaling() throws {
        let buffer = MetricBuffer(capacity: 16384)
        
        // Fill buffer
        for i in 0..<10000 {
            buffer.write(MetricDataPoint.histogram("read.test", value: Double(i)))
        }
        
        // Test different batch sizes
        let batchSizes = [1, 10, 100, 1000, 5000]
        
        print("[Batch Read Scaling]")
        
        for batchSize in batchSizes {
            // Refill if needed
            while buffer.statistics().used < batchSize {
                for i in 0..<batchSize {
                    buffer.write(MetricDataPoint.histogram("read.test", value: Double(i)))
                }
            }
            
            let start = DispatchTime.now()
            let samples = buffer.readBatch(maxCount: batchSize)
            let end = DispatchTime.now()
            
            let totalNanos = end.uptimeNanoseconds - start.uptimeNanoseconds
            let nanosPerSample = samples.isEmpty ? 0 : Double(totalNanos) / Double(samples.count)
            
            print("  Batch size \(batchSize): \(String(format: "%.0f", Double(totalNanos)))ns total, " +
                  "\(String(format: "%.1f", nanosPerSample))ns per sample")
        }
    }
    
    // MARK: - Memory Performance
    
    func testMemoryEfficiency() throws {
        let bufferSizes = [1024, 8192, 65536]
        
        print("[Memory Efficiency]")
        
        for size in bufferSizes {
            let buffer = MetricBuffer(capacity: size)
            
            // Fill to capacity
            for i in 0..<size {
                buffer.write(MetricDataPoint.gauge("memory.test", value: Double(i)))
            }
            
            let stats = buffer.statistics()
            let expectedMemory = size * MetricDataPoint.estimatedSize
            let efficiencyRatio = Double(stats.capacity) / Double(size)
            
            print("  Capacity \(size) -> \(stats.capacity) (\(String(format: "%.1fx", efficiencyRatio)))")
            print("    Estimated memory: \(expectedMemory / 1024)KB")
        }
    }
    
    // MARK: - Contention Performance
    
    func testContentionOverhead() async throws {
        let buffer = MetricBuffer(capacity: 16384)
        let duration: TimeInterval = 2.0
        let writerCounts = [1, 2, 4, 8]
        
        print("[Contention Overhead]")
        
        for writerCount in writerCounts {
            buffer.clear()
            
            let start = Date()
            var totalWrites = 0
            
            await withTaskGroup(of: Int.self) { group in
                for _ in 0..<writerCount {
                    group.addTask {
                        var writes = 0
                        while Date().timeIntervalSince(start) < duration {
                            buffer.write(MetricDataPoint.gauge("contention.test", value: Double(writes)))
                            writes += 1
                        }
                        return writes
                    }
                }
                
                for await writes in group {
                    totalWrites += writes
                }
            }
            
            let elapsed = Date().timeIntervalSince(start)
            let writesPerSecond = Double(totalWrites) / elapsed
            let writesPerSecondPerWriter = writesPerSecond / Double(writerCount)
            
            print("  \(writerCount) writers: \(String(format: "%.0f", writesPerSecond)) total writes/sec")
            print("    Per writer: \(String(format: "%.0f", writesPerSecondPerWriter)) writes/sec")
        }
    }
    
    // MARK: - Statistical Analysis
    
    func testLatencyPercentiles() throws {
        let buffer = MetricBuffer(capacity: 65536)
        let sampleCount = 100_000
        var latencies: [UInt64] = []
        latencies.reserveCapacity(sampleCount)
        
        // Collect write latencies
        for i in 0..<sampleCount {
            let sample = MetricDataPoint.timer("latency.test", seconds: Double(i) / 1000.0)
            
            let start = DispatchTime.now()
            buffer.write(sample)
            let end = DispatchTime.now()
            
            latencies.append(end.uptimeNanoseconds - start.uptimeNanoseconds)
        }
        
        // Calculate percentiles
        latencies.sort()
        
        let p50 = latencies[sampleCount / 2]
        let p90 = latencies[sampleCount * 9 / 10]
        let p95 = latencies[sampleCount * 95 / 100]
        let p99 = latencies[sampleCount * 99 / 100]
        let p999 = latencies[sampleCount * 999 / 1000]
        
        print("[Write Latency Percentiles]")
        print("  P50:  \(p50)ns")
        print("  P90:  \(p90)ns")
        print("  P95:  \(p95)ns")
        print("  P99:  \(p99)ns")
        print("  P99.9: \(p999)ns")
        
        // Verify P99 is still reasonable
        XCTAssertLessThan(p99, 1000, "P99 latency should be <1μs")
    }
    
    // MARK: - Stress Scenarios
    
    func testSustainedHighLoad() async throws {
        let buffer = MetricBuffer(capacity: 8192)
        let duration: TimeInterval = 10.0
        let targetWritesPerSecond = 1_000_000
        
        print("[Sustained High Load Test]")
        print("  Target: \(targetWritesPerSecond) writes/sec for \(duration)s")
        
        let start = Date()
        var totalWrites = 0
        var lastReport = start
        
        while Date().timeIntervalSince(start) < duration {
            // Write batch
            for _ in 0..<1000 {
                buffer.write(MetricDataPoint.gauge("sustained.load", value: Double(totalWrites)))
                totalWrites += 1
            }
            
            // Periodic reporting
            if Date().timeIntervalSince(lastReport) >= 1.0 {
                let elapsed = Date().timeIntervalSince(start)
                let currentRate = Double(totalWrites) / elapsed
                print("    \(String(format: "%.1f", elapsed))s: \(String(format: "%.0f", currentRate)) writes/sec")
                lastReport = Date()
            }
            
            // Occasional reads to simulate real usage
            if totalWrites % 10000 == 0 {
                let _ = buffer.readBatch(maxCount: 100)
            }
        }
        
        let finalElapsed = Date().timeIntervalSince(start)
        let finalRate = Double(totalWrites) / finalElapsed
        let stats = buffer.statistics()
        
        print("  Final: \(totalWrites) writes in \(String(format: "%.1f", finalElapsed))s")
        print("  Average rate: \(String(format: "%.0f", finalRate)) writes/sec")
        print("  Drop rate: \(String(format: "%.2f", stats.dropRate * 100))%")
        
        // Should sustain high rate
        XCTAssertGreaterThan(finalRate, Double(targetWritesPerSecond) * 0.9)
    }
}
