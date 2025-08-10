import XCTest
@testable import PipelineKitMetrics

/// Integration test to verify exponential decay values are properly returned
final class ExponentialDecayIntegrationTest: XCTestCase {

    func testExponentialDecayValuesAreReturned() async {
        // Create an exponential decay window
        let window = AggregationWindow.exponentialDecay(halfLife: 10.0)

        // Create a windowed accumulator with BasicStatsAccumulator
        let accumulator = window.createAccumulator(
            type: BasicStatsAccumulator.self,
            config: .default
        )

        let now = Date()

        // Record some values
        await accumulator.record(100.0, at: now)
        await accumulator.record(50.0, at: now.addingTimeInterval(1))
        await accumulator.record(25.0, at: now.addingTimeInterval(2))

        // Get the snapshot
        let snapshot = await accumulator.snapshot()

        // Verify we have data
        XCTAssertEqual(snapshot.count, 3, "Should have 3 values recorded")

        // The mean should be weighted towards recent values (not simple average)
        // Simple average would be (100 + 50 + 25) / 3 = 58.33
        // EWMA should be lower since recent values are smaller
        XCTAssertLessThan(snapshot.mean, 58.0, "EWMA should weight recent values more")

        // Verify min/max are preserved
        XCTAssertEqual(snapshot.min, 25.0, "Min should be 25")
        XCTAssertEqual(snapshot.max, 100.0, "Max should be 100")

        // Last value should be tracked
        XCTAssertEqual(snapshot.lastValue, 25.0, "Last value should be 25")
    }

    func testNoDoubleRecording() async {
        // Create an exponential decay window
        let window = AggregationWindow.exponentialDecay(halfLife: 5.0)

        // Create a windowed accumulator
        let accumulator = window.createAccumulator(
            type: BasicStatsAccumulator.self,
            config: .default
        )

        let now = Date()

        // Record a single value
        await accumulator.record(42.0, at: now)

        // Get the snapshot
        let snapshot = await accumulator.snapshot()

        // Should have exactly 1 count (not 2 from double recording)
        XCTAssertEqual(snapshot.count, 1, "Should have exactly 1 value, not double recorded")
        XCTAssertEqual(snapshot.sum, 42.0, "Sum should be 42, not doubled")
    }

    func testSlidingWindowMergeAggregates() async {
        // Create a sliding window with multiple buckets
        let window = AggregationWindow.sliding(duration: 10, buckets: 3)

        // Create a windowed accumulator
        let accumulator = window.createAccumulator(
            type: BasicStatsAccumulator.self,
            config: .default
        )

        let now = Date()

        // Record values across different buckets
        await accumulator.record(10.0, at: now)
        await accumulator.record(20.0, at: now.addingTimeInterval(4))  // Different bucket
        await accumulator.record(30.0, at: now.addingTimeInterval(8))  // Another bucket

        // Get the snapshot
        let snapshot = await accumulator.snapshot()

        // Should have all values aggregated
        XCTAssertEqual(snapshot.count, 3, "Should have all 3 values")
        XCTAssertEqual(snapshot.sum, 60.0, "Sum should be 60 (10+20+30)")
        XCTAssertEqual(snapshot.min, 10.0, "Min should be 10")
        XCTAssertEqual(snapshot.max, 30.0, "Max should be 30")
    }

    func testAlphaClamping() {
        // Test that alpha clamping preserves data
        var accumulator = ExponentialDecayAccumulator(
            config: .init(halfLife: 1.0, minWeight: 0.01)
        )

        let now = Date()

        // Record initial value
        accumulator.record(100.0, at: now)

        // Record value after many half-lives (would normally trigger reset)
        accumulator.record(50.0, at: now.addingTimeInterval(100))  // 100 seconds = 100 half-lives

        let snapshot = accumulator.snapshot()

        // Should have both values (not reset)
        XCTAssertEqual(snapshot.count, 2, "Should have 2 values, not reset")

        // EWMA should be heavily weighted to the new value but not exactly 50
        XCTAssertGreaterThan(snapshot.ewma, 49.0, "Should be close to new value")
        XCTAssertLessThan(snapshot.ewma, 51.0, "Should be close to new value")
    }
}

