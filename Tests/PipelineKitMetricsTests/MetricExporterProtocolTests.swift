import XCTest
@testable import PipelineKitMetrics
import PipelineKitCore

final class MetricExporterProtocolTests: XCTestCase {

    func testProtocolWithMultipleExporters() async throws {
        // Create sample metrics
        let metrics = [
            MetricSnapshot(
                name: "api.requests",
                type: "counter",
                value: 42,
                timestamp: Date(),
                tags: ["endpoint": "/users", "method": "GET"],
                unit: "count"
            ),
            MetricSnapshot(
                name: "api.latency",
                type: "histogram",
                value: 125.5,
                timestamp: Date(),
                tags: ["endpoint": "/users"],
                unit: "ms"
            ),
            MetricSnapshot(
                name: "memory.usage",
                type: "gauge",
                value: 67.8,
                timestamp: Date(),
                tags: ["process": "api-server"],
                unit: "percent"
            )
        ]

        // Test 1: Console exporter (push-based)
        let consoleExporter = ConsoleExporter(format: .compact)
        try await consoleExporter.export(metrics)

        // Test 2: Prometheus exporter (pull-based)
        let prometheusExporter = PrometheusExporter()
        try await prometheusExporter.export(metrics)
        let prometheusOutput = await prometheusExporter.scrape()

        XCTAssertTrue(prometheusOutput.contains("api_requests"))
        XCTAssertTrue(prometheusOutput.contains("endpoint=\"/users\""))
        print("Prometheus output:\n\(prometheusOutput)")

        // Test 3: Multi-exporter
        let multiExporter = MultiExporter(exporters: [
            consoleExporter,
            prometheusExporter,
            NullExporter()
        ])
        try await multiExporter.export(metrics)

        // Test 4: Batching exporter
        let batchingConsole = await BatchingExporter(
            underlying: ConsoleExporter(format: .compact, prefix: "[BATCH]"),
            maxBatchSize: 2,
            autostart: true
        )

        // Should batch after 2 metrics
        try await batchingConsole.export([metrics[0]])
        try await batchingConsole.export([metrics[1]]) // This triggers batch export
        try await batchingConsole.export([metrics[2]])
        try await batchingConsole.flush() // Export remaining

        await batchingConsole.shutdown()
    }

    func testExporterLifecycle() async throws {
        // Test exporter lifecycle methods
        let exporter = ConsoleExporter(format: .pretty)

        let metrics = [
            MetricSnapshot(
                name: "test.metric",
                type: "counter",
                value: 1,
                timestamp: Date(),
                tags: [:],
                unit: nil
            )
        ]

        // Normal operation
        try await exporter.export(metrics)
        try await exporter.flush() // Should be no-op for console
        await exporter.shutdown()  // Should be safe to call
    }

    func testStreamSupport() async throws {
        // Test streaming metrics
        let stream = AsyncStream<MetricSnapshot> { continuation in
            Task {
                for i in 1...5 {
                    let metric = MetricSnapshot(
                        name: "stream.test",
                        type: "counter",
                        value: Double(i),
                        timestamp: Date(),
                        tags: ["index": "\(i)"],
                        unit: nil
                    )
                    continuation.yield(metric)
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
                }
                continuation.finish()
            }
        }

        let exporter = ConsoleExporter(format: .compact, prefix: "[STREAM]")
        try await exporter.exportStream(stream, batchSize: 2)
    }

    func testNullExporter() async throws {
        // Test that null exporter doesn't crash
        let nullExporter = NullExporter()

        let metrics = (1...100).map { i in
            MetricSnapshot(
                name: "null.test",
                type: "counter",
                value: Double(i),
                timestamp: Date(),
                tags: [:],
                unit: nil
            )
        }

        // Should handle any number of metrics without issues
        try await nullExporter.export(metrics)
        try await nullExporter.flush()
        await nullExporter.shutdown()
    }

    func testPrometheusDeduplication() async throws {
        // Test that Prometheus correctly deduplicates metrics
        let exporter = PrometheusExporter()

        // Send same metric multiple times with different values
        let metric1 = MetricSnapshot(
            name: "dedup.test",
            type: "gauge",
            value: 10,
            timestamp: Date(),
            tags: ["host": "server1"],
            unit: nil
        )

        let metric2 = MetricSnapshot(
            name: "dedup.test",
            type: "gauge",
            value: 20, // Different value
            timestamp: Date().addingTimeInterval(1),
            tags: ["host": "server1"], // Same tags
            unit: nil
        )

        try await exporter.export([metric1])
        try await exporter.export([metric2])

        let output = await exporter.scrape()

        // Should only have the latest value (20)
        XCTAssertTrue(output.contains("20"))
        XCTAssertFalse(output.contains("10"))
    }
}

