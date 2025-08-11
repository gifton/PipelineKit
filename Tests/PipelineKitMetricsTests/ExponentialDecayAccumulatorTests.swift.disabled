import XCTest
@testable import PipelineKitMetrics

final class ExponentialDecayAccumulatorTests: XCTestCase {

    func testBasicAccumulation() {
        var accumulator = ExponentialDecayAccumulator(config: .default)
        let now = Date()

        // Record some values
        accumulator.record(10, at: now)
        accumulator.record(20, at: now.addingTimeInterval(1))
        accumulator.record(30, at: now.addingTimeInterval(2))

        let snapshot = accumulator.snapshot()

        XCTAssertEqual(snapshot.count, 3)
        XCTAssertGreaterThan(snapshot.ewma, 0)
        XCTAssertGreaterThanOrEqual(snapshot.ewmv, 0)
        XCTAssertEqual(snapshot.min, 10)
        XCTAssertEqual(snapshot.max, 30)
        XCTAssertEqual(snapshot.lastValue, 30)
    }

    func testDecayOverTime() {
        var accumulator = ExponentialDecayAccumulator(
            config: .init(halfLife: 1.0, warmupPeriod: 0)
        )
        let now = Date()

        // Record value at t=0
        accumulator.record(100, at: now)
        var snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot.ewma, 100, accuracy: 0.01)

        // Record value after half-life (should have ~50% weight)
        accumulator.record(0, at: now.addingTimeInterval(1.0))
        snapshot = accumulator.snapshot()

        // EWMA should be between original values due to decay
        XCTAssertLessThan(snapshot.ewma, 100)
        XCTAssertGreaterThan(snapshot.ewma, 0)
    }

    func testWarmupPeriod() {
        var accumulator = ExponentialDecayAccumulator(
            config: .init(halfLife: 10.0, warmupPeriod: 5.0)
        )
        let now = Date()

        // During warmup, no decay should occur
        accumulator.record(10, at: now)
        accumulator.record(20, at: now.addingTimeInterval(2))
        accumulator.record(30, at: now.addingTimeInterval(4))

        let snapshot = accumulator.snapshot()

        // Simple average during warmup
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertGreaterThan(snapshot.ewma, 15) // Should be close to average
    }

    func testTimeAnomalies() {
        var accumulator = ExponentialDecayAccumulator(config: .default)
        let now = Date()

        // Record normal value
        accumulator.record(50, at: now)

        // Record value with timestamp in the past (time went backwards)
        accumulator.record(60, at: now.addingTimeInterval(-10))

        // Should handle gracefully without crash
        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertGreaterThan(snapshot.ewma, 0)
    }

    func testReset() {
        var accumulator = ExponentialDecayAccumulator(config: .default)
        let now = Date()

        accumulator.record(100, at: now)
        accumulator.record(200, at: now.addingTimeInterval(1))

        accumulator.reset()

        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot.count, 0)
        XCTAssertEqual(snapshot.ewma, 0)
        XCTAssertEqual(snapshot.ewmv, 0)
    }

    func testConfidenceInterval() {
        var accumulator = ExponentialDecayAccumulator(config: .default)
        let now = Date()

        // Record values with some variance
        for i in 0..<10 {
            let value = 50.0 + Double(i % 3) * 10
            accumulator.record(value, at: now.addingTimeInterval(Double(i)))
        }

        let snapshot = accumulator.snapshot()
        let ci = snapshot.confidenceInterval

        // Confidence interval should contain the mean
        XCTAssertLessThan(ci.lower, snapshot.ewma)
        XCTAssertGreaterThan(ci.upper, snapshot.ewma)

        // Standard deviation should be positive
        XCTAssertGreaterThan(snapshot.ewmStdDev, 0)
    }

    func testFastConfig() {
        var accumulator = ExponentialDecayAccumulator(config: .fast)
        let now = Date()

        // Fast config should have shorter half-life
        accumulator.record(100, at: now)
        accumulator.record(0, at: now.addingTimeInterval(5)) // After one half-life

        let snapshot = accumulator.snapshot()

        // Value should decay significantly
        XCTAssertLessThan(snapshot.ewma, 75) // Should be closer to recent value
    }

    func testSlowConfig() {
        var accumulator = ExponentialDecayAccumulator(config: .slow)
        let now = Date()

        // Slow config should have longer half-life
        accumulator.record(100, at: now)
        accumulator.record(0, at: now.addingTimeInterval(60)) // Well within half-life

        let snapshot = accumulator.snapshot()

        // Value should decay slowly
        XCTAssertGreaterThan(snapshot.ewma, 25) // Should retain more of old value
    }

    func testWindowedAccumulatorIntegration() {
        let window = AggregationWindow.exponentialDecay(halfLife: 10)
        let accumulator = window.createAccumulator(
            type: BasicStatsAccumulator.self,
            config: .default
        )

        Task {
            let now = Date()
            await accumulator.record(10, at: now)
            await accumulator.record(20, at: now.addingTimeInterval(1))
            await accumulator.record(30, at: now.addingTimeInterval(2))

            let snapshot = await accumulator.snapshot()

            XCTAssertEqual(snapshot.count, 3)
            XCTAssertGreaterThan(snapshot.sum, 0)
        }
    }

    func testDecayRateConfig() {
        // Test creating config with specific decay rate
        let config = ExponentialDecayAccumulator.Config.withDecayRate(0.5)
        var accumulator = ExponentialDecayAccumulator(config: config)
        let now = Date()

        accumulator.record(100, at: now)
        accumulator.record(0, at: now.addingTimeInterval(1))

        let snapshot = accumulator.snapshot()
        XCTAssertGreaterThan(snapshot.ewma, 0)
        XCTAssertLessThan(snapshot.ewma, 100)
    }

    func testPercentileConfig() {
        // Test creating config for specific percentile
        let config = ExponentialDecayAccumulator.Config.forPercentile(0.95, window: 60)
        var accumulator = ExponentialDecayAccumulator(config: config)
        let now = Date()

        accumulator.record(100, at: now)

        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot.ewma, 100, accuracy: 0.01)
    }
}

