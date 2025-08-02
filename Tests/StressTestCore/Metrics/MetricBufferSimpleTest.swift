import XCTest
@testable import PipelineKit
@testable import StressTestSupport

// NOTE: These tests require PipelineKitStressTest types which have been
// moved to a separate package. They should be moved to that package's test suite.
final class MetricBufferSimpleTest: XCTestCase {
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

/// Simple test to verify MetricBuffer basic functionality.
final class MetricBufferSimpleTest: XCTestCase {
    
    func testMetricBufferBasics() {
        // Create buffer
        let buffer = MetricBuffer(capacity: 100)
        
        // Test initial state
        let stats = buffer.statistics()
        print("Initial stats:")
        print("  Capacity: \(stats.capacity)")
        print("  Used: \(stats.used)")
        print("  Available: \(stats.available)")
        XCTAssertEqual(stats.capacity, 128) // Rounded to power of 2
        XCTAssertEqual(stats.used, 0)
        
        // Write samples
        for i in 0..<10 {
            let sample = MetricDataPoint.gauge("test.metric", value: Double(i))
            buffer.write(sample)
        }
        
        // Check after writes
        let stats2 = buffer.statistics()
        print("\nAfter 10 writes:")
        print("  Used: \(stats2.used)")
        print("  Total writes: \(stats2.totalWrites)")
        XCTAssertEqual(stats2.used, 10)
        XCTAssertEqual(stats2.totalWrites, 10)
        
        // Read samples
        let samples = buffer.readBatch(maxCount: 5)
        print("\nRead \(samples.count) samples")
        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples[0].value, 0.0)
        XCTAssertEqual(samples[4].value, 4.0)
        
        // Check remaining
        let stats3 = buffer.statistics()
        print("\nAfter reading 5:")
        print("  Used: \(stats3.used)")
        XCTAssertEqual(stats3.used, 5)
        
        print("\n✅ MetricBuffer basic test passed!")
    }
    
    func testMetricBufferOverflow() {
        // Small buffer for testing overflow
        let buffer = MetricBuffer(capacity: 4)
        
        // Fill buffer
        for i in 0..<4 {
            buffer.write(MetricDataPoint.gauge("metric", value: Double(i)))
        }
        
        var stats = buffer.statistics()
        print("\nBuffer full:")
        print("  Used: \(stats.used) / \(stats.capacity)")
        print("  Dropped: \(stats.droppedSamples)")
        XCTAssertEqual(stats.used, 4)
        XCTAssertEqual(stats.droppedSamples, 0)
        
        // Cause overflow
        buffer.write(MetricDataPoint.gauge("metric", value: 4.0))
        
        stats = buffer.statistics()
        print("\nAfter overflow:")
        print("  Used: \(stats.used) / \(stats.capacity)")
        print("  Dropped: \(stats.droppedSamples)")
        print("  Total writes: \(stats.totalWrites)")
        XCTAssertEqual(stats.used, 4)
        XCTAssertEqual(stats.droppedSamples, 1)
        XCTAssertEqual(stats.totalWrites, 5)
        
        // Read all - should get samples 1-4 (0 was dropped)
        let samples = buffer.readBatch()
        print("\nRead \(samples.count) samples after overflow")
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[0].value, 1.0) // First was dropped
        XCTAssertEqual(samples[3].value, 4.0) // Last is present
        
        print("\n✅ Overflow handling test passed!")
    }
}
*/
