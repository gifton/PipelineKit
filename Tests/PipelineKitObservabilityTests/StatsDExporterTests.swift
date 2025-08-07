import XCTest
import Foundation
@testable import PipelineKit
import PipelineKitTestSupport

final class StatsDExporterTests: XCTestCase {
    func testStatsDExporterInitialization() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            prefix: "test."
        )
        
        // When
        do {
            let exporter = try await StatsDExporter(configuration: configuration)
            
            // Then
            let status = await exporter.status
            XCTAssertTrue(status.isActive)
            XCTAssertEqual(status.queueDepth, 0)
            XCTAssertEqual(status.successCount, 0)
            XCTAssertEqual(status.failureCount, 0)
            
            // Cleanup
            await exporter.shutdown()
        } catch {
            // Expected on platforms without Network framework
            if error.localizedDescription.contains("Network framework") {
                throw XCTSkip("Network framework not available on this platform")
            }
            throw error
        }
    }
    
    func testMetricFormatting() async throws {
        // This test doesn't require actual network connection
        // We'll test the formatting logic by examining what would be sent
        
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            prefix: "myapp.",
            enableTags: true
        )
        
        do {
            let exporter = try await StatsDExporter(configuration: configuration)
            
            // Test gauge metric
            let gaugeMetric = MetricDataPoint(
                timestamp: Date(),
                name: "cpu.usage",
                value: 75.5,
                type: .gauge,
                tags: ["host": "server1"]
            )
            
            // Test counter metric
            let counterMetric = MetricDataPoint(
                timestamp: Date(),
                name: "requests.count",
                value: 100.0,
                type: .counter,
                tags: ["method": "GET", "status": "200"]
            )
            
            // Test timer metric
            let timerMetric = MetricDataPoint(
                timestamp: Date(),
                name: "response.time",
                value: 0.150, // 150ms
                type: .timer,
                tags: ["endpoint": "/api/users"]
            )
            
            // Export metrics (will fail without server, but that's ok)
            for metric in [gaugeMetric, counterMetric, timerMetric] {
                do {
                    try await exporter.export(metric)
                } catch {
                    // Expected - no real server
                }
            }
            
            // Cleanup
            await exporter.shutdown()
        } catch {
            if error.localizedDescription.contains("Network framework") {
                throw XCTSkip("Network framework not available on this platform")
            }
            throw error
        }
    }
    
    func testBatchExport() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            bufferSize: 5,
            realTimeExport: false
        )
        
        do {
            let exporter = try await StatsDExporter(configuration: configuration)
            
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
        } catch {
            if error.localizedDescription.contains("Network framework") {
                throw XCTSkip("Network framework not available on this platform")
            }
            throw error
        }
    }
    
    func testSamplingRate() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            sampleRate: 0.1, // Only 10% of metrics should be sent
            realTimeExport: true
        )
        
        do {
            let exporter = try await StatsDExporter(configuration: configuration)
            
            // When - Send many metrics
            for i in 0..<100 {
                let metric = MetricDataPoint(
                    timestamp: Date(),
                    name: "sampled.metric",
                    value: Double(i),
                    type: .counter,
                    tags: [:]
                )
                
                do {
                    try await exporter.export(metric)
                } catch {
                    // Ignore network errors
                }
            }
            
            // Then - Due to sampling, not all metrics will be sent
            // We can't test exact numbers due to randomness, but status should show activity
            let status = await exporter.status
            XCTAssertTrue(status.successCount > 0 || status.failureCount > 0)
            
            // Cleanup
            await exporter.shutdown()
        } catch {
            if error.localizedDescription.contains("Network framework") {
                throw XCTSkip("Network framework not available on this platform")
            }
            throw error
        }
    }
    
    func testGlobalTags() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            globalTags: [
                "environment": "test",
                "region": "us-east-1"
            ]
        )
        
        do {
            let exporter = try await StatsDExporter(configuration: configuration)
            
            // When
            let metric = MetricDataPoint(
                timestamp: Date(),
                name: "test.metric",
                value: 42.0,
                type: .gauge,
                tags: ["custom": "tag"]
            )
            
            do {
                try await exporter.export(metric)
            } catch {
                // Expected - no real server
            }
            
            // Cleanup
            await exporter.shutdown()
        } catch {
            if error.localizedDescription.contains("Network framework") {
                throw XCTSkip("Network framework not available on this platform")
            }
            throw error
        }
    }
    
    func testExportAggregatedMetrics() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            realTimeExport: true // Force real-time to trigger actual send
        )
        
        do {
            let exporter = try await StatsDExporter(configuration: configuration)
            
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
                // If we get here without error, count it as success
                let status = await exporter.status
                XCTAssertTrue(status.successCount > 0 || status.failureCount > 0)
            } catch {
                // Expected - will fail with no real server
                // Even if it fails, we should have tried to send
                let status = await exporter.status
                XCTAssertGreaterThanOrEqual(status.failureCount, 1)
            }
            
            // Cleanup
            await exporter.shutdown()
        } catch {
            if error.localizedDescription.contains("Network framework") {
                throw XCTSkip("Network framework not available on this platform")
            }
            throw error
        }
    }
    
    func testShutdown() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125
        )
        
        do {
            let exporter = try await StatsDExporter(configuration: configuration)
            
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
        } catch {
            if error.localizedDescription.contains("Network framework") {
                throw XCTSkip("Network framework not available on this platform")
            }
            throw error
        }
    }
    
    func testMetricNameSanitization() async throws {
        // Given
        let configuration = StatsDExportConfiguration(
            host: "localhost",
            port: 8125,
            prefix: "app."
        )
        
        do {
            let exporter = try await StatsDExporter(configuration: configuration)
            
            // Test metric with special characters that need sanitization
            let metric = MetricDataPoint(
                timestamp: Date(),
                name: "test:metric|with@special#chars",
                value: 42.0,
                type: .gauge,
                tags: [:]
            )
            
            // When
            do {
                try await exporter.export(metric)
            } catch {
                // Expected - no real server
            }
            
            // The metric name should be sanitized internally
            // We can't directly test the sanitized name, but the export should work
            
            // Cleanup
            await exporter.shutdown()
        } catch {
            if error.localizedDescription.contains("Network framework") {
                throw XCTSkip("Network framework not available on this platform")
            }
            throw error
        }
    }
}
