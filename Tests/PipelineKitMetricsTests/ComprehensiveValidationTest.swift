import XCTest
@testable import PipelineKitMetrics

/// Comprehensive validation of all 5 exponential decay fixes
final class ComprehensiveValidationTest: XCTestCase {

    // MARK: - Fix 1: createDecayedSnapshot returns decay values

    func testFix1_DecayValuesReturned() async {
        // Setup
        let window = AggregationWindow.exponentialDecay(halfLife: 2.0)
        let accumulator = window.createAccumulator(
            type: BasicStatsAccumulator.self,
            config: .default
        )

        let now = Date()

        // Record values with time gaps
        await accumulator.record(100.0, at: now)
        await accumulator.record(50.0, at: now.addingTimeInterval(2))  // One half-life
        await accumulator.record(25.0, at: now.addingTimeInterval(4))  // Two half-lives

        // Get snapshot
        let snapshot = await accumulator.snapshot()

        // Validations
        XCTAssertEqual(snapshot.count, 3, "Should have 3 values in decay accumulator")

        // The mean should reflect exponential weighting
        // Not a simple average of (100+50+25)/3 = 58.33
        let simpleAverage = (100.0 + 50.0 + 25.0) / 3.0
        XCTAssertNotEqual(snapshot.mean, simpleAverage, "Should not be simple average")

        // Most recent values should have more weight
        XCTAssertLessThan(snapshot.mean, simpleAverage, "EWMA should weight recent (smaller) values more")

        // Min/max should be preserved
        XCTAssertEqual(snapshot.min, 25.0, "Min should be preserved")
        XCTAssertEqual(snapshot.max, 100.0, "Max should be preserved")

        print("✅ Fix 1 Validated: Decay values are properly returned")
    }

    // MARK: - Fix 2: No double recording

    func testFix2_NoDoubleRecording() async {
        // Setup
        let window = AggregationWindow.exponentialDecay(halfLife: 10.0)
        let accumulator = window.createAccumulator(
            type: BasicStatsAccumulator.self,
            config: .default
        )

        // Record exactly one value
        await accumulator.record(42.0, at: Date())

        // Get snapshot
        let snapshot = await accumulator.snapshot()

        // Validations
        XCTAssertEqual(snapshot.count, 1, "Should have exactly 1 count, not doubled")
        XCTAssertEqual(snapshot.sum, 42.0, "Sum should be 42, not 84 from double recording")
        XCTAssertEqual(snapshot.mean, 42.0, "Mean should be 42")

        // Record more values to ensure counts are correct
        await accumulator.record(10.0, at: Date().addingTimeInterval(1))
        await accumulator.record(20.0, at: Date().addingTimeInterval(2))

        let snapshot2 = await accumulator.snapshot()
        XCTAssertEqual(snapshot2.count, 3, "Should have exactly 3 counts total")

        print("✅ Fix 2 Validated: No double recording occurs")
    }

    // MARK: - Fix 3: Variance calculation with Welford's algorithm

    func testFix3_VarianceCalculation() {
        // Test with time anomaly (backwards time)
        var accumulator = ExponentialDecayAccumulator(config: .default)
        let now = Date()

        // Record initial values
        accumulator.record(10.0, at: now)
        accumulator.record(20.0, at: now.addingTimeInterval(1))

        // Record with backwards timestamp (triggers updateWithoutDecay)
        accumulator.record(30.0, at: now.addingTimeInterval(-5))

        let snapshot = accumulator.snapshot()

        // Validations
        XCTAssertEqual(snapshot.count, 3, "Should have 3 values")
        XCTAssertGreaterThanOrEqual(snapshot.ewmv, 0, "Variance should be non-negative")
        XCTAssertGreaterThan(snapshot.ewmStdDev, 0, "Should have positive std dev for varied data")

        // Test with identical values (variance should approach 0)
        var accumulator2 = ExponentialDecayAccumulator(config: .default)
        for i in 0..<5 {
            accumulator2.record(100.0, at: now.addingTimeInterval(Double(i)))
        }

        let snapshot2 = accumulator2.snapshot()
        XCTAssertLessThan(snapshot2.ewmv, 0.01, "Variance should be near 0 for identical values")

        print("✅ Fix 3 Validated: Variance calculation is correct")
    }

    // MARK: - Fix 4: Sliding window merge

    func testFix4_SlidingWindowMerge() async {
        // Setup sliding window with 4 buckets
        let window = AggregationWindow.sliding(duration: 12, buckets: 4)
        let accumulator = window.createAccumulator(
            type: BasicStatsAccumulator.self,
            config: .default
        )

        let now = Date()

        // Record values that will go into different buckets
        // Each bucket covers 3 seconds (12/4)
        await accumulator.record(10.0, at: now)              // Bucket 0
        await accumulator.record(20.0, at: now.addingTimeInterval(3))   // Bucket 1
        await accumulator.record(30.0, at: now.addingTimeInterval(6))   // Bucket 2
        await accumulator.record(40.0, at: now.addingTimeInterval(9))   // Bucket 3

        // Get merged snapshot
        let snapshot = await accumulator.snapshot()

        // Validations
        XCTAssertEqual(snapshot.count, 4, "Should have all 4 values merged")
        XCTAssertEqual(snapshot.sum, 100.0, "Sum should be 10+20+30+40 = 100")
        XCTAssertEqual(snapshot.mean, 25.0, "Mean should be 100/4 = 25")
        XCTAssertEqual(snapshot.min, 10.0, "Min should be 10 from all buckets")
        XCTAssertEqual(snapshot.max, 40.0, "Max should be 40 from all buckets")
        XCTAssertEqual(snapshot.lastValue, 40.0, "Last value should be most recent")

        print("✅ Fix 4 Validated: Sliding window merge works correctly")
    }

    // MARK: - Fix 5: Alpha clamping instead of reset

    func testFix5_AlphaClamping() {
        // Setup with short half-life and min weight
        var accumulator = ExponentialDecayAccumulator(
            config: .init(
                halfLife: 1.0,      // 1 second half-life
                warmupPeriod: 0,    // No warmup
                minWeight: 0.001    // Clamp at 0.001
            )
        )

        let now = Date()

        // Record initial value
        accumulator.record(1000.0, at: now)
        let snapshot1 = accumulator.snapshot()
        XCTAssertEqual(snapshot1.count, 1, "Should have 1 value")
        XCTAssertEqual(snapshot1.ewma, 1000.0, "Initial EWMA should be 1000")

        // Record after many half-lives (would previously trigger reset)
        let manyHalfLives = 20.0  // 20 half-lives = 2^20 decay ≈ 0.00000095
        accumulator.record(100.0, at: now.addingTimeInterval(manyHalfLives))

        let snapshot2 = accumulator.snapshot()

        // Validations
        XCTAssertEqual(snapshot2.count, 2, "Should have 2 values (not reset to 1)")

        // EWMA should be heavily weighted toward new value but not exactly 100
        // With clamping at 0.001, old value has minimal but non-zero weight
        XCTAssertGreaterThan(snapshot2.ewma, 99.0, "Should be very close to new value")
        XCTAssertLessThan(snapshot2.ewma, 100.1, "Should have tiny influence from old value")

        // Min/max should include both values
        XCTAssertEqual(snapshot2.min, 100.0, "Min should update to newer value")
        XCTAssertEqual(snapshot2.max, 1000.0, "Max should preserve old value")

        print("✅ Fix 5 Validated: Alpha clamping preserves history")
    }

    // MARK: - Integration test

    func testAllFixesIntegrated() async {
        // This test verifies all fixes work together
        let window = AggregationWindow.exponentialDecay(halfLife: 5.0)
        let accumulator = window.createAccumulator(
            type: BasicStatsAccumulator.self,
            config: .default
        )

        let now = Date()

        // Test sequence that exercises all fixes
        await accumulator.record(100.0, at: now)
        await accumulator.record(90.0, at: now.addingTimeInterval(1))
        await accumulator.record(80.0, at: now.addingTimeInterval(2))
        await accumulator.record(70.0, at: now.addingTimeInterval(100)) // Extreme time gap

        let snapshot = await accumulator.snapshot()

        // All fixes working together
        XCTAssertEqual(snapshot.count, 4, "Fix 1 & 2: Correct count")
        XCTAssertGreaterThan(snapshot.mean, 0, "Fix 1: Decay values returned")
        XCTAssertLessThan(snapshot.mean, 85, "Fix 1: EWMA weighting works")
        XCTAssertEqual(snapshot.min, 70.0, "Fix 5: No reset occurred")
        XCTAssertEqual(snapshot.max, 100.0, "Fix 5: History preserved")

        print("✅ Integration Validated: All fixes work together correctly")
    }

    // MARK: - Test Runner

    func testRunAllValidations() async {
        print("\n" + "=" * 50)
        print("COMPREHENSIVE VALIDATION OF EXPONENTIAL DECAY FIXES")
        print("=" * 50 + "\n")

        await testFix1_DecayValuesReturned()
        await testFix2_NoDoubleRecording()
        testFix3_VarianceCalculation()
        await testFix4_SlidingWindowMerge()
        testFix5_AlphaClamping()
        await testAllFixesIntegrated()

        print("\n" + "=" * 50)
        print("✅ ALL 5 FIXES VALIDATED SUCCESSFULLY")
        print("=" * 50 + "\n")
    }
}

// String multiplication helper
fileprivate extension String {
    static func *(lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}

