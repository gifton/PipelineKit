import XCTest
import Foundation
@testable import PipelineKit

/// Tests for MetricBuffer lock-free ring buffer implementation.
final class MetricBufferTests: XCTestCase {
    
    // MARK: - Basic Operations
    
    func testBufferInitialization() {
        let buffer = MetricBuffer(capacity: 100)
        let stats = buffer.statistics()
        
        XCTAssertEqual(stats.capacity, 128) // Rounded up to power of 2
        XCTAssertEqual(stats.used, 0)
        XCTAssertEqual(stats.available, 128)
        XCTAssertEqual(stats.totalWrites, 0)
        XCTAssertEqual(stats.droppedSamples, 0)
    }
    
    func testPowerOfTwoRounding() {
        // Test various capacities round up to nearest power of 2
        let testCases: [(requested: Int, expected: Int)] = [
            (1, 1),
            (2, 2),
            (3, 4),
            (7, 8),
            (15, 16),
            (17, 32),
            (100, 128),
            (1000, 1024),
            (8192, 8192)
        ]
        
        for (requested, expected) in testCases {
            let buffer = MetricBuffer(capacity: requested)
            let stats = buffer.statistics()
            XCTAssertEqual(stats.capacity, expected,
                          "Capacity \(requested) should round to \(expected)")
        }
    }
    
    func testWriteAndRead() {
        let buffer = MetricBuffer(capacity: 16)
        
        // Write a sample
        let sample = MetricDataPoint.gauge("test.metric", value: 42.0)
        XCTAssertTrue(buffer.write(sample))
        
        // Check statistics
        var stats = buffer.statistics()
        XCTAssertEqual(stats.used, 1)
        XCTAssertEqual(stats.totalWrites, 1)
        XCTAssertEqual(stats.droppedSamples, 0)
        
        // Read the sample back
        let samples = buffer.readBatch(maxCount: 10)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].name, "test.metric")
        XCTAssertEqual(samples[0].value, 42.0)
        XCTAssertEqual(samples[0].type, .gauge)
        
        // Buffer should be empty after read
        stats = buffer.statistics()
        XCTAssertEqual(stats.used, 0)
    }
    
    func testMultipleWritesAndBatchRead() {
        let buffer = MetricBuffer(capacity: 64)
        let sampleCount = 10
        
        // Write multiple samples
        for i in 0..<sampleCount {
            let sample = MetricDataPoint.counter("test.counter", value: Double(i))
            buffer.write(sample)
        }
        
        // Read all samples
        let samples = buffer.readBatch(maxCount: 20)
        XCTAssertEqual(samples.count, sampleCount)
        
        // Verify order and values
        for (index, sample) in samples.enumerated() {
            XCTAssertEqual(sample.value, Double(index))
            XCTAssertEqual(sample.type, .counter)
        }
    }
    
    func testPartialBatchRead() {
        let buffer = MetricBuffer(capacity: 64)
        
        // Write 20 samples
        for i in 0..<20 {
            buffer.write(MetricDataPoint.gauge("metric.\(i)", value: Double(i)))
        }
        
        // Read in batches of 5
        let batch1 = buffer.readBatch(maxCount: 5)
        XCTAssertEqual(batch1.count, 5)
        XCTAssertEqual(batch1[0].value, 0)
        XCTAssertEqual(batch1[4].value, 4)
        
        let batch2 = buffer.readBatch(maxCount: 5)
        XCTAssertEqual(batch2.count, 5)
        XCTAssertEqual(batch2[0].value, 5)
        XCTAssertEqual(batch2[4].value, 9)
        
        // Read remaining
        let batch3 = buffer.readBatch(maxCount: 100)
        XCTAssertEqual(batch3.count, 10)
        XCTAssertEqual(batch3[0].value, 10)
        XCTAssertEqual(batch3[9].value, 19)
        
        // Buffer should be empty
        XCTAssertEqual(buffer.statistics().used, 0)
    }
    
    // MARK: - Overflow Handling
    
    func testOverflowDropsOldestSamples() {
        let buffer = MetricBuffer(capacity: 8) // Will be 8 exactly
        
        // Fill buffer completely
        for i in 0..<8 {
            buffer.write(MetricDataPoint.gauge("metric", value: Double(i)))
        }
        
        var stats = buffer.statistics()
        XCTAssertEqual(stats.used, 8)
        XCTAssertEqual(stats.droppedSamples, 0)
        
        // Write one more - should drop oldest
        buffer.write(MetricDataPoint.gauge("metric", value: 8.0))
        
        stats = buffer.statistics()
        XCTAssertEqual(stats.used, 8) // Still full
        XCTAssertEqual(stats.droppedSamples, 1)
        XCTAssertEqual(stats.totalWrites, 9)
        
        // Read all - should get samples 1-8 (0 was dropped)
        let samples = buffer.readBatch(maxCount: 10)
        XCTAssertEqual(samples.count, 8)
        XCTAssertEqual(samples[0].value, 1.0) // First sample dropped
        XCTAssertEqual(samples[7].value, 8.0) // Last sample present
    }
    
    func testContinuousOverflow() {
        let buffer = MetricBuffer(capacity: 4) // Small buffer
        
        // Write many samples
        for i in 0..<20 {
            buffer.write(MetricDataPoint.gauge("metric", value: Double(i)))
        }
        
        let stats = buffer.statistics()
        XCTAssertEqual(stats.totalWrites, 20)
        XCTAssertEqual(stats.droppedSamples, 16) // 20 - 4
        XCTAssertEqual(stats.used, 4)
        
        // Should have the last 4 samples
        let samples = buffer.readBatch()
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0].value, 16.0)
        XCTAssertEqual(samples[3].value, 19.0)
    }
    
    // MARK: - Clear Operations
    
    func testClearBuffer() {
        let buffer = MetricBuffer(capacity: 16)
        
        // Add samples
        for i in 0..<10 {
            buffer.write(MetricDataPoint.gauge("metric", value: Double(i)))
        }
        
        XCTAssertEqual(buffer.statistics().used, 10)
        
        // Clear buffer
        buffer.clear()
        
        let stats = buffer.statistics()
        XCTAssertEqual(stats.used, 0)
        XCTAssertEqual(stats.totalWrites, 10) // Preserved
        XCTAssertEqual(stats.droppedSamples, 0)
        
        // Should read nothing
        let samples = buffer.readBatch()
        XCTAssertEqual(samples.count, 0)
    }
    
    // MARK: - Statistics
    
    func testStatisticsCalculations() {
        let buffer = MetricBuffer(capacity: 100)
        
        // Fill to 50%
        for i in 0..<64 {
            buffer.write(MetricDataPoint.gauge("metric", value: Double(i)))
        }
        
        let stats = buffer.statistics()
        XCTAssertEqual(stats.capacity, 128)
        XCTAssertEqual(stats.used, 64)
        XCTAssertEqual(stats.available, 64)
        XCTAssertEqual(stats.utilization, 0.5, accuracy: 0.01)
        XCTAssertEqual(stats.dropRate, 0.0)
        
        // Force some drops
        for i in 0..<70 {
            buffer.write(MetricDataPoint.gauge("metric", value: Double(i)))
        }
        
        let stats2 = buffer.statistics()
        XCTAssertEqual(stats2.totalWrites, 134)
        XCTAssertEqual(stats2.droppedSamples, 6) // 64 + 70 - 128
        XCTAssertGreaterThan(stats2.dropRate, 0.0)
        XCTAssertLessThan(stats2.dropRate, 0.1) // Should be ~4.5%
    }
    
    // MARK: - Edge Cases
    
    func testEmptyRead() {
        let buffer = MetricBuffer()
        let samples = buffer.readBatch()
        XCTAssertEqual(samples.count, 0)
    }
    
    func testWriteReadCycle() {
        let buffer = MetricBuffer(capacity: 8)
        
        // Multiple write-read cycles
        for cycle in 0..<3 {
            // Write batch
            for i in 0..<5 {
                let value = Double(cycle * 10 + i)
                buffer.write(MetricDataPoint.gauge("metric", value: value))
            }
            
            // Read batch
            let samples = buffer.readBatch()
            XCTAssertEqual(samples.count, 5)
            XCTAssertEqual(samples[0].value, Double(cycle * 10))
        }
    }
    
    func testMetricDataPointTypes() {
        let buffer = MetricBuffer(capacity: 16)
        
        // Write different metric types
        buffer.write(MetricDataPoint.gauge("gauge.metric", value: 1.0))
        buffer.write(MetricDataPoint.counter("counter.metric", value: 2.0))
        buffer.write(MetricDataPoint.histogram("histogram.metric", value: 3.0))
        buffer.write(MetricDataPoint.timer("timer.metric", seconds: 4.0))
        
        let samples = buffer.readBatch()
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0].type, .gauge)
        XCTAssertEqual(samples[1].type, .counter)
        XCTAssertEqual(samples[2].type, .histogram)
        XCTAssertEqual(samples[3].type, .timer)
    }
    
    func testMetricTags() {
        let buffer = MetricBuffer()
        
        let tags = ["simulator": "cpu", "phase": "ramp"]
        let sample = MetricDataPoint.gauge("cpu.usage", value: 75.0, tags: tags)
        
        buffer.write(sample)
        
        let samples = buffer.readBatch()
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].tags["simulator"], "cpu")
        XCTAssertEqual(samples[0].tags["phase"], "ramp")
    }
}
