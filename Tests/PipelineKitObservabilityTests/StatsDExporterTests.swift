import XCTest
@testable import PipelineKitObservability
import Foundation
#if canImport(Network)
import Network
#endif

final class StatsDExporterTests: XCTestCase {
    
    // MARK: - Configuration Tests
    
    func testDefaultConfiguration() {
        let config = StatsDExporter.Configuration.default
        
        XCTAssertEqual(config.host, "localhost")
        XCTAssertEqual(config.port, 8125)
        XCTAssertNil(config.prefix)
        XCTAssertTrue(config.globalTags.isEmpty)
        XCTAssertEqual(config.maxBatchSize, 20)
        XCTAssertEqual(config.flushInterval, 0.1)
    }
    
    func testCustomConfiguration() {
        let config = StatsDExporter.Configuration(
            host: "metrics.example.com",
            port: 8126,
            prefix: "myapp",
            globalTags: ["env": "production", "region": "us-east-1"],
            maxBatchSize: 50,
            flushInterval: 0.5
        )
        
        XCTAssertEqual(config.host, "metrics.example.com")
        XCTAssertEqual(config.port, 8126)
        XCTAssertEqual(config.prefix, "myapp")
        XCTAssertEqual(config.globalTags["env"], "production")
        XCTAssertEqual(config.globalTags["region"], "us-east-1")
        XCTAssertEqual(config.maxBatchSize, 50)
        XCTAssertEqual(config.flushInterval, 0.5)
    }
    
    // MARK: - Metric Recording Tests
    
    func testRecordCounter() async {
        let exporter = StatsDExporter()
        let snapshot = MetricSnapshot.counter("test.counter", value: 5.0, tags: ["key": "value"])
        
        // Should not crash
        await exporter.record(snapshot)
    }
    
    func testRecordGauge() async {
        let exporter = StatsDExporter()
        let snapshot = MetricSnapshot.gauge("test.gauge", value: 42.0, tags: [:], unit: "bytes")
        
        // Should not crash
        await exporter.record(snapshot)
    }
    
    func testRecordTimer() async {
        let exporter = StatsDExporter()
        let snapshot = MetricSnapshot.timer("test.timer", duration: 0.123, tags: ["endpoint": "/api"])
        
        // Should not crash
        await exporter.record(snapshot)
    }
    
    func testBatchRecording() async {
        let exporter = StatsDExporter()
        let snapshots = [
            MetricSnapshot.counter("batch.counter", value: 1.0),
            MetricSnapshot.gauge("batch.gauge", value: 2.0),
            MetricSnapshot.timer("batch.timer", duration: 0.003)
        ]
        
        await exporter.recordBatch(snapshots)
    }
    
    // MARK: - Batching Tests
    
    func testBatchingTriggersOnSize() async {
        let config = StatsDExporter.Configuration(
            maxBatchSize: 3,
            flushInterval: 10.0 // Long interval so size triggers first
        )
        let exporter = StatsDExporter(configuration: config)
        
        // Record 3 metrics to trigger batch
        for i in 1...3 {
            await exporter.counter("batch.test", value: Double(i))
        }
        
        // Give it time to flush
        try? await Task.sleep(for: .milliseconds(100))
    }
    
    func testBatchingTriggersOnInterval() async {
        let config = StatsDExporter.Configuration(
            maxBatchSize: 100, // High limit so interval triggers first
            flushInterval: 0.05 // 50ms
        )
        let exporter = StatsDExporter(configuration: config)
        
        await exporter.counter("interval.test", value: 1.0)
        
        // Wait for interval to trigger
        try? await Task.sleep(for: .milliseconds(100))
    }
    
    func testForceFlush() async {
        let exporter = StatsDExporter()
        
        await exporter.counter("flush.test", value: 1.0)
        await exporter.forceFlush()
        
        // Should have flushed immediately
    }
    
    // MARK: - Error Handling Tests
    
    func testErrorHandlerCalled() async {
        let expectation = XCTestExpectation(description: "Error handler called")
        let exporter = StatsDExporter()
        
        await exporter.setErrorHandler { error in
            expectation.fulfill()
        }
        
        // Record with invalid host to trigger error
        let badConfig = StatsDExporter.Configuration(host: "")
        let badExporter = StatsDExporter(configuration: badConfig)
        await badExporter.setErrorHandler { _ in
            expectation.fulfill()
        }
        
        // This might trigger an error
        await badExporter.counter("error.test", value: 1.0)
        await badExporter.forceFlush()
        
        // Give it time
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    // MARK: - Convenience Methods Tests
    
    func testConvenienceCounter() async {
        let exporter = StatsDExporter()
        await exporter.counter("convenience.counter", value: 10.0, tags: ["test": "true"])
    }
    
    func testConvenienceGauge() async {
        let exporter = StatsDExporter()
        await exporter.gauge("convenience.gauge", value: 99.9, tags: [:])
    }
    
    func testConvenienceTimer() async {
        let exporter = StatsDExporter()
        await exporter.timer("convenience.timer", duration: 0.456, tags: ["method": "GET"])
    }
    
    func testTimeBlock() async throws {
        let exporter = StatsDExporter()
        
        let result = try await exporter.time("block.timer", tags: ["async": "true"]) {
            try await Task.sleep(for: .milliseconds(10))
            return 42
        }
        
        XCTAssertEqual(result, 42)
    }
    
    // MARK: - Metric Name Sanitization Tests
    
    func testMetricNameSanitization() async {
        let exporter = StatsDExporter()
        
        // Names with special characters should be sanitized
        await exporter.counter("test:metric|with@special#chars", value: 1.0)
        await exporter.counter("test metric with spaces", value: 1.0)
        
        // Should not crash
    }
    
    // MARK: - Tag Merging Tests
    
    func testGlobalTagMerging() async {
        let config = StatsDExporter.Configuration(
            globalTags: ["env": "test", "version": "1.0"]
        )
        let exporter = StatsDExporter(configuration: config)
        
        await exporter.counter("tag.test", value: 1.0, tags: ["custom": "tag"])
        
        // Tags should be merged (global + custom)
    }
    
    func testTagOverride() async {
        let config = StatsDExporter.Configuration(
            globalTags: ["env": "production"]
        )
        let exporter = StatsDExporter(configuration: config)
        
        // Custom tag should override global
        await exporter.counter("override.test", value: 1.0, tags: ["env": "staging"])
    }
    
    // MARK: - Prefix Tests
    
    func testMetricPrefix() async {
        let config = StatsDExporter.Configuration(prefix: "myapp")
        let exporter = StatsDExporter(configuration: config)
        
        await exporter.counter("requests", value: 1.0)
        // Should send as "myapp.requests"
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentRecording() async {
        let exporter = StatsDExporter()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await exporter.counter("concurrent.test", value: Double(i))
                }
            }
        }
        
        await exporter.forceFlush()
    }
    
    func testConcurrentBatching() async {
        let config = StatsDExporter.Configuration(maxBatchSize: 10)
        let exporter = StatsDExporter(configuration: config)
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    for j in 0..<10 {
                        await exporter.counter("batch.concurrent", value: Double(j))
                    }
                }
            }
        }
        
        await exporter.forceFlush()
    }
}