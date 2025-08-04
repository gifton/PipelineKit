import XCTest
import Foundation
@testable import PipelineKit
@testable import PipelineKitMiddleware

final class OpenTelemetryExporterTests: XCTestCase {
    
    func testOpenTelemetryExporterInitialization() async throws {
        // Given
        let configuration = try OpenTelemetryExportConfiguration(
            endpoint: "http://localhost:4318/v1/metrics",
            serviceName: "test-service",
            serviceVersion: "1.0.0"
        )
        
        // When
        let exporter = try await OpenTelemetryExporter(configuration: configuration)
        
        // Then
        let status = await exporter.status
        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.queueDepth, 0)
        XCTAssertEqual(status.successCount, 0)
        XCTAssertEqual(status.failureCount, 0)
        
        // Cleanup
        await exporter.shutdown()
    }
    
    func testExportSingleMetric() async throws {
        // Given
        let configuration = try OpenTelemetryExportConfiguration(
            endpoint: "http://localhost:4318/v1/metrics",
            serviceName: "test-service",
            realTimeExport: true
        )
        
        let exporter = try await OpenTelemetryExporter(configuration: configuration)
        
        // Create a test metric
        let metric = MetricDataPoint(
            timestamp: Date(),
            name: "test.metric",
            value: 42.0,
            type: .gauge,
            tags: ["environment": "test"]
        )
        
        // When
        do {
            try await exporter.export(metric)
            XCTFail("Should fail without real server")
        } catch {
            // Expected - will fail with no real server
        }
        
        // Then
        let status = await exporter.status
        XCTAssertGreaterThanOrEqual(status.failureCount, 1) // Should have at least one failure
        
        // Cleanup
        await exporter.shutdown()
    }
    
    func testBatchExport() async throws {
        // Given
        let configuration = try OpenTelemetryExportConfiguration(
            endpoint: "http://localhost:4318/v1/metrics",
            serviceName: "test-service",
            bufferSize: 5,
            realTimeExport: false
        )
        
        let exporter = try await OpenTelemetryExporter(configuration: configuration)
        
        // When - Add metrics without triggering immediate export
        for i in 0..<3 {
            let metric = MetricDataPoint(
                timestamp: Date(),
                name: "test.metric.\(i)",
                value: Double(i),
                type: .counter,
                tags: ["index": "\(i)"]
            )
            try await exporter.export(metric)
        }
        
        // Then - Metrics should be buffered
        let status = await exporter.status
        XCTAssertEqual(status.queueDepth, 3)
        
        // Cleanup
        await exporter.shutdown()
    }
    
    func testExportAggregatedMetrics() async throws {
        // Given
        let configuration = try OpenTelemetryExportConfiguration(
            endpoint: "http://localhost:4318/v1/metrics",
            serviceName: "test-service"
        )
        
        let exporter = try await OpenTelemetryExporter(configuration: configuration)
        
        // Create aggregated metrics
        let aggregated = AggregatedMetrics(
            name: "request.duration",
            type: .histogram,
            window: TimeWindow(duration: 60, startTime: Date().addingTimeInterval(-60)),
            timestamp: Date(),
            statistics: .histogram(HistogramStatistics(
                count: 100,
                min: 10,
                max: 200,
                sum: 5000,
                mean: 50,
                p50: 45,
                p90: 90,
                p95: 95,
                p99: 99,
                p999: 120
            )),
            tags: ["service": "api"]
        )
        
        // When
        do {
            try await exporter.exportAggregated([aggregated])
        } catch {
            // Expected - will fail with no real server
        }
        
        // Then
        let status = await exporter.status
        XCTAssertGreaterThanOrEqual(status.failureCount, 1)
        
        // Cleanup
        await exporter.shutdown()
    }
    
    func testResourceAttributes() async throws {
        // Given
        let configuration = try OpenTelemetryExportConfiguration(
            endpoint: "http://localhost:4318/v1/metrics",
            serviceName: "test-service",
            serviceVersion: "2.0.0",
            serviceInstanceId: "instance-123",
            resourceAttributes: [
                "deployment.environment": "production",
                "service.namespace": "backend"
            ]
        )
        
        // When
        let exporter = try await OpenTelemetryExporter(configuration: configuration)
        
        // Then - Just verify initialization with resource attributes works
        let status = await exporter.status
        XCTAssertTrue(status.isActive)
        
        // Cleanup
        await exporter.shutdown()
    }
    
    func testShutdown() async throws {
        // Given
        let configuration = try OpenTelemetryExportConfiguration(
            endpoint: "http://localhost:4318/v1/metrics",
            serviceName: "test-service"
        )
        
        let exporter = try await OpenTelemetryExporter(configuration: configuration)
        
        // Add a metric to buffer
        let metric = MetricDataPoint(
            timestamp: Date(),
            name: "test.metric",
            value: 1.0,
            type: .gauge,
            tags: [:]
        )
        try await exporter.export(metric)
        
        // When
        await exporter.shutdown()
        
        // Then
        let status = await exporter.status
        XCTAssertFalse(status.isActive)
        
        // Export should fail after shutdown
        do {
            try await exporter.export(metric)
            XCTFail("Should not be able to export after shutdown")
        } catch {
            // Expected
        }
    }
    
    func testMetricTypeMapping() async throws {
        // Given
        let configuration = try OpenTelemetryExportConfiguration(
            endpoint: "http://localhost:4318/v1/metrics",
            serviceName: "test-service",
            realTimeExport: true
        )
        
        let exporter = try await OpenTelemetryExporter(configuration: configuration)
        
        // Test different metric types
        let gaugeMetric = MetricDataPoint(
            timestamp: Date(),
            name: "memory.usage",
            value: 1024.0,
            type: .gauge,
            tags: ["unit": "bytes"]
        )
        
        let counterMetric = MetricDataPoint(
            timestamp: Date(),
            name: "requests.total",
            value: 100.0,
            type: .counter,
            tags: ["method": "GET"]
        )
        
        let histogramMetric = MetricDataPoint(
            timestamp: Date(),
            name: "request.duration",
            value: 0.150,
            type: .histogram,
            tags: ["endpoint": "/api/users"]
        )
        
        // When - Export each type
        for metric in [gaugeMetric, counterMetric, histogramMetric] {
            do {
                try await exporter.export(metric)
            } catch {
                // Expected - no real server
            }
        }
        
        // Then
        let status = await exporter.status
        XCTAssertEqual(status.failureCount, 3) // All should fail without server
        
        // Cleanup
        await exporter.shutdown()
    }
}

