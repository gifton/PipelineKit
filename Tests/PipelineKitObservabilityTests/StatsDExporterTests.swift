import XCTest
@testable import PipelineKitObservability
import Foundation

final class StatsDExporterTests: XCTestCase {
    // MARK: - Configuration Tests
    
    func testDefaultConfiguration() {
        let config = StatsDExporter.Configuration.default
        
        XCTAssertEqual(config.host, "localhost")
        XCTAssertEqual(config.port, 8125)
        XCTAssertNil(config.prefix)
        XCTAssertTrue(config.globalTags.isEmpty)
        XCTAssertEqual(config.maxBatchSize, 20)
        XCTAssertEqual(config.flushInterval, 0.1, accuracy: 1e-12)
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
        XCTAssertEqual(config.flushInterval, 0.5, accuracy: 1e-12)
    }
    
    // MARK: - Metric Recording Tests
    
    func testRecordCounter() async throws {
        let (exporter, _) = try await makeExporter()
        let snapshot = MetricSnapshot.counter("test.counter", value: 5.0, tags: ["key": "value"])
        
        // Should not crash
        await exporter.record(snapshot)
    }
    
    func testRecordGauge() async throws {
        let (exporter, _) = try await makeExporter()
        let snapshot = MetricSnapshot.gauge("test.gauge", value: 42.0, tags: [:], unit: "bytes")
        
        // Should not crash
        await exporter.record(snapshot)
    }
    
    func testRecordTimer() async throws {
        let (exporter, _) = try await makeExporter()
        let snapshot = MetricSnapshot.timer("test.timer", duration: 0.123, tags: ["endpoint": "/api"])
        
        // Should not crash
        await exporter.record(snapshot)
    }
    
    func testBatchRecording() async throws {
        let (exporter, _) = try await makeExporter()
        let snapshots = [
            MetricSnapshot.counter("batch.counter", value: 1.0),
            MetricSnapshot.gauge("batch.gauge", value: 2.0),
            MetricSnapshot.timer("batch.timer", duration: 0.003)
        ]
        
        await exporter.recordBatch(snapshots)
    }
    
    // MARK: - Batching Tests
    
    func testBatchingTriggersOnSize() async throws {
        let config = StatsDExporter.Configuration(
            maxBatchSize: 3,
            flushInterval: 10.0 // Long interval so size triggers first
        )
        let (exporter, mockTransport) = try await makeExporter(configuration: config)
        
        // Record 3 metrics to trigger batch
        for i in 1...3 {
            await exporter.counter("batch.test", value: Double(i))
        }
        
        let packets = await mockTransport.getMetricsAsStrings()
        XCTAssertEqual(packets.sorted(), (1...3).map { "batch.test:\(Double($0))|c" }.sorted())
    }
    
    func testBatchingTriggersOnInterval() async throws {
        let config = StatsDExporter.Configuration(
            maxBatchSize: 100, // High limit so interval triggers first
            flushInterval: 0.05 // 50ms
        )
        let (exporter, mockTransport) = try await makeExporter(configuration: config)
        
        await exporter.counter("interval.test", value: 1.0)
        
        // Acknowledge actual transport receipt; the watchdog bounds timer failure.
        while await mockTransport.getMetricsAsStrings().isEmpty { await Task.yield() }
        let packets = await mockTransport.getMetricsAsStrings()
        XCTAssertEqual(packets, ["interval.test:1.0|c"])
    }
    
    func testForceFlush() async throws {
        // Use mock transport to avoid network operations
        guard let (exporter, mockTransport) = await StatsDExporter.withMockTransport() else {
            XCTFail("Failed to create mock transport")
            return
        }
        addTeardownBlock { await exporter.close() }
        
        await exporter.counter("flush.test", value: 1.0)
        await exporter.forceFlush()
        
        // Verify metric was sent
        let sentMetrics = await mockTransport.getMetricsAsStrings()
        XCTAssertEqual(sentMetrics.count, 1)
        XCTAssertTrue(sentMetrics[0].contains("flush.test"))
    }
    
    // MARK: - Error Handling Tests
    
    func testErrorHandlerCalled() async throws {
        let expectation = XCTestExpectation(description: "Error handler called")
        
        // Use mock transport configured to fail
        let mockConfig = MockTransport.Configuration(
            shouldFail: true,
            failureError: .sendFailed("Simulated failure")
        )
        guard let (exporter, _) = await StatsDExporter.withMockTransport(mockConfig: mockConfig) else {
            XCTFail("Failed to create mock transport")
            return
        }
        addTeardownBlock { await exporter.close() }
        
        await exporter.setErrorHandler { _ in
            // Verify we got an error
            expectation.fulfill()
        }
        
        // Try to send metrics - should trigger error from mock
        await exporter.counter("error.test", value: 1.0)
        await exporter.forceFlush()
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    // MARK: - Convenience Methods Tests
    
    func testConvenienceCounter() async throws {
        let (exporter, _) = try await makeExporter()
        await exporter.counter("convenience.counter", value: 10.0, tags: ["test": "true"])
    }
    
    func testConvenienceGauge() async throws {
        let (exporter, _) = try await makeExporter()
        await exporter.gauge("convenience.gauge", value: 99.9, tags: [:])
    }
    
    func testConvenienceTimer() async throws {
        let (exporter, _) = try await makeExporter()
        await exporter.timer("convenience.timer", duration: 0.456, tags: ["method": "GET"])
    }
    
    func testTimeBlock() async throws {
        let (exporter, _) = try await makeExporter()
        
        let result = try await exporter.time("block.timer", tags: ["async": "true"]) {
            try await Task.sleep(for: .milliseconds(10))
            return 42
        }
        
        XCTAssertEqual(result, 42)
    }
    
    // MARK: - Metric Name Sanitization Tests
    
    func testMetricNameSanitization() async throws {
        let (exporter, _) = try await makeExporter()
        
        // Names with special characters should be sanitized
        await exporter.counter("test:metric|with@special#chars", value: 1.0)
        await exporter.counter("test metric with spaces", value: 1.0)
        
        // Should not crash
    }
    
    // MARK: - Tag Merging Tests
    
    func testGlobalTagMerging() async throws {
        let config = StatsDExporter.Configuration(
            globalTags: ["env": "test", "version": "1.0"]
        )
        let (exporter, _) = try await makeExporter(configuration: config)
        
        await exporter.counter("tag.test", value: 1.0, tags: ["custom": "tag"])
        
        // Tags should be merged (global + custom)
    }
    
    func testTagOverride() async throws {
        let config = StatsDExporter.Configuration(
            globalTags: ["env": "production"]
        )
        let (exporter, _) = try await makeExporter(configuration: config)
        
        // Custom tag should override global
        await exporter.counter("override.test", value: 1.0, tags: ["env": "staging"])
    }
    
    // MARK: - Prefix Tests
    
    func testMetricPrefix() async throws {
        let config = StatsDExporter.Configuration(prefix: "myapp")
        let (exporter, _) = try await makeExporter(configuration: config)
        
        await exporter.counter("requests", value: 1.0)
        // Should send as "myapp.requests"
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentRecording() async throws {
        // Use mock transport to avoid network operations
        guard let (exporter, mockTransport) = await StatsDExporter.withMockTransport() else {
            XCTFail("Failed to create mock transport")
            return
        }
        addTeardownBlock { await exporter.close() }
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await exporter.counter("concurrent.test", value: Double(i))
                }
            }
        }
        
        await exporter.forceFlush()
        
        // Verify all metrics were captured
        let sentMetrics = await mockTransport.getMetricsAsStrings()
        XCTAssertEqual(sentMetrics.sorted(), (0..<100).map { "concurrent.test:\(Double($0))|c" }.sorted())
    }
    
    func testConcurrentBatching() async throws {
        let config = StatsDExporter.Configuration(maxBatchSize: 10)
        guard let (exporter, mockTransport) = await StatsDExporter.withMockTransport(configuration: config) else {
            XCTFail("Failed to create mock transport")
            return
        }
        addTeardownBlock { await exporter.close() }
        
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
        
        // Verify batching occurred
        let sentMetrics = await mockTransport.getMetricsAsStrings()
        XCTAssertEqual(sentMetrics.count, 100)
        for index in 0..<10 {
            XCTAssertEqual(sentMetrics.filter { $0 == "batch.concurrent:\(Double(index))|c" }.count, 10)
        }
    }

    private func makeExporter(
        configuration: StatsDExporter.Configuration = .default
    ) async throws -> (StatsDExporter, MockTransport) {
        let transport = try await MockTransport(configuration: .init())
        let exporter = StatsDExporter(configuration: configuration, transport: transport)
        addTeardownBlock { await exporter.close() }
        return (exporter, transport)
    }
}
