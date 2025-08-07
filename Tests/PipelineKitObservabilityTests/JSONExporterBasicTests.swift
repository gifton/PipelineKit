import XCTest
@testable import PipelineKitObservability
@testable import PipelineKitCore

final class JSONExporterBasicTests: XCTestCase {
    
    // MARK: - Basic Export Tests
    
    func testBasicExport() async throws {
        let configuration = JSONExportConfiguration(
            fileConfig: JSONFileConfiguration(
                path: "/tmp/test-basic-export.json",
                maxFileSize: 1024 * 1024,
                maxFiles: 1,
                bufferSize: 10,
                realTimeExport: true,
                flushInterval: 1.0,
                compressRotated: false
            ),
            prettyPrint: true,
            sortKeys: true,
            dateFormat: .iso8601,
            decimalPlaces: 2
        )
        
        let exporter = try await JSONExporter(configuration: configuration)
        
        // Export a single metric
        let metric = MetricDataPoint(
            name: "test.metric",
            value: 42.123,
            type: .gauge,
            tags: ["env": "test", "host": "localhost"]
        )
        
        try await exporter.export(metric)
        await exporter.shutdown()
        
        // Verify file exists and contains the metric
        let fileURL = URL(fileURLWithPath: configuration.fileConfig.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        
        let data = try Data(contentsOf: fileURL)
        let content = String(data: data, encoding: .utf8)!
        
        // Verify JSON structure
        XCTAssertTrue(content.contains("test.metric"))
        XCTAssertTrue(content.contains("42.12")) // Decimal places = 2
        XCTAssertTrue(content.contains("gauge"))
        XCTAssertTrue(content.contains("\"env\" : \"test\""))
        XCTAssertTrue(content.contains("\"host\" : \"localhost\""))
        
        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    func testBatchExport() async throws {
        let configuration = JSONExportConfiguration(
            fileConfig: JSONFileConfiguration(
                path: "/tmp/test-batch-export.json",
                maxFileSize: 1024 * 1024,
                maxFiles: 1,
                bufferSize: 100,
                realTimeExport: false,
                flushInterval: 10.0,
                compressRotated: false
            ),
            prettyPrint: false,
            sortKeys: false,
            dateFormat: .unixMillis,
            decimalPlaces: 0
        )
        
        let exporter = try await JSONExporter(configuration: configuration)
        
        // Create a batch of metrics
        let metrics = (0..<50).map { i in
            MetricDataPoint(
                name: "batch.metric.\(i)",
                value: Double(i),
                type: .counter,
                tags: ["index": String(i)]
            )
        }
        
        try await exporter.exportBatch(metrics)
        try await exporter.flush()
        await exporter.shutdown()
        
        // Verify file contains all metrics
        let fileURL = URL(fileURLWithPath: configuration.fileConfig.path)
        let data = try Data(contentsOf: fileURL)
        let content = String(data: data, encoding: .utf8)!
        
        for i in 0..<50 {
            XCTAssertTrue(content.contains("batch.metric.\(i)"))
        }
        
        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    func testAggregatedMetricsExport() async throws {
        let configuration = JSONExportConfiguration(
            fileConfig: JSONFileConfiguration(
                path: "/tmp/test-aggregated.json",
                maxFileSize: 1024 * 1024,
                maxFiles: 1,
                bufferSize: 10,
                realTimeExport: true,
                flushInterval: 1.0,
                compressRotated: false
            ),
            prettyPrint: true,
            sortKeys: true,
            dateFormat: .custom,
            decimalPlaces: 3
        )
        
        let exporter = try await JSONExporter(configuration: configuration)
        
        // Create aggregated metrics
        let aggregated = [
            AggregatedMetrics(
                name: "request.duration",
                type: .histogram,
                timestamp: Date(),
                window: TimeWindow(
                    duration: 60.0,
                    startTime: Date().addingTimeInterval(-60),
                    endTime: Date()
                ),
                statistics: .histogram(HistogramStatistics(
                    count: 1000,
                    min: 0.5,
                    max: 150.7,
                    mean: 25.3,
                    stdDev: 12.5,
                    p50: 20.0,
                    p90: 45.0,
                    p95: 60.0,
                    p99: 120.0,
                    p999: 145.0
                )),
                tags: ["service": "api", "endpoint": "/users"]
            )
        ]
        
        try await exporter.exportAggregated(aggregated)
        await exporter.shutdown()
        
        // Verify file contains aggregated metrics
        let fileURL = URL(fileURLWithPath: configuration.fileConfig.path)
        let data = try Data(contentsOf: fileURL)
        let content = String(data: data, encoding: .utf8)!
        
        // Check for histogram statistics
        XCTAssertTrue(content.contains("request.duration"))
        XCTAssertTrue(content.contains("histogram"))
        XCTAssertTrue(content.contains("\"count\" : 1000"))
        XCTAssertTrue(content.contains("\"p50\" : 20"))
        XCTAssertTrue(content.contains("\"p99\" : 120"))
        
        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    func testFileRotation() async throws {
        let basePath = "/tmp/test-rotation.json"
        let configuration = JSONExportConfiguration(
            fileConfig: JSONFileConfiguration(
                path: basePath,
                maxFileSize: 100, // Very small to trigger rotation
                maxFiles: 3,
                bufferSize: 1,
                realTimeExport: true,
                flushInterval: 1.0,
                compressRotated: false
            ),
            prettyPrint: false,
            sortKeys: false,
            dateFormat: .unix,
            decimalPlaces: 0
        )
        
        let exporter = try await JSONExporter(configuration: configuration)
        
        // Export enough metrics to trigger rotation
        for i in 0..<20 {
            let metric = MetricDataPoint(
                name: "rotation.test",
                value: Double(i),
                type: .gauge,
                tags: ["index": String(i)]
            )
            try await exporter.export(metric)
        }
        
        await exporter.shutdown()
        
        // Check that rotation occurred
        let baseURL = URL(fileURLWithPath: basePath)
        let rotatedURL1 = baseURL.deletingLastPathComponent()
            .appendingPathComponent("test-rotation.1.json")
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: basePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL1.path))
        
        // Clean up
        try? FileManager.default.removeItem(atPath: basePath)
        try? FileManager.default.removeItem(at: rotatedURL1)
        try? FileManager.default.removeItem(at: baseURL.deletingLastPathComponent()
            .appendingPathComponent("test-rotation.2.json"))
    }
    
    func testExporterStatus() async throws {
        let configuration = JSONExportConfiguration(
            fileConfig: JSONFileConfiguration(
                path: "/tmp/test-status.json",
                maxFileSize: 1024 * 1024,
                maxFiles: 1,
                bufferSize: 10,
                realTimeExport: false,
                flushInterval: 10.0,
                compressRotated: false
            ),
            prettyPrint: true,
            sortKeys: true,
            dateFormat: .iso8601,
            decimalPlaces: 2
        )
        
        let exporter = try await JSONExporter(configuration: configuration)
        
        // Check initial status
        var status = exporter.status
        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.queueDepth, 0)
        XCTAssertEqual(status.successCount, 0)
        XCTAssertEqual(status.failureCount, 0)
        
        // Export some metrics
        for i in 0..<5 {
            let metric = MetricDataPoint(
                name: "status.test",
                value: Double(i),
                type: .counter
            )
            try await exporter.export(metric)
        }
        
        // Check buffered status
        status = exporter.status
        XCTAssertEqual(status.queueDepth, 5)
        
        // Flush and check
        try await exporter.flush()
        status = exporter.status
        XCTAssertEqual(status.queueDepth, 0)
        XCTAssertEqual(status.successCount, 5)
        XCTAssertNotNil(status.lastExportTime)
        
        await exporter.shutdown()
        
        // Check shutdown status
        status = exporter.status
        XCTAssertFalse(status.isActive)
        
        // Clean up
        try? FileManager.default.removeItem(atPath: configuration.fileConfig.path)
    }
}