import XCTest
@testable import PipelineKitObservability

final class AggregationTests: XCTestCase {
    func testCanonicalTagOrdering() throws {
        var aggregator = MetricAggregator(configuration: .init(enabled: true))
        _ = try aggregator.aggregate(.counter("test.metric", value: 2,
                                          tags: ["env": "prod", "region": "us-east"]), sampleRate: 1)
        _ = try aggregator.aggregate(.counter("test.metric", value: 3,
                                          tags: ["region": "us-east", "env": "prod"]), sampleRate: 1)
        let output = aggregator.flush()
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.snapshot.tags, ["env": "prod", "region": "us-east"])
        XCTAssertEqual(output.first?.snapshot.value ?? -1, 5, accuracy: 0.000_001)
    }

    func testCounterAggregation() async throws {
        let config = AggregationConfiguration(
            enabled: true,
            flushInterval: 60.0  // Long interval so it doesn't auto-flush
        )
        var aggregator = MetricAggregator(configuration: config)
        
        // Send multiple counter increments
        let snapshot1 = MetricSnapshot.counter("api.requests", value: 1.0)
        let snapshot2 = MetricSnapshot.counter("api.requests", value: 2.0)
        let snapshot3 = MetricSnapshot.counter("api.requests", value: 3.0)
        
        _ = try aggregator.aggregate(snapshot1, sampleRate: 1.0)
        _ = try aggregator.aggregate(snapshot2, sampleRate: 1.0)
        _ = try aggregator.aggregate(snapshot3, sampleRate: 1.0)
        
        // Flush and check aggregated value
        let results = aggregator.flush()
        XCTAssertEqual(results.count, 1)
        
        let (metric, rate) = results[0]
        XCTAssertEqual(metric.name, "api.requests")
        XCTAssertEqual(metric.type, "counter")
        XCTAssertEqual(metric.value, 6.0)  // 1 + 2 + 3
        XCTAssertEqual(rate, 1.0)
    }
    
    func testCounterScalingWithSampling() async throws {
        let config = AggregationConfiguration(enabled: true)
        var aggregator = MetricAggregator(configuration: config)
        
        // Counter with sampling rate < 1.0
        let snapshot = MetricSnapshot.counter("sampled.counter", value: 10.0)
        
        // With 0.1 sample rate, the value should be scaled by 10x
        _ = try aggregator.aggregate(snapshot, sampleRate: 0.1)
        
        let results = aggregator.flush()
        XCTAssertEqual(results.count, 1)
        
        let (metric, rate) = results[0]
        XCTAssertEqual(metric.value, 100.0)  // 10.0 / 0.1
        XCTAssertEqual(rate, 1.0)  // Always send with @1 after scaling
    }
    
    func testGaugeKeepsLatest() async throws {
        let config = AggregationConfiguration(enabled: true)
        var aggregator = MetricAggregator(configuration: config)
        
        // Send multiple gauge updates
        let snapshot1 = MetricSnapshot.gauge("memory.usage", value: 50.0)
        let snapshot2 = MetricSnapshot.gauge("memory.usage", value: 75.0)
        let snapshot3 = MetricSnapshot.gauge("memory.usage", value: 60.0)
        
        _ = try aggregator.aggregate(snapshot1, sampleRate: 1.0)
        _ = try aggregator.aggregate(snapshot2, sampleRate: 1.0)
        _ = try aggregator.aggregate(snapshot3, sampleRate: 1.0)
        
        // Flush and check latest value
        let results = aggregator.flush()
        XCTAssertEqual(results.count, 1)
        
        let (metric, _) = results[0]
        XCTAssertEqual(metric.name, "memory.usage")
        XCTAssertEqual(metric.type, "gauge")
        XCTAssertEqual(metric.value, 60.0)  // Latest value
    }
    
    func testTimerPreservesAllValues() async throws {
        let config = AggregationConfiguration(enabled: true)
        var aggregator = MetricAggregator(configuration: config)
        
        // Send multiple timer values
        let snapshot1 = MetricSnapshot.timer("api.latency", duration: 100.0)
        let snapshot2 = MetricSnapshot.timer("api.latency", duration: 150.0)
        let snapshot3 = MetricSnapshot.timer("api.latency", duration: 200.0)
        
        _ = try aggregator.aggregate(snapshot1, sampleRate: 1.0)
        _ = try aggregator.aggregate(snapshot2, sampleRate: 1.0)
        _ = try aggregator.aggregate(snapshot3, sampleRate: 1.0)
        
        // Flush and check all values preserved
        let results = aggregator.flush()
        XCTAssertEqual(results.count, 3)  // Each timer value sent separately
        
        let values = results.map { $0.snapshot.value! }.sorted()
        // Timer values are converted to milliseconds
        XCTAssertEqual(values, [100000.0, 150000.0, 200000.0])
    }
    
    func testMaxMetricsLimit() async throws {
        let config = AggregationConfiguration(
            enabled: true,
            maxUniqueMetrics: 3
        )
        var aggregator = MetricAggregator(configuration: config)
        
        // Try to add more than max metrics
        let success1 = try aggregator.aggregate(
            MetricSnapshot.counter("metric1"), sampleRate: 1.0
        )
        let success2 = try aggregator.aggregate(
            MetricSnapshot.counter("metric2"), sampleRate: 1.0
        )
        let success3 = try aggregator.aggregate(
            MetricSnapshot.counter("metric3"), sampleRate: 1.0
        )
        let success4 = try aggregator.aggregate(
            MetricSnapshot.counter("metric4"), sampleRate: 1.0
        )
        
        XCTAssertTrue(success1)
        XCTAssertTrue(success2)
        XCTAssertTrue(success3)
        XCTAssertFalse(success4)  // Should fail - buffer full
        
        // But updating existing metric should work
        let success5 = try aggregator.aggregate(
            MetricSnapshot.counter("metric1", value: 5.0), sampleRate: 1.0
        )
        XCTAssertTrue(success5)
    }
    
    func testMaxTotalValuesLimit() async throws {
        let config = AggregationConfiguration(
            enabled: true,
            maxTotalValues: 5
        )
        var aggregator = MetricAggregator(configuration: config)
        
        // Add timer values until we hit the limit
        _ = try aggregator.aggregate(
            MetricSnapshot.timer("timer1", duration: 1.0), sampleRate: 1.0
        )
        _ = try aggregator.aggregate(
            MetricSnapshot.timer("timer1", duration: 2.0), sampleRate: 1.0
        )
        _ = try aggregator.aggregate(
            MetricSnapshot.timer("timer2", duration: 3.0), sampleRate: 1.0
        )
        _ = try aggregator.aggregate(
            MetricSnapshot.timer("timer2", duration: 4.0), sampleRate: 1.0
        )
        
        // This should succeed (total = 4)
        let success1 = try aggregator.aggregate(
            MetricSnapshot.timer("timer2", duration: 5.0), sampleRate: 1.0
        )
        XCTAssertTrue(success1)
        
        // This should fail (would make total = 6)
        let success2 = try aggregator.aggregate(
            MetricSnapshot.timer("timer3", duration: 6.0), sampleRate: 1.0
        )
        XCTAssertFalse(success2)
    }
    
    func testFlushClearsBuffer() async throws {
        let config = AggregationConfiguration(enabled: true)
        var aggregator = MetricAggregator(configuration: config)
        
        // Add some metrics
        _ = try aggregator.aggregate(
            MetricSnapshot.counter("test.counter"), sampleRate: 1.0
        )
        
        // First flush should return metrics
        let results1 = aggregator.flush()
        XCTAssertEqual(results1.count, 1)
        
        // Second flush should return empty
        let results2 = aggregator.flush()
        XCTAssertEqual(results2.count, 0)
    }
    
    func testIntegrationWithExporter() async throws {
        // Use mock transport to avoid network operations
        let config = StatsDExporter.Configuration(
            aggregation: AggregationConfiguration(
                enabled: true,
                flushInterval: 60.0  // Long so we control flushing
            )
        )
        
        guard let (exporter, mockTransport) = await StatsDExporter.withMockTransport(configuration: config) else {
            XCTFail("Failed to create mock transport")
            return
        }
        
        // Record multiple counters
        await exporter.counter("requests", value: 1.0)
        await exporter.counter("requests", value: 2.0)
        await exporter.counter("requests", value: 3.0)
        
        // Record gauge updates
        await exporter.gauge("cpu.usage", value: 50.0)
        await exporter.gauge("cpu.usage", value: 75.0)
        
        // Force flush would trigger aggregation flush
        await exporter.forceFlush()
        
        // Verify metrics were sent
        let sentMetrics = await mockTransport.getMetricsAsStrings()
        XCTAssertEqual(sentMetrics.count, 2, "Should have 2 aggregated metrics")
        
        // Verify counter was aggregated (should be 6.0 = 1+2+3)
        let counterMetric = sentMetrics.first { $0.contains("requests") }
        XCTAssertNotNil(counterMetric)
        XCTAssertTrue(counterMetric?.contains("6.0") ?? false, "Counter should be aggregated to 6.0")
        
        // Verify gauge keeps latest value (75.0)
        let gaugeMetric = sentMetrics.first { $0.contains("cpu.usage") }
        XCTAssertNotNil(gaugeMetric)
        XCTAssertTrue(gaugeMetric?.contains("75.0") ?? false, "Gauge should keep latest value of 75.0")
    }
}
