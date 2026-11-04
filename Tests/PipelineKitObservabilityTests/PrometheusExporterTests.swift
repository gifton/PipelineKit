//
//  PrometheusExporterTests.swift
//  PipelineKitObservabilityTests
//
//  Tests for Prometheus metrics export
//

import XCTest
@testable import PipelineKitObservability

final class PrometheusExporterTests: XCTestCase {
    func testExplicitNonMillisecondTimerUnitsAreRejectedWithoutRelabelingValues() async {
        let storage = MetricsStorage()
        await storage.record(.init(name: "seconds", type: "timer", value: 1, unit: "s"))
        await storage.record(.init(name: "legacy", type: "timer", value: 1))
        await storage.record(.timer("current", duration: 0.002))
        let result = await PrometheusExporter(metricsStorage: storage).exportWithDiagnostics()
        XCTAssertEqual(sampleLines(result.text), ["current_milliseconds 2", "legacy_milliseconds 1"])
        XCTAssertEqual(result.rejectedSeries.map { $0.reason.rawValue }, ["unsupportedUnit"])
    }

    func testScrapeSurvivesDrainAndPruningUntilExplicitClear() async {
        let storage = MetricsStorage()
        let exporter = PrometheusExporter(metricsStorage: storage)
        await storage.record(.counter("requests", value: 2))
        _ = await storage.drain()
        let drained = await exporter.export()
        XCTAssertEqual(sampleLines(drained), ["requests_total 2"])
        await storage.record(.init(name: "requests", type: "counter", value: 3, timestamp: 0))
        await storage.pruneOlderThan(0)
        let pruned = await exporter.export()
        XCTAssertEqual(sampleLines(pruned), ["requests_total 5"])
        await storage.clear()
        let cleared = await exporter.export()
        XCTAssertEqual(cleared, "")
        await storage.record(.counter("requests", value: 1))
        let restarted = await exporter.export()
        XCTAssertEqual(sampleLines(restarted), ["requests_total 1"])
    }

    func testNegativeCounterUpdateIsRetainedRawButCannotDecreaseScrape() async {
        let storage = MetricsStorage()
        await storage.record(.counter("requests", value: 10))
        await storage.record(.counter("requests", value: -4))
        await storage.record(.counter("requests", value: 2))
        let raw = await storage.getAll()
        XCTAssertEqual(raw.map(\.value), [10, -4, 2])
        let output = await PrometheusExporter(metricsStorage: storage).export()
        XCTAssertEqual(sampleLines(output), ["requests_total 12"])
        let diagnostics = await storage.diagnostics
        XCTAssertEqual(diagnostics.rejectedPrometheusUpdates, 1)
    }

    func testOverflowingCounterAndHistogramUpdatesLeaveFiniteScrapeState() async {
        let storage = MetricsStorage()
        for kind in ["counter", "histogram"] {
            await storage.record(.init(name: kind, type: kind, value: Double.greatestFiniteMagnitude))
            await storage.record(.init(name: kind, type: kind, value: Double.greatestFiniteMagnitude))
        }
        let output = await PrometheusExporter(metricsStorage: storage).export()
        XCTAssertTrue(output.contains("counter_total 1.7976931348623157e+308"))
        XCTAssertTrue(output.contains("histogram_sum 1.7976931348623157e+308"))
        XCTAssertTrue(output.contains("histogram_count 1\n"))
        XCTAssertFalse(output.contains(" inf"))
        let diagnostics = await storage.diagnostics
        XCTAssertEqual(diagnostics.rejectedPrometheusUpdates, 2)
        let raw = await storage.getAll()
        XCTAssertEqual(raw.count, 4)
        let aggregate = await storage.aggregate()
        XCTAssertTrue(aggregate.allSatisfy { $0.value?.isFinite == true })
    }

    func testRejectionsAreObservableAndDoNotHideUnrelatedValidFamilies() async {
        let storage = MetricsStorage()
        await storage.record(.gauge("invalid name", value: 1))
        await storage.record(.gauge("a.b", value: 1))
        await storage.record(.gauge("a_b", value: 2))
        await storage.record(.gauge("valid", value: 7))
        let result = await PrometheusExporter(metricsStorage: storage).exportWithDiagnostics()
        XCTAssertEqual(sampleLines(result.text), ["valid 7"])
        XCTAssertEqual(result.rejectedSeries.count, 3)
        XCTAssertEqual(result.rejectedSeries.filter { $0.reason == .conflictingDefinition }.count, 2)
        XCTAssertEqual(result.rejectedSeries.filter { $0.reason == .invalidMetricName }.count, 1)
    }

    func testRepeatedCounterUpdatesProduceOneCumulativeSamplePerSeries() async {
        let storage = MetricsStorage()
        await storage.record(.counter("requests", value: 2, tags: ["tenant": "a"]))
        await storage.record(.init(name: "requests", type: "counter", tags: ["tenant": "a"]))
        await storage.record(.counter("requests", value: 7, tags: ["tenant": "b"]))
        let exporter = PrometheusExporter(metricsStorage: storage)

        let output = await exporter.export()
        XCTAssertEqual(sampleLines(output), ["requests_total{tenant=\"a\"} 3", "requests_total{tenant=\"b\"} 7"])
        let repeated = await exporter.export()
        XCTAssertEqual(repeated, output)
        let aggregated = await exporter.exportAggregated()
        XCTAssertEqual(aggregated, output)
    }

    func testRepeatedGaugeUpdatesKeepLatestValueForEachSeries() async {
        let storage = MetricsStorage()
        await storage.record(.gauge("memory", value: 2, tags: ["tenant": "a"]))
        await storage.record(.gauge("memory", value: 7, tags: ["tenant": "b"]))
        await storage.record(.gauge("memory", value: 5, tags: ["tenant": "a"]))
        let exporter = PrometheusExporter(metricsStorage: storage)

        let output = await exporter.export()
        XCTAssertEqual(sampleLines(output), ["memory{tenant=\"a\"} 5", "memory{tenant=\"b\"} 7"])
    }

    func testCounterTotalSurvivesHistoryEvictionBeforeFirstScrape() async {
        let storage = MetricsStorage(maxSnapshotsPerMetric: 1)
        await storage.record(.counter("requests", value: 2))
        await storage.record(.counter("requests", value: 3))
        let exporter = PrometheusExporter(metricsStorage: storage)

        let first = await exporter.export()
        XCTAssertEqual(sampleLines(first), ["requests_total 5"])
        await storage.record(.counter("requests", value: 7))
        let second = await exporter.export()
        XCTAssertEqual(sampleLines(second), ["requests_total 12"])
    }

    func testHistogramAccumulatesSumCountAndInfiniteBucketPerSeries() async {
        let storage = MetricsStorage(maxSnapshotsPerMetric: 1)
        await storage.record(.init(name: "sizes", type: "histogram", value: 2, tags: ["tenant": "a"]))
        await storage.record(.init(name: "sizes", type: "histogram", value: 3, tags: ["tenant": "a"]))
        await storage.record(.init(name: "sizes", type: "histogram", value: 7, tags: ["tenant": "b"]))
        let exporter = PrometheusExporter(metricsStorage: storage)

        let output = await exporter.export()
        XCTAssertEqual(sampleLines(output), [
            "sizes_bucket{le=\"+Inf\",tenant=\"a\"} 2",
            "sizes_bucket{le=\"+Inf\",tenant=\"b\"} 1",
            "sizes_count{tenant=\"a\"} 2",
            "sizes_count{tenant=\"b\"} 1",
            "sizes_sum{tenant=\"a\"} 5",
            "sizes_sum{tenant=\"b\"} 7"
        ])
        let repeated = await exporter.export()
        XCTAssertEqual(repeated, output)
    }

    func testInvalidMetricAndLabelNamesCannotInjectExpositionLines() async {
        let invalidNames = ["", "1invalid", "bad name", "bad\ninjected 1", "bad/metric", "métric"]
        for name in invalidNames {
            let storage = MetricsStorage()
            await storage.record(.gauge(name, value: 1))
            let output = await PrometheusExporter(metricsStorage: storage).export()
            XCTAssertEqual(output, "", "Unexpected exposition for metric name \(name.debugDescription)")
        }
        for label in ["", "1invalid", "bad-name", "bad:label", "bad\ninjected", "__name__"] {
            let storage = MetricsStorage()
            await storage.record(.gauge("valid", value: 1, tags: [label: "value"]))
            let output = await PrometheusExporter(metricsStorage: storage).export()
            XCTAssertEqual(output, "", "Unexpected exposition for label name \(label.debugDescription)")
        }
    }

    func testConflictingWireFamiliesAreRejectedRegardlessOfRecordOrder() async {
        let collisions: [[MetricSnapshot]] = [
            [.gauge("a.b", value: 1), .gauge("a_b", value: 2)],
            [.counter("requests", value: 1), .gauge("requests_total", value: 2)],
            [.timer("duration", duration: 1), .gauge("duration_milliseconds", value: 2)],
            [.init(name: "sizes", type: "histogram", value: 1), .gauge("sizes_sum", value: 2)],
            [.gauge("shared", value: 1, unit: "bytes"), .gauge("shared", value: 2, unit: "items")],
            [.gauge("shared", value: 1), .counter("shared", value: 2)]
        ]
        for inputs in collisions {
            for sequence in [inputs, Array(inputs.reversed())] {
                let storage = MetricsStorage()
                for snapshot in sequence { await storage.record(snapshot) }
                let output = await PrometheusExporter(metricsStorage: storage).export()
                XCTAssertEqual(output, "", "Conflicting families must not depend on dictionary/record order")
            }
        }
    }

    func testEmptyAndAbsentLabelsDoNotProduceEquivalentDuplicateSamples() async {
        let storage = MetricsStorage()
        await storage.record(.gauge("load", value: 1))
        await storage.record(.gauge("load", value: 2, tags: ["optional": ""]))
        let output = await PrometheusExporter(metricsStorage: storage).export()
        XCTAssertEqual(output, "")
    }

    func testHistogramRejectsUserBucketBoundaryLabel() async {
        let storage = MetricsStorage()
        await storage.record(.init(name: "sizes", type: "histogram", value: 1, tags: ["le": "user"]))
        let output = await PrometheusExporter(metricsStorage: storage).export()
        XCTAssertEqual(output, "")
    }

    private func sampleLines(_ output: String) -> [String] {
        output.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init).sorted()
    }

    // MARK: - Counter Tests

    func testExportCounter() async throws {
        let storage = await MetricsStorage()
        let counter = MetricSnapshot.counter("requests", value: 42, tags: ["endpoint": "/api"])
        await storage.record(counter)

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        XCTAssertTrue(output.contains("# TYPE requests_total counter"))
        XCTAssertTrue(output.contains("requests_total{endpoint=\"/api\"} 42"))
    }

    func testExportCounterWithoutTags() async throws {
        let storage = await MetricsStorage()
        let counter = MetricSnapshot.counter("simple_counter", value: 100)
        await storage.record(counter)

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        XCTAssertTrue(output.contains("# TYPE simple_counter_total counter"))
        XCTAssertTrue(output.contains("simple_counter_total 100"))
    }

    func testExportMultipleCountersWithSameName() async throws {
        let storage = await MetricsStorage()

        await storage.record(MetricSnapshot.counter("requests", value: 10, tags: ["endpoint": "/api"]))
        await storage.record(MetricSnapshot.counter("requests", value: 20, tags: ["endpoint": "/users"]))

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        // Should have single TYPE declaration
        let typeCount = output.components(separatedBy: "# TYPE requests_total counter").count - 1
        XCTAssertEqual(typeCount, 1)

        // Should have both metric lines
        XCTAssertTrue(output.contains("requests_total{endpoint=\"/api\"} 10"))
        XCTAssertTrue(output.contains("requests_total{endpoint=\"/users\"} 20"))
    }

    // MARK: - Gauge Tests

    func testExportGauge() async throws {
        let storage = await MetricsStorage()
        let gauge = MetricSnapshot.gauge("memory", value: 75.5, unit: "percentage")
        await storage.record(gauge)

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        XCTAssertTrue(output.contains("# TYPE memory gauge"))
        XCTAssertTrue(output.contains("memory 75.5"))
    }

    func testExportGaugeWithTags() async throws {
        let storage = await MetricsStorage()
        let gauge = MetricSnapshot.gauge(
            "cpu_usage",
            value: 45.2,
            tags: ["host": "server1", "core": "0"],
            unit: "percent"
        )
        await storage.record(gauge)

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        XCTAssertTrue(output.contains("# TYPE cpu_usage gauge"))
        // Tags should be sorted alphabetically
        XCTAssertTrue(output.contains("cpu_usage{core=\"0\",host=\"server1\"} 45.2"))
    }

    // MARK: - Timer Tests

    func testExportTimer() async throws {
        let storage = await MetricsStorage()
        let timer = MetricSnapshot.timer("query_duration", duration: 0.1255) // 125.5ms
        await storage.record(timer)

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        XCTAssertTrue(output.contains("# TYPE query_duration_milliseconds gauge"))
        XCTAssertTrue(output.contains("query_duration_milliseconds 125.5"))
    }

    func testExportTimerWithTags() async throws {
        let storage = await MetricsStorage()
        let timer = MetricSnapshot.timer(
            "request_duration",
            duration: 0.05,
            tags: ["handler": "CreateUser", "status": "success"]
        )
        await storage.record(timer)

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        XCTAssertTrue(output.contains("# TYPE request_duration_milliseconds gauge"))
        XCTAssertTrue(output.contains("request_duration_milliseconds{handler=\"CreateUser\",status=\"success\"} 50"))
    }

    // MARK: - Name Sanitization Tests

    func testNameSanitization() async throws {
        let storage = await MetricsStorage()
        let counter = MetricSnapshot.counter("api.request-count", value: 1)
        await storage.record(counter)

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        // Dots and dashes should be replaced with underscores
        XCTAssertTrue(output.contains("api_request_count_total"))
        XCTAssertFalse(output.contains("api.request-count"))
    }

    func testComplexNameSanitization() async throws {
        let storage = await MetricsStorage()
        let gauge = MetricSnapshot.gauge("my-app.metrics.cpu-usage", value: 50)
        await storage.record(gauge)

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        XCTAssertTrue(output.contains("my_app_metrics_cpu_usage"))
    }

    // MARK: - Label Escaping Tests

    func testLabelValueEscaping() async throws {
        let storage = await MetricsStorage()
        let counter = MetricSnapshot.counter(
            "requests",
            value: 1,
            tags: ["path": "/api/\"test\"", "desc": "line1\nline2"]
        )
        await storage.record(counter)

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        // Quotes and newlines should be escaped
        XCTAssertTrue(output.contains("desc=\"line1\\nline2\""))
        XCTAssertTrue(output.contains("path=\"/api/\\\"test\\\"\""))
    }

    func testBackslashEscaping() async throws {
        let storage = await MetricsStorage()
        let gauge = MetricSnapshot.gauge(
            "path_metric",
            value: 1,
            tags: ["path": "C:\\Users\\test"]
        )
        await storage.record(gauge)

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        XCTAssertTrue(output.contains("path=\"C:\\\\Users\\\\test\""))
    }

    // MARK: - Mixed Metrics Tests

    func testExportMixedMetrics() async throws {
        let storage = await MetricsStorage()

        await storage.record(MetricSnapshot.counter("api_requests", value: 100))
        await storage.record(MetricSnapshot.gauge("memory_usage", value: 512.0))
        await storage.record(MetricSnapshot.timer("db_query", duration: 0.025))

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        // Should have all three metric types
        XCTAssertTrue(output.contains("# TYPE api_requests_total counter"))
        XCTAssertTrue(output.contains("# TYPE memory_usage gauge"))
        XCTAssertTrue(output.contains("# TYPE db_query_milliseconds gauge"))

        // Should have all metric values
        XCTAssertTrue(output.contains("api_requests_total 100"))
        XCTAssertTrue(output.contains("memory_usage 512"))
        XCTAssertTrue(output.contains("db_query_milliseconds 25"))
    }

    // MARK: - Empty Storage Tests

    func testExportEmptyStorage() async throws {
        let storage = await MetricsStorage()
        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        XCTAssertEqual(output, "")
    }

    // MARK: - Aggregation Tests

    func testExportAggregated() async throws {
        let storage = await MetricsStorage()

        // Add multiple counter values
        await storage.record(MetricSnapshot.counter("requests", value: 10))
        await storage.record(MetricSnapshot.counter("requests", value: 20))
        await storage.record(MetricSnapshot.counter("requests", value: 30))

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.exportAggregated()

        // Should aggregate counters by summing
        XCTAssertTrue(output.contains("# TYPE requests_total counter"))
        XCTAssertTrue(output.contains("requests_total 60"))
    }

    func testExportAggregatedGauges() async throws {
        let storage = await MetricsStorage()

        // Add multiple gauge values - should keep latest
        await storage.record(MetricSnapshot.gauge("temperature", value: 20.0))
        await storage.record(MetricSnapshot.gauge("temperature", value: 22.5))
        await storage.record(MetricSnapshot.gauge("temperature", value: 21.0))

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.exportAggregated()

        // Should keep latest gauge value
        XCTAssertTrue(output.contains("# TYPE temperature gauge"))
        XCTAssertTrue(output.contains("temperature 21"))
    }

    // MARK: - Format Compliance Tests

    func testPrometheusFormatCompliance() async throws {
        let storage = await MetricsStorage()

        await storage.record(MetricSnapshot.counter(
            "http_requests",
            value: 1547,
            tags: ["endpoint": "/users", "method": "GET"]
        ))

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        // First line should be TYPE comment
        XCTAssertTrue(lines[0].hasPrefix("# TYPE"))

        // Second line should be metric with tags
        XCTAssertTrue(lines[1].contains("http_requests_total{"))
        XCTAssertTrue(lines[1].contains("endpoint=\"/users\""))
        XCTAssertTrue(lines[1].contains("method=\"GET\""))
        XCTAssertTrue(lines[1].hasSuffix(" 1547"))
    }

    func testTagOrdering() async throws {
        let storage = await MetricsStorage()

        await storage.record(MetricSnapshot.counter(
            "requests",
            value: 1,
            tags: ["z_tag": "last", "a_tag": "first", "m_tag": "middle"]
        ))

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        // Tags should be alphabetically sorted
        XCTAssertTrue(output.contains("{a_tag=\"first\",m_tag=\"middle\",z_tag=\"last\"}"))
    }

    // MARK: - Histogram Tests

    func testExportHistogram() async throws {
        let storage = await MetricsStorage()
        let histogram = MetricSnapshot(
            name: "request_duration",
            type: "histogram",
            value: 6000,
            tags: [:],
            unit: "ms"
        )
        await storage.record(histogram)

        let exporter = PrometheusExporter(metricsStorage: storage)
        let output = await exporter.export()

        XCTAssertTrue(output.contains("# TYPE request_duration histogram"))
        XCTAssertTrue(output.contains("request_duration_sum 6000"))
        XCTAssertTrue(output.contains("request_duration_count 1"))
    }
}
