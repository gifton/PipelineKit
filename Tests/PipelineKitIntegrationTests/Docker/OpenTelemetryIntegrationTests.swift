import XCTest
@testable import PipelineKitMiddleware

/// Integration tests for OpenTelemetry Collector
/// 
/// These tests verify that the OpenTelemetryExporter can successfully
/// send data to a real OpenTelemetry Collector instance.
@available(macOS 13.0, *)
final class OpenTelemetryIntegrationTests: XCTestCase {
    
    override func setUpWithError() throws {
        // Use async setup with proper error propagation
        let expectation = XCTestExpectation(description: "Docker services ready")
        
        Task {
            do {
                try await DockerTestHelper.shared.ensureServicesRunning()
                try await DockerTestHelper.shared.waitForService(port: 4317) // OTLP gRPC
                try await DockerTestHelper.shared.waitForService(port: 8888) // Metrics endpoint
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
    
    func testCollectorIsReachable() async throws {
        // Given - collector should be running
        
        // When - we query the metrics endpoint
        let metrics = try await DockerTestHelper.shared.queryOTelMetrics()
        
        // Then - we should get a response containing OpenTelemetry metrics
        XCTAssertTrue(metrics.contains("# HELP"))
        XCTAssertTrue(metrics.contains("# TYPE"))
        XCTAssertTrue(metrics.contains("otelcol_"))
    }
    
    func testExporterCanConnect() async throws {
        // Given
        let exporter = OpenTelemetryExporter(
            endpoint: "http://localhost:4317",
            headers: ["test-run": UUID().uuidString],
            timeout: 5.0
        )
        
        // When - Create a context and export metrics
        let context = CommandContext()
        context.set(key: MetricsContextKey.self, value: [
            "test.connection.check": 1.0
        ])
        
        // Then - export should succeed without throwing
        do {
            try await exporter.export(context: context)
            
            // Give collector time to process
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            
            // Verify collector received data
            let metrics = try await DockerTestHelper.shared.queryOTelMetrics()
            XCTAssertTrue(metrics.contains("otelcol_receiver_accepted_metric_points"))
        } catch {
            XCTFail("Failed to export metric: \(error)")
        }
    }
    
    func testBatchExport() async throws {
        // Given
        let exporter = OpenTelemetryExporter(
            endpoint: "http://localhost:4317",
            headers: ["test-run": "batch-test"]
        )
        
        let batchSize = 100
        var metrics: [ExportableMetric] = []
        
        // Create a batch of metrics
        for i in 0..<batchSize {
            metrics.append(ExportableMetric(
                name: "test.batch.counter",
                value: Double(i),
                timestamp: Date(),
                tags: ["index": String(i), "batch": "test"],
                type: .counter
            ))
        }
        
        // When
        let startTime = Date()
        try await exporter.export(metrics)
        let exportDuration = Date().timeIntervalSince(startTime)
        
        // Then
        XCTAssertLessThan(exportDuration, 5.0, "Batch export should complete quickly")
        
        // Verify collector processed the batch
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let collectorMetrics = try await DockerTestHelper.shared.queryOTelMetrics()
        
        // Check that exporter metrics show activity
        XCTAssertTrue(collectorMetrics.contains("otelcol_receiver_accepted_metric_points"))
    }
    
    func testExportWithLargePayload() async throws {
        // Given - a metric with many tags
        let exporter = OpenTelemetryExporter(endpoint: "http://localhost:4317")
        
        var tags: [String: String] = [:]
        for i in 0..<50 {
            tags["tag_\(i)"] = "value_\(i)_with_some_longer_content_to_increase_size"
        }
        
        let metric = ExportableMetric(
            name: "test.large.payload",
            value: 42.0,
            timestamp: Date(),
            tags: tags,
            type: .gauge
        )
        
        // When/Then - should handle large payload
        do {
            try await exporter.export([metric])
        } catch {
            XCTFail("Failed to export large metric: \(error)")
        }
    }
    
    func testExportDifferentMetricTypes() async throws {
        // Given
        let exporter = OpenTelemetryExporter(endpoint: "http://localhost:4317")
        
        let metrics = [
            ExportableMetric(
                name: "test.counter",
                value: 10,
                timestamp: Date(),
                tags: ["type": "counter"],
                type: .counter
            ),
            ExportableMetric(
                name: "test.gauge",
                value: 42.5,
                timestamp: Date(),
                tags: ["type": "gauge"],
                type: .gauge
            ),
            ExportableMetric(
                name: "test.histogram",
                value: 123.45,
                timestamp: Date(),
                tags: ["type": "histogram"],
                type: .histogram
            )
        ]
        
        // When/Then - all types should export successfully
        for metric in metrics {
            do {
                try await exporter.export([metric])
                // Small delay between exports
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            } catch {
                XCTFail("Failed to export \(metric.type) metric: \(error)")
            }
        }
    }
}

// Note: Real PipelineKit types from PipelineKitMiddleware should be used
// This assumes MetricsContextKey and CommandContext are available