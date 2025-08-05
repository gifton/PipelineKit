import XCTest
@testable import PipelineKitMiddleware
@testable import PipelineKitCore
import Foundation

/// Integration tests for StatsD server
/// 
/// These tests verify that the StatsDExporter can successfully
/// send metrics to a real StatsD server instance.
@available(macOS 13.0, *)
final class StatsDIntegrationTests: XCTestCase {
    
    override func setUpWithError() throws {
        // Use async setup with proper error propagation
        let expectation = XCTestExpectation(description: "Docker services ready")
        
        Task {
            do {
                try await DockerTestHelper.shared.ensureServicesRunning()
                try await DockerTestHelper.shared.waitForService(port: 8125) // StatsD UDP
                try await DockerTestHelper.shared.waitForService(port: 8126) // StatsD management
                expectation.fulfill()
            } catch {
                XCTFail("Failed to start Docker services: \(error)")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 60.0)
    }
    
    override class func tearDown() {
        super.tearDown()
        
        // Optionally stop services after all tests
        if ProcessInfo.processInfo.environment["STOP_DOCKER_AFTER_TESTS"] == "true" {
            Task {
                try? await DockerTestHelper.shared.stopServices()
            }
        }
    }
    
    func testStatsDServerIsReachable() async throws {
        // Given - StatsD should be running
        
        // When - we check the management port
        let urlRequest = URLRequest(url: URL(string: "http://localhost:8126/health")!)
        
        do {
            let (_, response) = try await URLSession.shared.data(for: urlRequest)
            
            // Then - we should get a response (even if it's an error since StatsD may not have /health)
            XCTAssertNotNil(response)
        } catch {
            // Connection should at least be possible
            XCTAssertTrue(error.localizedDescription.contains("refused") == false,
                         "StatsD server should be reachable")
        }
    }
    
    func testExporterCanConnect() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            prefix: "pipelinekit.test.",
            realTimeExport: true
        )
        
        // When - Create exporter and send a test metric
        do {
            let exporter = try await StatsDExporter(configuration: configuration)
            
            let metric = MetricDataPoint(
                timestamp: Date(),
                name: "connection.test",
                value: 1.0,
                type: .counter,
                tags: ["test": "integration"]
            )
            
            // Then - export should succeed without throwing
            try await exporter.export(metric)
            
            // Give StatsD time to process
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second
            
            // Check exporter status
            let status = await exporter.status
            XCTAssertTrue(status.isActive)
            XCTAssertGreaterThan(status.successCount, 0)
            XCTAssertEqual(status.failureCount, 0)
            
            await exporter.shutdown()
        } catch {
            XCTFail("Failed to connect to StatsD: \(error)")
        }
    }
    
    func testBatchExport() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            prefix: "pipelinekit.batch.",
            bufferSize: 50,
            realTimeExport: false,
            flushInterval: 0.5
        )
        
        let exporter = try await StatsDExporter(configuration: configuration)
        
        // When - Send a batch of metrics
        let batchSize = 25
        var metrics: [MetricDataPoint] = []
        
        for i in 0..<batchSize {
            metrics.append(MetricDataPoint(
                timestamp: Date(),
                name: "batch.counter",
                value: Double(i),
                type: .counter,
                tags: ["batch": "test", "index": String(i)]
            ))
        }
        
        let startTime = Date()
        try await exporter.exportBatch(metrics)
        try await exporter.flush() // Force flush to send immediately
        let exportDuration = Date().timeIntervalSince(startTime)
        
        // Then
        XCTAssertLessThan(exportDuration, 2.0, "Batch export should complete quickly")
        
        let status = await exporter.status
        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.queueDepth, 0, "Queue should be empty after flush")
        
        await exporter.shutdown()
    }
    
    func testDifferentMetricTypes() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            prefix: "pipelinekit.types.",
            enableTags: true
        )
        
        let exporter = try await StatsDExporter(configuration: configuration)
        
        // When - Send different metric types
        let testCases: [(MetricDataPoint, String)] = [
            (MetricDataPoint(
                timestamp: Date(),
                name: "cpu.usage",
                value: 75.5,
                type: .gauge,
                tags: ["host": "test-server"]
            ), "gauge"),
            (MetricDataPoint(
                timestamp: Date(),
                name: "requests.count",
                value: 100,
                type: .counter,
                tags: ["endpoint": "/api/test"]
            ), "counter"),
            (MetricDataPoint(
                timestamp: Date(),
                name: "response.time",
                value: 0.123, // seconds, will be converted to ms
                type: .timer,
                tags: ["status": "200"]
            ), "timer"),
            (MetricDataPoint(
                timestamp: Date(),
                name: "data.size",
                value: 1024,
                type: .histogram,
                tags: ["operation": "upload"]
            ), "histogram")
        ]
        
        // Then - all types should export successfully
        for (metric, typeName) in testCases {
            do {
                try await exporter.export(metric)
                // Small delay between exports
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            } catch {
                XCTFail("Failed to export \(typeName) metric: \(error)")
            }
        }
        
        // Verify all metrics were sent
        try await exporter.flush()
        let status = await exporter.status
        XCTAssertGreaterThanOrEqual(status.successCount, UInt64(testCases.count))
        
        await exporter.shutdown()
    }
    
    func testGlobalTags() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            prefix: "pipelinekit.global.",
            globalTags: [
                "environment": "integration-test",
                "service": "pipelinekit",
                "version": "1.0.0"
            ],
            enableTags: true
        )
        
        let exporter = try await StatsDExporter(configuration: configuration)
        
        // When - Send metrics with both global and metric-specific tags
        let metric = MetricDataPoint(
            timestamp: Date(),
            name: "tagged.metric",
            value: 42.0,
            type: .gauge,
            tags: ["custom": "value", "test": "global-tags"]
        )
        
        try await exporter.export(metric)
        try await exporter.flush()
        
        // Then
        let status = await exporter.status
        XCTAssertGreaterThan(status.successCount, 0)
        XCTAssertEqual(status.failureCount, 0)
        
        await exporter.shutdown()
    }
    
    func testHighVolumeMetrics() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            prefix: "pipelinekit.load.",
            bufferSize: 1000,
            realTimeExport: false,
            sampleRate: 0.1 // Only sample 10% to reduce load
        )
        
        let exporter = try await StatsDExporter(configuration: configuration)
        
        // When - Send many metrics rapidly
        let metricCount = 1000
        let startTime = Date()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<metricCount {
                group.addTask {
                    let metric = MetricDataPoint(
                        timestamp: Date(),
                        name: "load.test",
                        value: Double(i % 100),
                        type: .counter,
                        tags: ["batch": String(i / 100)]
                    )
                    
                    do {
                        try await exporter.export(metric)
                    } catch {
                        // Ignore individual failures in load test
                    }
                }
            }
        }
        
        // Flush remaining metrics
        try await exporter.flush()
        
        let duration = Date().timeIntervalSince(startTime)
        
        // Then
        XCTAssertLessThan(duration, 10.0, "High volume export should complete within 10 seconds")
        
        let status = await exporter.status
        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.queueDepth, 0, "Queue should be empty after flush")
        
        // With 10% sampling, we should have sent roughly 10% of metrics
        // Allow for some variance in random sampling
        let expectedCount = metricCount / 10
        let variance = expectedCount / 4 // 25% variance
        XCTAssertGreaterThan(Int(status.successCount), expectedCount - variance)
        XCTAssertLessThan(Int(status.successCount), expectedCount + variance)
        
        await exporter.shutdown()
    }
    
    func testConnectionRecovery() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            prefix: "pipelinekit.recovery.",
            realTimeExport: true
        )
        
        let exporter = try await StatsDExporter(configuration: configuration)
        
        // When - Send metrics (connection should work)
        let metric1 = MetricDataPoint(
            timestamp: Date(),
            name: "before.disconnect",
            value: 1.0,
            type: .counter,
            tags: [:]
        )
        
        do {
            try await exporter.export(metric1)
            
            // Note: We can't actually stop/start the Docker container mid-test easily
            // So we'll just verify the exporter handles errors gracefully
            
            // Send more metrics
            let metric2 = MetricDataPoint(
                timestamp: Date(),
                name: "after.recovery",
                value: 2.0,
                type: .counter,
                tags: [:]
            )
            
            try await exporter.export(metric2)
            
            // Then - metrics should be sent
            let status = await exporter.status
            XCTAssertTrue(status.isActive)
            
        } catch {
            // Connection errors are expected in this test
            XCTAssertTrue(error.localizedDescription.contains("export") ||
                         error.localizedDescription.contains("connection"))
        }
        
        await exporter.shutdown()
    }
    
    func testAggregatedMetricsExport() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            prefix: "pipelinekit.aggregated.",
            enableTags: true
        )
        
        let exporter = try await StatsDExporter(configuration: configuration)
        
        // When - Export aggregated metrics
        let window = TimeWindow(start: Date().addingTimeInterval(-60), duration: 60)
        
        let aggregatedMetrics = [
            AggregatedMetrics(
                name: "request.rate",
                timestamp: Date(),
                window: window,
                statistics: .counter(CounterStatistics(
                    count: 150,
                    increase: 50,
                    rate: 0.83
                )),
                tags: ["endpoint": "/api/v1"]
            ),
            AggregatedMetrics(
                name: "response.time",
                timestamp: Date(),
                window: window,
                statistics: .histogram(HistogramStatistics(
                    count: 100,
                    sum: 12.5,
                    min: 0.01,
                    max: 0.5,
                    mean: 0.125,
                    stdDev: 0.05,
                    p50: 0.1,
                    p95: 0.3,
                    p99: 0.45
                )),
                tags: ["endpoint": "/api/v1"]
            )
        ]
        
        try await exporter.exportAggregated(aggregatedMetrics)
        try await exporter.flush()
        
        // Then
        let status = await exporter.status
        XCTAssertGreaterThan(status.successCount, 0)
        XCTAssertEqual(status.failureCount, 0)
        
        await exporter.shutdown()
    }
}