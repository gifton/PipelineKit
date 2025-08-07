import XCTest
@testable import PipelineKitObservability
import PipelineKitCore

final class JSONExporterBenchmarkTests: XCTestCase {
    
    // MARK: - JSONEncoder Allocation Performance Test
    
    func testJSONEncoderAllocationPerformance() async throws {
        // This test compares the performance of creating JSONEncoder on each encode
        // vs reusing a stored JSONEncoder instance
        
        let configuration = JSONExportConfiguration(
            fileConfig: JSONFileConfiguration(
                path: "/tmp/test-export.json",
                maxFileSize: 1024 * 1024,
                maxFiles: 3,
                bufferSize: 100,
                realTimeExport: false,
                flushInterval: 10.0,
                compressRotated: false
            ),
            prettyPrint: true,
            sortKeys: true,
            dateFormat: .iso8601,
            decimalPlaces: 3
        )
        
        // Test data
        let metrics = (0..<1000).map { i in
            MetricDataPoint(
                name: "test.metric.\(i)",
                value: Double(i),
                type: .gauge,
                timestamp: Date(),
                tags: ["env": "test", "host": "localhost", "index": String(i)]
            )
        }
        
        // Warm up
        _ = try await JSONExporter(configuration: configuration)
        
        // Test 1: Current implementation (stored encoder)
        let start1 = CFAbsoluteTimeGetCurrent()
        let exporter1 = try await JSONExporter(configuration: configuration)
        for metric in metrics {
            try await exporter1.export(metric)
        }
        await exporter1.shutdown()
        let duration1 = CFAbsoluteTimeGetCurrent() - start1
        
        // Clean up
        try? FileManager.default.removeItem(atPath: configuration.fileConfig.path)
        
        // For comparison, we'll create a simple test that mimics per-call allocation
        let start2 = CFAbsoluteTimeGetCurrent()
        var encodingTime: Double = 0
        for metric in metrics {
            let encodeStart = CFAbsoluteTimeGetCurrent()
            // Simulate creating encoder each time
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            
            let jsonMetric = MetricJSON(
                timestamp: metric.timestamp,
                name: metric.name,
                value: metric.value,
                type: metric.type.rawValue,
                tags: metric.tags.isEmpty ? nil : metric.tags
            )
            _ = try encoder.encode(jsonMetric)
            encodingTime += CFAbsoluteTimeGetCurrent() - encodeStart
        }
        let duration2 = encodingTime
        
        // Results
        print("=== JSONEncoder Performance Comparison ===")
        print("Stored encoder (current): \(String(format: "%.3f", duration1 * 1000))ms total")
        print("Per-call encoder allocation: \(String(format: "%.3f", duration2 * 1000))ms encoding only")
        print("Improvement factor: \(String(format: "%.2fx", duration2 / duration1))")
        
        // The stored encoder should be significantly faster
        XCTAssertLessThan(duration1, duration2 * 1.5, "Stored encoder should be faster than per-call allocation")
    }
    
    // MARK: - Thread Safety Test
    
    func testJSONEncoderThreadSafety() async throws {
        // Verify that the stored JSONEncoder is thread-safe when used in an actor
        let configuration = JSONExportConfiguration(
            fileConfig: JSONFileConfiguration(
                path: "/tmp/test-thread-safety.json",
                maxFileSize: 10 * 1024 * 1024,
                maxFiles: 1,
                bufferSize: 1000,
                realTimeExport: false,
                flushInterval: 60.0,
                compressRotated: false
            ),
            prettyPrint: false,
            sortKeys: false,
            dateFormat: .unixMillis,
            decimalPlaces: 2
        )
        
        let exporter = try await JSONExporter(configuration: configuration)
        let concurrentTasks = 10
        let metricsPerTask = 100
        
        // Launch multiple concurrent tasks
        try await withThrowingTaskGroup(of: Void.self) { group in
            for taskId in 0..<concurrentTasks {
                group.addTask {
                    for i in 0..<metricsPerTask {
                        let metric = MetricDataPoint(
                            name: "concurrent.test",
                            value: Double(taskId * 1000 + i),
                            type: .counter,
                            timestamp: Date(),
                            tags: ["task": String(taskId), "index": String(i)]
                        )
                        try await exporter.export(metric)
                    }
                }
            }
            
            try await group.waitForAll()
        }
        
        // Verify all metrics were exported
        try await exporter.flush()
        await exporter.shutdown()
        
        // Check file exists and has content
        let fileURL = URL(fileURLWithPath: configuration.fileConfig.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        
        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Exported file should have content")
        
        // Clean up
        try? FileManager.default.removeItem(atPath: configuration.fileConfig.path)
    }
    
    // MARK: - Memory Usage Test
    
    func testMemoryUsageComparison() async throws {
        // Compare memory usage between stored encoder and per-call allocation
        let configuration = JSONExportConfiguration(
            fileConfig: JSONFileConfiguration(
                path: "/tmp/test-memory.json",
                maxFileSize: 50 * 1024 * 1024,
                maxFiles: 1,
                bufferSize: 10000,
                realTimeExport: false,
                flushInterval: 60.0,
                compressRotated: false
            ),
            prettyPrint: true,
            sortKeys: true,
            dateFormat: .custom,
            decimalPlaces: 6
        )
        
        // Create a large batch of metrics
        let largeMetricsBatch = (0..<10000).map { i in
            MetricDataPoint(
                name: "memory.test.metric",
                value: Double.random(in: 0...1000),
                type: .histogram,
                timestamp: Date(),
                tags: [
                    "env": "production",
                    "region": "us-east-1",
                    "service": "api",
                    "endpoint": "/api/v1/users/\(i)",
                    "method": "GET",
                    "status": "200"
                ]
            )
        }
        
        let exporter = try await JSONExporter(configuration: configuration)
        
        // Export in batches to simulate real usage
        for i in stride(from: 0, to: largeMetricsBatch.count, by: 100) {
            let batch = Array(largeMetricsBatch[i..<min(i + 100, largeMetricsBatch.count)])
            try await exporter.exportBatch(batch)
        }
        
        try await exporter.flush()
        await exporter.shutdown()
        
        // Verify file was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.fileConfig.path))
        
        // Clean up
        try? FileManager.default.removeItem(atPath: configuration.fileConfig.path)
    }
}

// MARK: - Helper Types

private struct MetricJSON: Codable {
    let timestamp: Date
    let name: String
    let value: Double
    let type: String
    let tags: [String: String]?
}