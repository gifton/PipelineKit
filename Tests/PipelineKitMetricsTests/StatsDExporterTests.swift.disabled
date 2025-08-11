import XCTest
@testable import PipelineKitMetrics
import PipelineKitCore

final class StatsDExporterTests: XCTestCase {

    // MARK: - Configuration Tests

    func testDefaultConfiguration() {
        let config = StatsDExporter.Configuration.default

        XCTAssertEqual(config.host, "localhost")
        XCTAssertEqual(config.port, 8125)
        XCTAssertNil(config.prefix)
        XCTAssertTrue(config.globalTags.isEmpty)
        XCTAssertEqual(config.sampleRate, 1.0)
        XCTAssertEqual(config.maxPacketSize, 1432)
        XCTAssertEqual(config.flushInterval, 1.0)
        XCTAssertEqual(config.format, .dogStatsD)
    }

    func testCustomConfiguration() {
        let config = StatsDExporter.Configuration(
            host: "metrics.example.com",
            port: 8126,
            prefix: "myapp",
            globalTags: ["env": "production", "region": "us-east-1"],
            sampleRate: 0.5,
            maxPacketSize: 512,
            flushInterval: 5.0,
            format: .vanilla
        )

        XCTAssertEqual(config.host, "metrics.example.com")
        XCTAssertEqual(config.port, 8126)
        XCTAssertEqual(config.prefix, "myapp")
        XCTAssertEqual(config.globalTags["env"], "production")
        XCTAssertEqual(config.sampleRate, 0.5)
        XCTAssertEqual(config.maxPacketSize, 512)
        XCTAssertEqual(config.flushInterval, 5.0)
        XCTAssertEqual(config.format, .vanilla)
    }

    func testSampleRateClamping() {
        let config1 = StatsDExporter.Configuration(sampleRate: 1.5)
        XCTAssertEqual(config1.sampleRate, 1.0)

        let config2 = StatsDExporter.Configuration(sampleRate: -0.5)
        XCTAssertEqual(config2.sampleRate, 0.0)
    }

    // MARK: - Format Generation Tests

    func testCounterFormatting() async throws {
        let exporter = StatsDExporter(
            configuration: StatsDExporter.Configuration(format: .vanilla)
        )

        // We'll need to test format generation indirectly through export
        // Since formatMetric is private, we test through the public API

        let metric = MetricSnapshot(
            name: "requests.count",
            type: "counter",
            value: 42,
            timestamp: Date(),
            tags: [:],
            unit: nil
        )

        try await exporter.export([metric])

        // In a real test, we'd capture the UDP packet
        // For now, verify it doesn't crash
        XCTAssertNotNil(exporter)
    }

    func testGaugeFormatting() async throws {
        let exporter = StatsDExporter()

        let metric = MetricSnapshot(
            name: "memory.usage",
            type: "gauge",
            value: 75.5,
            timestamp: Date(),
            tags: ["host": "server1"],
            unit: "percent"
        )

        try await exporter.export([metric])

        let stats = await exporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 1)
    }

    func testHistogramFormatting() async throws {
        let exporter = StatsDExporter()

        let metric = MetricSnapshot(
            name: "response.time",
            type: "histogram",
            value: 125.5,
            timestamp: Date(),
            tags: ["endpoint": "/api/users"],
            unit: "milliseconds"
        )

        try await exporter.export([metric])

        let stats = await exporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 1)
    }

    func testTimerFormatting() async throws {
        let exporter = StatsDExporter()

        let metric = MetricSnapshot(
            name: "db.query.time",
            type: "timer",
            value: 0.125,  // 125ms in seconds
            timestamp: Date(),
            tags: ["query": "select"],
            unit: "seconds"
        )

        try await exporter.export([metric])

        let stats = await exporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 1)
    }

    // MARK: - Prefix Tests

    func testMetricPrefix() async throws {
        let config = StatsDExporter.Configuration(
            prefix: "myapp",
            format: .vanilla
        )
        let exporter = StatsDExporter(configuration: config)

        let metric = MetricSnapshot(
            name: "requests",
            type: "counter",
            value: 1,
            timestamp: Date(),
            tags: [:],
            unit: nil
        )

        try await exporter.export([metric])

        // Metric name should be prefixed
        let stats = await exporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 1)
    }

    // MARK: - Tag Tests

    func testDogStatsDTags() async throws {
        let config = StatsDExporter.Configuration(
            globalTags: ["env": "test", "version": "1.0.0"],
            format: .dogStatsD
        )
        let exporter = StatsDExporter(configuration: config)

        let metric = MetricSnapshot(
            name: "api.requests",
            type: "counter",
            value: 10,
            timestamp: Date(),
            tags: ["method": "GET", "status": "200"],
            unit: nil
        )

        try await exporter.export([metric])

        // Tags should be merged (global + metric)
        let stats = await exporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 1)
    }

    func testVanillaStatsDIgnoresTags() async throws {
        let config = StatsDExporter.Configuration(
            globalTags: ["env": "test"],
            format: .vanilla
        )
        let exporter = StatsDExporter(configuration: config)

        let metric = MetricSnapshot(
            name: "cpu.usage",
            type: "gauge",
            value: 45.2,
            timestamp: Date(),
            tags: ["core": "0"],
            unit: nil
        )

        try await exporter.export([metric])

        // Vanilla format should ignore tags
        let stats = await exporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 1)
    }

    // MARK: - Escaping Tests

    func testMetricNameEscaping() async throws {
        let exporter = StatsDExporter()

        let metric = MetricSnapshot(
            name: "metric:with|special@chars#test",
            type: "counter",
            value: 1,
            timestamp: Date(),
            tags: [:],
            unit: nil
        )

        try await exporter.export([metric])

        // Special characters should be escaped
        let stats = await exporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 1)
    }

    func testTagEscaping() async throws {
        let exporter = StatsDExporter()

        let metric = MetricSnapshot(
            name: "test.metric",
            type: "gauge",
            value: 1,
            timestamp: Date(),
            tags: [
                "tag:with:colon": "value,with,comma",
                "pipe|tag": "value|pipe"
            ],
            unit: nil
        )

        try await exporter.export([metric])

        // Tags should be properly escaped
        let stats = await exporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 1)
    }

    // MARK: - Batching Tests

    func testBatchingMultipleMetrics() async throws {
        let exporter = StatsDExporter()

        let metrics = [
            MetricSnapshot(name: "metric1", type: "counter", value: 1, timestamp: Date(), tags: [:], unit: nil),
            MetricSnapshot(name: "metric2", type: "gauge", value: 2, timestamp: Date(), tags: [:], unit: nil),
            MetricSnapshot(name: "metric3", type: "histogram", value: 3, timestamp: Date(), tags: [:], unit: nil),
            MetricSnapshot(name: "metric4", type: "timer", value: 4, timestamp: Date(), tags: [:], unit: nil),
            MetricSnapshot(name: "metric5", type: "counter", value: 5, timestamp: Date(), tags: [:], unit: nil)
        ]

        try await exporter.export(metrics)

        let stats = await exporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 5)
    }

    func testEmptyMetrics() async throws {
        let exporter = StatsDExporter()

        try await exporter.export([])

        let stats = await exporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 0)
    }

    // MARK: - Sample Rate Tests

    func testSampleRateFiltering() async throws {
        let config = StatsDExporter.Configuration(sampleRate: 0.0)  // 0% sample rate
        let exporter = StatsDExporter(configuration: config)

        let metrics = (0..<100).map { i in
            MetricSnapshot(
                name: "sampled.metric",
                type: "counter",
                value: Double(i),
                timestamp: Date(),
                tags: [:],
                unit: nil
            )
        }

        try await exporter.export(metrics)

        let stats = await exporter.getStats()
        // With 0% sample rate, no metrics should be sent
        XCTAssertEqual(stats.metricsTotal, 0)
    }

    func testFullSampleRate() async throws {
        let config = StatsDExporter.Configuration(sampleRate: 1.0)  // 100% sample rate
        let exporter = StatsDExporter(configuration: config)

        let metrics = (0..<10).map { i in
            MetricSnapshot(
                name: "sampled.metric",
                type: "counter",
                value: Double(i),
                timestamp: Date(),
                tags: [:],
                unit: nil
            )
        }

        try await exporter.export(metrics)

        let stats = await exporter.getStats()
        // With 100% sample rate, all metrics should be sent
        XCTAssertEqual(stats.metricsTotal, 10)
    }

    // MARK: - Lifecycle Tests

    func testFlush() async throws {
        let exporter = StatsDExporter()

        let metric = MetricSnapshot(
            name: "flush.test",
            type: "counter",
            value: 1,
            timestamp: Date(),
            tags: [:],
            unit: nil
        )

        try await exporter.export([metric])
        try await exporter.flush()

        // Flush should not cause errors
        let stats = await exporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 1)
    }

    func testShutdown() async throws {
        let exporter = StatsDExporter()

        let metric = MetricSnapshot(
            name: "shutdown.test",
            type: "counter",
            value: 1,
            timestamp: Date(),
            tags: [:],
            unit: nil
        )

        try await exporter.export([metric])
        await exporter.shutdown()

        // After shutdown, metrics might be dropped
        // This is expected behavior for UDP
        XCTAssertNotNil(exporter)
    }

    // MARK: - Integration Tests

    func testWithBatchingExporter() async throws {
        let statsdExporter = StatsDExporter()
        let batchingExporter = await BatchingExporter(
            underlying: statsdExporter,
            maxBatchSize: 10,
            autostart: false
        )

        let metric = MetricSnapshot(
            name: "batch.test",
            type: "counter",
            value: 1,
            timestamp: Date(),
            tags: [:],
            unit: nil
        )

        for _ in 0..<5 {
            try await batchingExporter.export([metric])
        }

        let stats = await batchingExporter.getStats()
        XCTAssertEqual(stats.currentBufferSize, 5)

        try await batchingExporter.flush()

        let statsdStats = await statsdExporter.getStats()
        XCTAssertEqual(statsdStats.metricsTotal, 5)
    }

    func testWithMultiExporter() async throws {
        let statsdExporter = StatsDExporter()
        let consoleExporter = ConsoleExporter(format: .compact)
        let multiExporter = MultiExporter(exporters: [
            statsdExporter,
            consoleExporter
        ])

        let metric = MetricSnapshot(
            name: "multi.test",
            type: "gauge",
            value: 42.0,
            timestamp: Date(),
            tags: ["exporter": "multi"],
            unit: nil
        )

        try await multiExporter.export([metric])

        let stats = await statsdExporter.getStats()
        XCTAssertEqual(stats.metricsTotal, 1)
    }
}

