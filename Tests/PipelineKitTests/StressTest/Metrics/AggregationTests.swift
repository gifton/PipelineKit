import XCTest
@testable import PipelineKit

final class AggregationTests: XCTestCase {
    
    // MARK: - StatisticsAccumulator Tests
    
    func testGaugeAccumulator() {
        var accumulator = GaugeAccumulator()
        
        // Test empty state
        XCTAssertTrue(accumulator.isEmpty)
        XCTAssertEqual(accumulator.sampleCount, 0)
        
        // Add values
        let now = Date()
        accumulator.add(10.0, at: now)
        accumulator.add(20.0, at: now.addingTimeInterval(1))
        accumulator.add(5.0, at: now.addingTimeInterval(2))
        accumulator.add(15.0, at: now.addingTimeInterval(3))
        
        // Verify statistics
        let stats = accumulator.statistics()
        XCTAssertEqual(stats.count, 4)
        XCTAssertEqual(stats.min, 5.0)
        XCTAssertEqual(stats.max, 20.0)
        XCTAssertEqual(stats.sum, 50.0)
        XCTAssertEqual(stats.mean, 12.5)
        XCTAssertEqual(stats.lastValue, 15.0)
        XCTAssertEqual(stats.range, 15.0)
        
        // Test reset
        accumulator.reset()
        XCTAssertTrue(accumulator.isEmpty)
    }
    
    func testCounterAccumulator() {
        var accumulator = CounterAccumulator()
        
        // Add monotonically increasing values
        let now = Date()
        accumulator.add(100.0, at: now)
        accumulator.add(150.0, at: now.addingTimeInterval(1))
        accumulator.add(200.0, at: now.addingTimeInterval(2))
        accumulator.add(300.0, at: now.addingTimeInterval(3))
        
        // Verify statistics
        let stats = accumulator.statistics()
        XCTAssertEqual(stats.count, 4)
        XCTAssertEqual(stats.firstValue, 100.0)
        XCTAssertEqual(stats.lastValue, 300.0)
        XCTAssertEqual(stats.increase, 200.0)
        XCTAssertEqual(stats.rate, 200.0 / 3.0, accuracy: 0.001) // 200 increase over 3 seconds
        
        // Test validation
        XCTAssertTrue(accumulator.isValidValue(350.0))
        XCTAssertFalse(accumulator.isValidValue(250.0)) // Decreasing value
    }
    
    func testHistogramAccumulator() {
        var accumulator = HistogramAccumulator(reservoirSize: 10)
        
        // Add values
        let now = Date()
        for i in 1...100 {
            accumulator.add(Double(i), at: now.addingTimeInterval(Double(i)))
        }
        
        // Verify basic statistics
        let stats = accumulator.statistics()
        XCTAssertEqual(stats.count, 100)
        XCTAssertEqual(stats.min, 1.0)
        XCTAssertEqual(stats.max, 100.0)
        XCTAssertEqual(stats.sum, 5050.0) // Sum of 1..100
        XCTAssertEqual(stats.mean, 50.5)
        
        // Percentiles should be approximate due to reservoir sampling
        XCTAssertGreaterThan(stats.p50, 40.0)
        XCTAssertLessThan(stats.p50, 60.0)
        XCTAssertGreaterThan(stats.p99, 90.0)
    }
    
    func testHistogramBuckets() {
        var accumulator = HistogramAccumulator()
        
        // Add values
        let now = Date()
        for i in 0..<100 {
            accumulator.add(Double(i), at: now)
        }
        
        // Get buckets
        let buckets = accumulator.buckets(count: 10)
        XCTAssertEqual(buckets.count, 10)
        
        // Verify bucket properties
        for (i, bucket) in buckets.enumerated() {
            if i == 0 {
                XCTAssertEqual(bucket.lowerBound, 0.0, accuracy: 0.01)
            }
            if i == buckets.count - 1 {
                XCTAssertEqual(bucket.upperBound, 99.0, accuracy: 0.01)
            }
            
            // Each bucket should have ~10% of values
            XCTAssertGreaterThan(bucket.percentage, 5.0)
            XCTAssertLessThan(bucket.percentage, 15.0)
        }
    }
    
    // MARK: - Time Window Tests
    
    func testTimeWindow() {
        let now = Date()
        let window = TimeWindow(duration: 60, startTime: now)
        
        XCTAssertEqual(window.duration, 60)
        XCTAssertEqual(window.startTime, now)
        XCTAssertEqual(window.endTime, now.addingTimeInterval(60))
        
        // Test contains
        XCTAssertTrue(window.contains(now))
        XCTAssertTrue(window.contains(now.addingTimeInterval(30)))
        XCTAssertTrue(window.contains(now.addingTimeInterval(59.9)))
        XCTAssertFalse(window.contains(now.addingTimeInterval(-1)))
        XCTAssertFalse(window.contains(now.addingTimeInterval(60)))
        
        // Test next window
        let nextWindow = window.next()
        XCTAssertEqual(nextWindow.startTime, window.endTime)
        XCTAssertEqual(nextWindow.duration, window.duration)
    }
    
    func testTimeWindowFactory() {
        let now = Date()
        let window = TimeWindow.ending(at: now, duration: 300)
        
        XCTAssertEqual(window.endTime, now)
        XCTAssertEqual(window.startTime, now.addingTimeInterval(-300))
        XCTAssertEqual(window.duration, 300)
    }
    
    // MARK: - MetricQuery Tests
    
    func testMetricQuery() {
        let query = MetricQuery(
            namePattern: "cpu.*",
            timeRange: Date()...Date().addingTimeInterval(3600),
            windows: [60, 300]
        )
        
        // Test pattern matching
        XCTAssertTrue(query.matches(name: "cpu.usage"))
        XCTAssertTrue(query.matches(name: "cpu.temperature"))
        XCTAssertFalse(query.matches(name: "memory.usage"))
        
        // Test wildcard
        let wildcardQuery = MetricQuery(
            namePattern: "*",
            timeRange: Date()...Date()
        )
        XCTAssertTrue(wildcardQuery.matches(name: "anything"))
    }
    
    // MARK: - Integration Tests
    
    func testMetricAggregatorIntegration() async {
        let aggregator = MetricAggregator(
            configuration: MetricAggregator.Configuration(
                windows: [60, 300],
                autoStart: true
            )
        )
        
        await aggregator.start()
        
        // Add various metric types
        let now = Date()
        for i in 0..<10 {
            await aggregator.add(.gauge("cpu.usage", value: Double(50 + i * 5)))
            await aggregator.add(.counter("requests.total", value: Double(100 + i * 10)))
            await aggregator.add(.histogram("response.time", value: Double(100 + i * 20)))
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        
        // Query metrics
        let query = MetricQuery(
            namePattern: "*",
            timeRange: now...Date(),
            windows: [60]
        )
        
        let result = await aggregator.query(query)
        XCTAssertGreaterThan(result.metrics.count, 0)
        
        // Verify we have all metric types
        let metricNames = Set(result.metrics.map { $0.name })
        XCTAssertTrue(metricNames.contains("cpu.usage"))
        XCTAssertTrue(metricNames.contains("requests.total"))
        XCTAssertTrue(metricNames.contains("response.time"))
        
        // Test convenience methods
        let gaugeValue = await aggregator.latestGauge("cpu.usage")
        XCTAssertNotNil(gaugeValue)
        
        let counterRate = await aggregator.counterRate("requests.total")
        XCTAssertNotNil(counterRate)
        
        let percentiles = await aggregator.histogramPercentiles("response.time")
        XCTAssertNotNil(percentiles)
        
        // Check statistics
        let stats = await aggregator.statistics()
        XCTAssertTrue(stats.isRunning)
        XCTAssertGreaterThan(stats.totalProcessed, 0)
        XCTAssertGreaterThan(stats.metricCount, 0)
        
        await aggregator.stop()
    }
    
    func testMetricCollectorWithAggregation() async {
        let collector = MetricCollector(
            configuration: MetricCollector.Configuration(
                collectionInterval: 0.1,
                autoStart: true
            )
        )
        
        await collector.start()
        
        // Record metrics
        for i in 0..<5 {
            await collector.record(.gauge("test.gauge", value: Double(i)))
            await collector.record(.counter("test.counter", value: Double(i * 10)))
        }
        
        // Wait for collection
        try? await Task.sleep(nanoseconds: 200_000_000)
        
        // Query through collector
        let query = MetricQuery(
            namePattern: "test.*",
            timeRange: Date().addingTimeInterval(-60)...Date(),
            windows: [60]
        )
        
        let result = await collector.query(query)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!.metrics.count, 0)
        
        await collector.stop()
    }
    
    // MARK: - Performance Tests
    
    func testAggregationPerformance() async {
        let aggregator = MetricAggregator()
        await aggregator.start()
        
        measure {
            let expectation = self.expectation(description: "Performance test")
            
            Task {
                // Add 10,000 metrics
                for i in 0..<10_000 {
                    await aggregator.add(.gauge("perf.test", value: Double(i)))
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 10.0)
        }
        
        await aggregator.stop()
    }
}