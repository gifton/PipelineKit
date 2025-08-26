import XCTest
@testable import PipelineKitObservability
import Foundation

final class MetricsFacadeTests: XCTestCase {
    override func setUp() async throws {
        // Reset to defaults before each test
        Metrics.storage = MetricsStorage()
        // Use NoOpRecorder for test setup to avoid network issues
        Metrics.exporter = NoOpRecorder()
        Metrics.errorHandler = nil
    }
    
    // MARK: - Basic Recording Tests
    
    func testRecordCounter() async {
        await Metrics.counter("test.counter", value: 5.0, tags: ["key": "value"])
        
        let stored = await Metrics.storage.get(name: "test.counter")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.value, 5.0)
        XCTAssertEqual(stored.first?.tags["key"], "value")
    }
    
    func testRecordGauge() async {
        await Metrics.gauge("test.gauge", value: 42.0, tags: [:], unit: "bytes")
        
        let stored = await Metrics.storage.get(name: "test.gauge")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.value, 42.0)
        XCTAssertEqual(stored.first?.unit, "bytes")
    }
    
    func testRecordTimer() async {
        await Metrics.timer("test.timer", duration: 0.123, tags: ["endpoint": "/api"])
        
        let stored = await Metrics.storage.get(name: "test.timer")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.value, 123.0) // Converted to milliseconds
        XCTAssertEqual(stored.first?.tags["endpoint"], "/api")
    }
    
    // MARK: - Time Block Tests
    
    func testTimeBlock() async throws {
        let result = try await Metrics.time("block.timer", tags: ["test": "true"]) {
            try await Task.sleep(for: .milliseconds(10))
            return "success"
        }
        
        XCTAssertEqual(result, "success")
        
        let stored = await Metrics.storage.get(name: "block.timer")
        XCTAssertEqual(stored.count, 1)
        XCTAssertNotNil(stored.first?.value)
        
        // Duration should be at least 10ms
        if let duration = stored.first?.value {
            XCTAssertGreaterThan(duration, 10.0)
        }
    }
    
    func testTimeBlockWithError() async {
        do {
            _ = try await Metrics.time("error.timer") {
                throw TestError.expected
            }
            XCTFail("Should have thrown")
        } catch {
            // Timer should still be recorded even on error
            let stored = await Metrics.storage.get(name: "error.timer")
            XCTAssertEqual(stored.count, 1)
        }
    }
    
    // MARK: - Configuration Tests
    
    func testConfigure() async {
        await Metrics.configure(
            host: "custom.host",
            port: 9999,
            prefix: "myapp",
            globalTags: ["env": "test"],
            maxBatchSize: 50,
            flushInterval: 0.5
        )
        
        // Record a metric with the new configuration
        await Metrics.counter("config.test", value: 1.0)
        
        // Verify the exporter was replaced
        XCTAssertTrue(Metrics.exporter is StatsDExporter)
    }
    
    func testConfigureWithCustomExporter() async {
        let customExporter = MockMetricRecorder()
        Metrics.configure(with: customExporter)
        
        await Metrics.counter("custom.test", value: 1.0)
        
        let snapshots = await customExporter.recordedSnapshots
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.name, "custom.test")
    }
    
    // MARK: - Disable Tests
    
    func testDisable() async {
        Metrics.disable()
        
        await Metrics.counter("disabled.test", value: 1.0)
        
        // Metrics should still be in storage
        let stored = await Metrics.storage.get(name: "disabled.test")
        XCTAssertEqual(stored.count, 1)
        
        // But exporter should be no-op
        // (Can't directly test NoOpRecorder behavior)
    }
    
    // MARK: - Flush Tests
    
    func testFlush() async {
        // Add metrics to storage
        await Metrics.storage.record(MetricSnapshot.counter("stored.metric", value: 1.0))
        
        // Add metric through facade
        await Metrics.counter("facade.metric", value: 2.0)
        
        // Flush should drain storage and send to exporter
        await Metrics.flush()
        
        // Storage should be empty
        let remaining = await Metrics.storage.getAll()
        XCTAssertEqual(remaining.count, 0)
    }
    
    // MARK: - Error Handler Tests
    
    func testErrorHandler() async {
        let expectation = XCTestExpectation(description: "Error handler called")
        expectation.isInverted = true  // We don't expect errors in normal operation
        
        Metrics.errorHandler = { error in
            print("Unexpected error: \(error)")
            expectation.fulfill()
        }
        
        // Configure with error handler
        await Metrics.configure(host: "localhost")
        
        // Trigger normal operations (should not cause errors)
        await Metrics.counter("error.test", value: 1.0)
        await Metrics.flush()
        
        // Wait a short time to ensure no errors occur
        await fulfillment(of: [expectation], timeout: 1.0, enforceOrder: false)
    }
    
    // MARK: - Concurrent Usage Tests
    
    func testConcurrentMetricRecording() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await Metrics.counter("concurrent.counter", value: Double(i))
                    await Metrics.gauge("concurrent.gauge", value: Double(i))
                    await Metrics.timer("concurrent.timer", duration: Double(i) / 1000.0)
                }
            }
        }
        
        let counters = await Metrics.storage.get(name: "concurrent.counter")
        let gauges = await Metrics.storage.get(name: "concurrent.gauge")
        let timers = await Metrics.storage.get(name: "concurrent.timer")
        
        XCTAssertEqual(counters.count, 100)
        XCTAssertEqual(gauges.count, 100)
        XCTAssertEqual(timers.count, 100)
    }
    
    func testConcurrentTimeBlocks() async throws {
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await Metrics.time("concurrent.time", tags: ["index": "\(i)"]) {
                        try await Task.sleep(for: .milliseconds(1))
                        return i
                    }
                }
            }
            
            var collected: [Int] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }
        
        XCTAssertEqual(results.count, 10)
        
        let timers = await Metrics.storage.get(name: "concurrent.time")
        XCTAssertEqual(timers.count, 10)
    }
}

// MARK: - Test Helpers

private enum TestError: Error {
    case expected
}

private struct NoOpRecorder: MetricRecorder, Sendable {
    func record(_ snapshot: MetricSnapshot) async {
        // Do nothing
    }
}

private actor MockMetricRecorder: MetricRecorder {
    var recordedSnapshots: [MetricSnapshot] = []
    
    func record(_ snapshot: MetricSnapshot) async {
        recordedSnapshots.append(snapshot)
    }
}
