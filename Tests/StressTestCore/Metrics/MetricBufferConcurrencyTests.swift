import XCTest
@testable import PipelineKit
@testable import StressTestSupport

// NOTE: These tests require PipelineKitStressTest types which have been
// moved to a separate package. They should be moved to that package's test suite.
final class MetricBufferConcurrencyTests: XCTestCase {
    func testPlaceholder() {
        // Placeholder test to prevent empty test class
        XCTAssertTrue(true)
    }
}

/*
import XCTest
import Foundation
@testable import PipelineKit
@testable import StressTestSupport

/// Concurrent safety tests for MetricBuffer.
///
/// These tests verify the lock-free ring buffer implementation is safe
/// for concurrent write and read operations.
final class MetricBufferConcurrencyTests: XCTestCase {
    
    // MARK: - Concurrent Write Tests
    
    func testConcurrentWrites() async throws {
        let buffer = MetricBuffer(capacity: 1024)
        let writersCount = 10
        let samplesPerWriter = 100
        
        // Launch multiple concurrent writers
        await withTaskGroup(of: Void.self) { group in
            for writerID in 0..<writersCount {
                group.addTask {
                    for i in 0..<samplesPerWriter {
                        let sample = MetricDataPoint.gauge(
                            "writer.\(writerID)",
                            value: Double(i),
                            tags: ["writer": String(writerID)]
                        )
                        buffer.write(sample)
                        
                        // Small random delay to increase contention
                        if i % 10 == 0 {
                            try? await Task.sleep(nanoseconds: UInt64.random(in: 1000...10000))
                        }
                    }
                }
            }
        }
        
        // Verify total writes
        let stats = buffer.statistics()
        XCTAssertEqual(stats.totalWrites, writersCount * samplesPerWriter)
        
        // Read all samples and verify each writer's samples
        var allSamples: [MetricDataPoint] = []
        while true {
            let batch = buffer.readBatch(maxCount: 100)
            if batch.isEmpty { break }
            allSamples.append(contentsOf: batch)
        }
        
        // Group by writer and verify
        let samplesByWriter = Dictionary(grouping: allSamples) { sample in
            sample.tags["writer"] ?? ""
        }
        
        // Each writer should have some samples (might lose some due to overflow)
        XCTAssertEqual(samplesByWriter.count, writersCount)
    }
    
    func testWriteReadRaceCondition() async throws {
        let buffer = MetricBuffer(capacity: 256)
        let testDuration: TimeInterval = 2.0
        let endTime = Date().addingTimeInterval(testDuration)
        
        var totalWritten = 0
        var totalRead = 0
        
        // Writer task
        let writerTask = Task {
            var written = 0
            while Date() < endTime {
                let sample = MetricDataPoint.counter("test.counter", value: Double(written))
                buffer.write(sample)
                written += 1
                
                // Occasional yield to increase contention
                if written % 100 == 0 {
                    await Task.yield()
                }
            }
            return written
        }
        
        // Reader task
        let readerTask = Task {
            var read = 0
            while Date() < endTime {
                let samples = buffer.readBatch(maxCount: 50)
                read += samples.count
                
                // Small delay between reads
                try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
            
            // Final read to get any remaining
            let final = buffer.readBatch(maxCount: 1000)
            read += final.count
            
            return read
        }
        
        // Wait for both tasks
        totalWritten = await writerTask.value
        totalRead = await readerTask.value
        
        print("[Race Test] Written: \(totalWritten), Read: \(totalRead)")
        
        // Read should not exceed written
        XCTAssertLessThanOrEqual(totalRead, totalWritten)
        
        // Stats should be consistent
        let stats = buffer.statistics()
        XCTAssertEqual(stats.totalWrites, totalWritten)
    }
    
    // MARK: - Stress Tests
    
    func testHighFrequencyWrites() async throws {
        let buffer = MetricBuffer(capacity: 8192)
        let duration: TimeInterval = 1.0
        let endTime = Date().addingTimeInterval(duration)
        
        var writeCount = 0
        
        // Write as fast as possible
        while Date() < endTime {
            let sample = MetricDataPoint.gauge("high.freq", value: Double(writeCount))
            buffer.write(sample)
            writeCount += 1
        }
        
        let stats = buffer.statistics()
        print("[High Frequency Test] Writes per second: \(writeCount)")
        print("[High Frequency Test] Drop rate: \(stats.dropRate * 100)%")
        
        // Should achieve high write rate
        XCTAssertGreaterThan(writeCount, 100_000) // At least 100K writes/sec
        XCTAssertEqual(stats.totalWrites, writeCount)
    }
    
    func testBurstWritePattern() async throws {
        let buffer = MetricBuffer(capacity: 512)
        
        // Simulate burst write pattern
        for burst in 0..<5 {
            // Burst write
            for i in 0..<200 {
                let sample = MetricDataPoint.histogram(
                    "burst.latency",
                    value: Double(i),
                    tags: ["burst": String(burst)]
                )
                buffer.write(sample)
            }
            
            // Pause between bursts
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            
            // Read some samples
            let _ = buffer.readBatch(maxCount: 100)
        }
        
        let stats = buffer.statistics()
        XCTAssertEqual(stats.totalWrites, 1000) // 5 bursts * 200 samples
        XCTAssertGreaterThan(stats.droppedSamples, 0) // Should have some drops
    }
    
    // MARK: - Memory Safety
    
    func testMemorySafetyUnderPressure() async throws {
        let buffer = MetricBuffer(capacity: 128)
        let iterations = 10_000
        
        // Rapid write-read cycles with varying batch sizes
        for i in 0..<iterations {
            // Write random number of samples
            let writeCount = Int.random(in: 1...20)
            for j in 0..<writeCount {
                let sample = MetricDataPoint.timer(
                    "memory.test",
                    seconds: Double(i * 100 + j) / 1000.0
                )
                buffer.write(sample)
            }
            
            // Read random batch size
            let readCount = Int.random(in: 1...30)
            let _ = buffer.readBatch(maxCount: readCount)
            
            // Occasionally clear
            if i % 1000 == 0 {
                buffer.clear()
            }
        }
        
        // Final statistics check
        let stats = buffer.statistics()
        XCTAssertGreaterThanOrEqual(stats.totalWrites, 0)
        XCTAssertLessThanOrEqual(stats.used, stats.capacity)
    }
    
    // MARK: - Performance Benchmarks
    
    func testWritePerformance() throws {
        let buffer = MetricBuffer(capacity: 16384)
        let sampleCount = 1_000_000
        
        // Pre-create samples to isolate buffer performance
        let samples = (0..<sampleCount).map { i in
            MetricDataPoint.gauge("perf.test", value: Double(i))
        }
        
        measure {
            for sample in samples {
                buffer.write(sample)
            }
            buffer.clear() // Reset for next iteration
        }
    }
    
    func testReadPerformance() throws {
        let buffer = MetricBuffer(capacity: 16384)
        
        // Pre-fill buffer
        for i in 0..<10000 {
            buffer.write(MetricDataPoint.gauge("perf.test", value: Double(i)))
        }
        
        measure {
            // Read all samples in batches
            var total = 0
            while true {
                let batch = buffer.readBatch(maxCount: 1000)
                if batch.isEmpty { break }
                total += batch.count
            }
            
            // Refill for next iteration
            for i in 0..<10000 {
                buffer.write(MetricDataPoint.gauge("perf.test", value: Double(i)))
            }
        }
    }
    
    // MARK: - Buffer Pool Tests
    
    func testBufferPoolConcurrentAccess() async throws {
        let pool = MetricBufferPool(defaultCapacity: 256)
        let metrics = ["cpu.usage", "memory.usage", "disk.io", "network.throughput"]
        
        // Multiple tasks accessing different metric buffers
        await withTaskGroup(of: Void.self) { group in
            for metric in metrics {
                group.addTask {
                    let buffer = await pool.buffer(for: metric)
                    
                    // Write samples
                    for i in 0..<100 {
                        buffer.write(MetricDataPoint.gauge(metric, value: Double(i)))
                        
                        if i % 20 == 0 {
                            try? await Task.sleep(nanoseconds: 100_000)
                        }
                    }
                }
            }
        }
        
        // Check all buffers
        let allStats = await pool.allStatistics()
        XCTAssertEqual(allStats.count, metrics.count)
        
        for (metric, stats) in allStats {
            XCTAssertGreaterThan(stats.totalWrites, 0)
            print("[Pool Test] \(metric): \(stats.totalWrites) writes, \(stats.used) in buffer")
        }
    }
    
    func testBufferPoolClearAll() async throws {
        let pool = MetricBufferPool()
        
        // Create and fill multiple buffers
        for i in 0..<5 {
            let buffer = await pool.buffer(for: "metric.\(i)")
            for j in 0..<50 {
                buffer.write(MetricDataPoint.counter("metric.\(i)", value: Double(j)))
            }
        }
        
        // Clear all
        await pool.clearAll()
        
        // Verify all are empty
        let stats = await pool.allStatistics()
        for (_, bufferStats) in stats {
            XCTAssertEqual(bufferStats.used, 0)
        }
    }
}
*/
