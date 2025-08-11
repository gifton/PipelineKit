import XCTest
@testable import PipelineKitMetrics

final class DecayConvertibleTests: XCTestCase {
    
    // MARK: - Test Basic Stats Conversion
    
    func testBasicStatsConversion() {
        // Given
        let decay = ExponentialDecayAccumulator.Snapshot(
            count: 100,
            ewma: 50.0,
            ewmv: 25.0,
            min: 10.0,
            max: 90.0,
            lastValue: 55.0,
            lastTimestamp: Date(),
            effectiveWeight: 80.0
        )
        
        // When
        let converted = BasicStatsAccumulator.Snapshot.fromDecay(decay)
        
        // Then
        XCTAssertEqual(converted.count, 100)
        XCTAssertEqual(converted.sum, 50.0 * 80.0) // ewma * effectiveWeight
        XCTAssertEqual(converted.min, 10.0)
        XCTAssertEqual(converted.max, 90.0)
        XCTAssertEqual(converted.lastValue, 55.0)
        XCTAssertNotNil(converted.lastTimestamp)
        XCTAssertNil(converted.firstValue) // Not tracked in decay
        XCTAssertNil(converted.firstTimestamp) // Not tracked in decay
    }
    
    // MARK: - Test Counter Conversion
    
    func testCounterConversion() {
        // Given
        let decay = ExponentialDecayAccumulator.Snapshot(
            count: 50,
            ewma: 100.0,
            ewmv: 10.0,
            min: 1.0,
            max: 200.0,
            lastValue: 150.0,
            lastTimestamp: Date(),
            effectiveWeight: 40.0
        )
        
        // When
        let converted = CounterAccumulator.Snapshot.fromDecay(decay)
        
        // Then
        XCTAssertEqual(converted.count, 50)
        XCTAssertEqual(converted.sum, 100.0 * 40.0) // ewma * effectiveWeight
        XCTAssertEqual(converted.firstValue, 1.0) // Uses min as first value
        XCTAssertEqual(converted.lastValue, 150.0)
        XCTAssertNotNil(converted.lastTimestamp)
        XCTAssertEqual(converted.firstTimestamp, converted.lastTimestamp) // Same timestamp
    }
    
    // MARK: - Test Histogram Conversion
    
    func testHistogramConversion() {
        // Given
        let decay = ExponentialDecayAccumulator.Snapshot(
            count: 90,
            ewma: 45.0,
            ewmv: 20.0,
            min: 5.0,
            max: 85.0,
            lastValue: 50.0,
            lastTimestamp: Date(),
            effectiveWeight: 75.0
        )
        
        // When
        let converted = HistogramAccumulator.Snapshot.fromDecay(decay)
        
        // Then
        XCTAssertEqual(converted.count, 90)
        XCTAssertEqual(converted.sum, 45.0 * 75.0) // ewma * effectiveWeight
        XCTAssertEqual(converted.min, 5.0)
        XCTAssertEqual(converted.max, 85.0)
        XCTAssertEqual(converted.mean, 45.0)
        XCTAssertTrue(converted.percentiles.isEmpty) // Can't reconstruct percentiles
        
        // Check bucket distribution
        XCTAssertFalse(converted.buckets.isEmpty)
        let totalInBuckets = converted.buckets.values.reduce(0, +)
        XCTAssertEqual(totalInBuckets, 90) // All counts accounted for
        
        // Check that min, mean, and max are represented
        XCTAssertNotNil(converted.buckets[5.0])  // min
        XCTAssertNotNil(converted.buckets[45.0]) // mean (ewma)
        XCTAssertNotNil(converted.buckets[85.0]) // max
    }
    
    // MARK: - Test Empty Decay Conversion
    
    func testEmptyDecayConversion() {
        // Given
        let decay = ExponentialDecayAccumulator.Snapshot(
            count: 0,
            ewma: 0.0,
            ewmv: 0.0,
            min: Double.infinity,
            max: -Double.infinity,
            lastValue: 0.0,
            lastTimestamp: Date(),
            effectiveWeight: 0.0
        )
        
        // When
        let basicStats = BasicStatsAccumulator.Snapshot.fromDecay(decay)
        let counter = CounterAccumulator.Snapshot.fromDecay(decay)
        let histogram = HistogramAccumulator.Snapshot.fromDecay(decay)
        
        // Then
        XCTAssertEqual(basicStats.count, 0)
        XCTAssertEqual(basicStats.sum, 0.0)
        
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(counter.sum, 0.0)
        
        XCTAssertEqual(histogram.count, 0)
        XCTAssertEqual(histogram.sum, 0.0)
        XCTAssertTrue(histogram.buckets.isEmpty) // No buckets for empty data
    }
    
    // MARK: - Test Integration with WindowedAccumulator
    
    func testWindowedAccumulatorIntegration() async {
        // Given
        let window = AggregationWindow.exponentialDecay(
            halfLife: 60,
            warmupSamples: 5
        )
        
        var accumulator = WindowedAccumulator(
            window: window,
            accumulator: BasicStatsAccumulator(config: .default)
        )
        
        // When - Record some values
        let now = Date()
        accumulator.record(10.0, at: now)
        accumulator.record(20.0, at: now.addingTimeInterval(1))
        accumulator.record(30.0, at: now.addingTimeInterval(2))
        accumulator.record(40.0, at: now.addingTimeInterval(3))
        accumulator.record(50.0, at: now.addingTimeInterval(4))
        
        // Then - Get snapshot (should use decay conversion)
        let snapshot = accumulator.snapshot()
        
        // Verify it's a valid snapshot
        XCTAssertGreaterThan(snapshot.count, 0)
        XCTAssertGreaterThan(snapshot.sum, 0)
        XCTAssertLessThanOrEqual(snapshot.min, 10.0)
        XCTAssertGreaterThanOrEqual(snapshot.max, 50.0)
    }
    
    // MARK: - Test Different Accumulator Types
    
    func testDifferentAccumulatorTypes() async {
        // Test that each accumulator type can use decay conversion
        let decay = ExponentialDecayAccumulator.Snapshot(
            count: 10,
            ewma: 25.0,
            ewmv: 5.0,
            min: 10.0,
            max: 40.0,
            lastValue: 30.0,
            lastTimestamp: Date(),
            effectiveWeight: 8.0
        )
        
        // Test with Counter
        let counterWindow = AggregationWindow.exponentialDecay(halfLife: 60)
        var counterAccum = WindowedAccumulator(
            window: counterWindow,
            accumulator: CounterAccumulator(config: .default)
        )
        counterAccum.record(10.0, at: Date())
        let counterSnapshot = counterAccum.snapshot()
        XCTAssertNotNil(counterSnapshot)
        
        // Test with Histogram
        let histWindow = AggregationWindow.exponentialDecay(halfLife: 60)
        var histAccum = WindowedAccumulator(
            window: histWindow,
            accumulator: HistogramAccumulator(config: .default)
        )
        histAccum.record(10.0, at: Date())
        let histSnapshot = histAccum.snapshot()
        XCTAssertNotNil(histSnapshot)
    }
}