import XCTest
@testable import PipelineKit
import PipelineKitTestSupport
@testable import StressTesting

// NOTE: These tests require PipelineKitStressTest types which have been
// moved to a separate package. They should be moved to that package's test suite.
final class MetricCollectorTests: XCTestCase {
    func testPlaceholder() {
        // Placeholder test to prevent empty test class
        XCTAssertTrue(true)
    }
}

/*
import Foundation

/// Tests for MetricCollector.
final class MetricCollectorTests: XCTestCase {
    
    func testBasicCollection() async throws {
        // Create collector with fast collection interval
        let config = MetricCollector.Configuration(
            collectionInterval: 0.1, // 100ms
            batchSize: 100
        )
        let collector = MetricCollector(configuration: config)
        
        // Start collection
        await collector.start()
        
        // Record some metrics
        await collector.record(.gauge("test.gauge", value: 42.0))
        await collector.record(.counter("test.counter", value: 1.0))
        await collector.record(.gauge("test.gauge", value: 43.0))
        
        // Wait for collection cycle
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Check statistics
        let stats = await collector.statistics()
        XCTAssertEqual(stats.state, .collecting)
        XCTAssertGreaterThan(stats.totalCollected, 0)
        XCTAssertNotNil(stats.lastCollectionTime)
        
        // Stop collector
        await collector.stop()
    }
    
    func testMetricStream() async throws {
        let collector = MetricCollector()
        await collector.start()
        
        // Start consuming stream
        let expectation = expectation(description: "Received metrics")
        var receivedMetrics: [MetricDataPoint] = []
        
        let streamTask = Task {
            for await metric in await collector.stream() {
                receivedMetrics.append(metric)
                if receivedMetrics.count >= 3 {
                    expectation.fulfill()
                    break
                }
            }
        }
        
        // Record metrics
        await collector.record(.gauge("stream.test", value: 1.0))
        await collector.record(.gauge("stream.test", value: 2.0))
        await collector.record(.gauge("stream.test", value: 3.0))
        
        // Force collection
        await collector.collect()
        
        // Wait for stream to receive metrics
        await fulfillment(of: [expectation], timeout: 2.0)
        
        XCTAssertEqual(receivedMetrics.count, 3)
        XCTAssertEqual(receivedMetrics[0].value, 1.0)
        XCTAssertEqual(receivedMetrics[1].value, 2.0)
        XCTAssertEqual(receivedMetrics[2].value, 3.0)
        
        streamTask.cancel()
        await collector.stop()
    }
    
    func testBatchRecording() async throws {
        let collector = MetricCollector()
        
        // Create batch of metrics
        let batch = [
            MetricDataPoint.gauge("batch.gauge", value: 1.0),
            MetricDataPoint.counter("batch.counter", value: 10.0),
            MetricDataPoint.gauge("batch.gauge", value: 2.0),
            MetricDataPoint.counter("batch.counter", value: 20.0),
            MetricDataPoint.histogram("batch.histogram", value: 100.0)
        ]
        
        // Record batch
        await collector.recordBatch(batch)
        
        // Collect and verify
        await collector.start()
        await collector.collect()
        
        let stats = await collector.statistics()
        XCTAssertEqual(stats.totalCollected, 5)
        
        // Check buffer statistics
        XCTAssertEqual(stats.bufferStatistics.count, 3) // 3 unique metrics
        
        await collector.stop()
    }
    
    func testCollectorState() async throws {
        let collector = MetricCollector()
        
        // Initial state
        var stats = await collector.statistics()
        XCTAssertEqual(stats.state, .idle)
        
        // Start
        await collector.start()
        stats = await collector.statistics()
        XCTAssertEqual(stats.state, .collecting)
        
        // Stop
        await collector.stop()
        stats = await collector.statistics()
        XCTAssertEqual(stats.state, .stopped)
    }
    
    func testAutoStart() async throws {
        let config = MetricCollector.Configuration(autoStart: true)
        let collector = MetricCollector(configuration: config)
        
        // Give it time to auto-start
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        let stats = await collector.statistics()
        XCTAssertEqual(stats.state, .collecting)
        
        await collector.stop()
    }
    
    func testExporter() async throws {
        // Create mock exporter
        let exporter = MockExporter()
        
        let collector = MetricCollector()
        await collector.addExporter(exporter)
        await collector.start()
        
        // Record metrics
        await collector.record(.gauge("export.test", value: 99.0))
        await collector.collect()
        
        // Check exporter received metrics
        let exported = await exporter.exportedMetrics
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported[0].value, 99.0)
        
        await collector.stop()
    }
}

// MARK: - Mock Exporter

actor MockExporter: MetricExporter {
    private(set) var exportedMetrics: [MetricDataPoint] = []
    
    func export(_ sample: MetricDataPoint) async {
        exportedMetrics.append(sample)
    }
    
    func flush() async {
        // No-op for mock
    }
}
*/
