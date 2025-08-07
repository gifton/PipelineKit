import XCTest
@testable import PipelineKitCore

final class BatchedMetricsCollectorTests: XCTestCase {
    
    func testBatchingReducesUnderlyingCalls() async throws {
        // Create a mock collector that counts calls
        let mockCollector = CountingMetricsCollector()
        let batchedCollector = BatchedMetricsCollector(
            underlying: mockCollector,
            configuration: .init(
                maxBatchSize: 10,
                flushInterval: 10.0, // Long interval to prevent auto-flush
                coalesceDuplicates: false,
                aggregateCounters: false
            )
        )
        
        // Record 5 metrics (under batch size)
        for i in 0..<5 {
            await batchedCollector.recordCounter("test.counter", value: Double(i), tags: [:])
        }
        
        // Should not have flushed yet
        let callsBeforeFlush = await mockCollector.totalCalls
        XCTAssertEqual(callsBeforeFlush, 0)
        
        // Force flush
        await batchedCollector.flush()
        
        // Now should have 5 calls
        let callsAfterFlush = await mockCollector.totalCalls
        XCTAssertEqual(callsAfterFlush, 5)
    }
    
    func testAutoFlushOnBatchSize() async throws {
        let mockCollector = CountingMetricsCollector()
        let batchedCollector = BatchedMetricsCollector(
            underlying: mockCollector,
            configuration: .init(
                maxBatchSize: 5,
                flushInterval: 10.0,
                coalesceDuplicates: false,
                aggregateCounters: false,
                overflowPolicy: .flush
            )
        )
        
        // Record exactly batch size metrics
        for i in 0..<5 {
            await batchedCollector.recordGauge("test.gauge", value: Double(i), tags: [:])
        }
        
        // Should have auto-flushed
        let calls = await mockCollector.totalCalls
        XCTAssertEqual(calls, 5)
    }
    
    func testCounterAggregation() async throws {
        let mockCollector = CountingMetricsCollector()
        let batchedCollector = BatchedMetricsCollector(
            underlying: mockCollector,
            configuration: .init(
                maxBatchSize: 100,
                flushInterval: 10.0,
                coalesceDuplicates: false,
                aggregateCounters: true
            )
        )
        
        // Record same counter multiple times
        for _ in 0..<10 {
            await batchedCollector.recordCounter("test.counter", value: 1.0, tags: ["env": "test"])
        }
        
        // Flush
        await batchedCollector.flush()
        
        // Should have only 1 call with aggregated value
        let calls = await mockCollector.totalCalls
        XCTAssertEqual(calls, 1)
        
        let metrics = await mockCollector.getMetrics()
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.value, 10.0) // Aggregated value
    }
    
    func testGaugeCoalescing() async throws {
        let mockCollector = StandardMetricsCollector()
        let batchedCollector = BatchedMetricsCollector(
            underlying: mockCollector,
            configuration: .init(
                maxBatchSize: 100,
                flushInterval: 10.0,
                coalesceDuplicates: true,
                aggregateCounters: false
            )
        )
        
        // Record same gauge multiple times with different values
        await batchedCollector.recordGauge("test.gauge", value: 1.0, tags: ["env": "test"])
        await batchedCollector.recordGauge("test.gauge", value: 2.0, tags: ["env": "test"])
        await batchedCollector.recordGauge("test.gauge", value: 3.0, tags: ["env": "test"])
        
        // Flush
        await batchedCollector.flush()
        
        // Should only have the latest gauge value
        let metrics = await mockCollector.getMetrics()
        let gaugeMetrics = metrics.filter { $0.name == "test.gauge" && $0.type == .gauge }
        XCTAssertEqual(gaugeMetrics.count, 1)
        XCTAssertEqual(gaugeMetrics.first?.value, 3.0) // Latest value
    }
    
    func testHistogramPreservation() async throws {
        let mockCollector = StandardMetricsCollector()
        let batchedCollector = BatchedMetricsCollector(
            underlying: mockCollector,
            configuration: .init(
                maxBatchSize: 100,
                flushInterval: 10.0,
                coalesceDuplicates: true,
                aggregateCounters: false
            )
        )
        
        // Record multiple histogram values
        let values = [1.0, 2.0, 3.0, 4.0, 5.0]
        for value in values {
            await batchedCollector.recordHistogram("test.histogram", value: value, tags: ["env": "test"])
        }
        
        // Flush
        await batchedCollector.flush()
        
        // Should preserve all histogram values
        let metrics = await mockCollector.getMetrics()
        let histogramMetrics = metrics.filter { $0.name == "test.histogram" && $0.type == .histogram }
        XCTAssertEqual(histogramMetrics.count, 5)
        XCTAssertEqual(Set(histogramMetrics.map { $0.value }), Set(values))
    }
    
    func testOverflowPolicyDropOldest() async throws {
        let mockCollector = CountingMetricsCollector()
        let batchedCollector = BatchedMetricsCollector(
            underlying: mockCollector,
            configuration: .init(
                maxBatchSize: 3,
                flushInterval: 10.0,
                coalesceDuplicates: false,
                aggregateCounters: false,
                overflowPolicy: .dropOldest
            )
        )
        
        // Record more than batch size
        for i in 0..<5 {
            await batchedCollector.recordGauge("test.gauge", value: Double(i), tags: [:])
        }
        
        // Should still be buffering (not flushed)
        let callsBeforeFlush = await mockCollector.totalCalls
        XCTAssertEqual(callsBeforeFlush, 0)
        
        // Flush
        await batchedCollector.flush()
        
        // Should have only the last 3 metrics
        let metrics = await mockCollector.getMetrics()
        XCTAssertEqual(metrics.count, 3)
        let values = metrics.map { $0.value }.sorted()
        XCTAssertEqual(values, [2.0, 3.0, 4.0]) // Oldest (0, 1) dropped
    }
    
    func testTimeBasedAutoFlush() async throws {
        let mockCollector = CountingMetricsCollector()
        let batchedCollector = BatchedMetricsCollector(
            underlying: mockCollector,
            configuration: .init(
                maxBatchSize: 100,
                flushInterval: 0.1, // 100ms
                coalesceDuplicates: false,
                aggregateCounters: false
            )
        )
        
        // Record a metric
        await batchedCollector.recordCounter("test.counter", value: 1.0, tags: [:])
        
        // Wait for auto-flush
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Should have auto-flushed
        let calls = await mockCollector.totalCalls
        XCTAssertGreaterThan(calls, 0)
    }
}

// MARK: - Mock Collector for Testing

actor CountingMetricsCollector: MetricsCollector {
    private var callCount = 0
    private var metrics: [MetricDataPoint] = []
    
    var totalCalls: Int {
        callCount
    }
    
    func recordCounter(_ name: String, value: Double, tags: [String: String]) async {
        callCount += 1
        metrics.append(MetricDataPoint(name: name, value: value, type: .counter, tags: tags))
    }
    
    func recordGauge(_ name: String, value: Double, tags: [String: String]) async {
        callCount += 1
        metrics.append(MetricDataPoint(name: name, value: value, type: .gauge, tags: tags))
    }
    
    func recordHistogram(_ name: String, value: Double, tags: [String: String]) async {
        callCount += 1
        metrics.append(MetricDataPoint(name: name, value: value, type: .histogram, tags: tags))
    }
    
    func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        callCount += 1
        metrics.append(MetricDataPoint(name: name, value: duration * 1000, type: .timer, tags: tags))
    }
    
    func getMetrics() async -> [MetricDataPoint] {
        metrics
    }
    
    func reset() async {
        callCount = 0
        metrics.removeAll()
    }
}