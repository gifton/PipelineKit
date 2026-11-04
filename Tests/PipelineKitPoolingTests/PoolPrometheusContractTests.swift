import Foundation
import XCTest
@testable import PipelineKitPooling

@MainActor
final class PoolPrometheusContractTests: XCTestCase {
    func testNormalizationGeneratedNamesAndKindsRejectEveryConflictingSeries() async {
        let collisions: [[(String, String)]] = [
            [("gauge", "a.b"), ("gauge", "a_b")],
            [("gauge", "a-b"), ("gauge", "a_b")],
            [("histogram", "duration"), ("gauge", "duration_sum")],
            [("summary", "duration"), ("counter", "duration_count")],
            [("counter", "same"), ("gauge", "same")],
            [("histogram", "same"), ("summary", "same")]
        ]
        for collision in collisions {
            for reversed in [false, true] {
                let metrics = PoolObservability()
                await metrics.setGauge("keep", value: 9)
                for (kind, name) in reversed ? Array(collision.reversed()) : collision {
                    switch kind {
                    case "counter": await metrics.incrementCounter(name)
                    case "gauge": await metrics.setGauge(name, value: 1)
                    case "histogram": await metrics.recordHistogram(name, value: 1)
                    default: await metrics.recordSummary(name, value: 1)
                    }
                }
                let result = await metrics.captureSnapshot().prometheusFormatWithDiagnostics()
                XCTAssertEqual(result.rejectedSeriesCount, 2, "\(collision), reversed=\(reversed)")
                XCTAssertEqual(result.text, "# TYPE keep gauge\nkeep 9\n\n")
            }
        }
    }

    func testEmptyAndAbsentLabelsCannotExportDuplicateSamples() async {
        for reversed in [false, true] {
            let metrics = PoolObservability()
            let labels = [["pool": "a"], ["pool": "a", "optional": ""]]
            for values in reversed ? Array(labels.reversed()) : labels {
                await metrics.setGauge("objects", value: 1, labels: values)
            }
            let snapshot = await metrics.captureSnapshot()
            XCTAssertEqual(snapshot.gauges.count, 2, "Storage retains distinct caller identities")
            let result = snapshot.prometheusFormatWithDiagnostics()
            XCTAssertEqual(result.rejectedSeriesCount, 2)
            XCTAssertTrue(result.text.isEmpty)
        }
    }

    func testMalformedAndReservedLabelsRejectWholeSeries() async {
        let metrics = PoolObservability()
        await metrics.setGauge("valid", value: 1, labels: ["pool": "normal"])
        await metrics.setGauge("1invalid", value: 2)
        await metrics.setGauge("invalid label", value: 3)
        await metrics.setGauge("bad_label", value: 4, labels: ["bad-key": "x"])
        await metrics.incrementCounter("reserved", labels: ["__name__": "x"])
        await metrics.recordHistogram("hist", value: 5, labels: ["quantile": "caller"])
        await metrics.recordSummary("summary", value: 6, labels: ["quantile": "caller"])
        let result = await metrics.captureSnapshot().prometheusFormatWithDiagnostics()
        XCTAssertEqual(result.rejectedSeriesCount, 6)
        XCTAssertEqual(result.text, "# TYPE valid gauge\nvalid{pool=\"normal\"} 1\n\n")
    }

    func testSnapshotKeysKeepRawNamesDistinctFromLabelSyntax() async {
        let metrics = PoolObservability()
        await metrics.setGauge("name{a=\"x\"}", value: 2)
        await metrics.setGauge("name", value: 3, labels: ["a": "x"])
        let first = await metrics.getGauge("name{a=\"x\"}")
        let second = await metrics.getGauge("name", labels: ["a": "x"])
        let snapshot = await metrics.captureSnapshot()
        XCTAssertEqual(first ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(second ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(snapshot.gauges.count, 2)
        let result = snapshot.prometheusFormatWithDiagnostics()
        XCTAssertEqual(result.rejectedSeriesCount, 1)
        XCTAssertEqual(result.text, "# TYPE name gauge\nname{a=\"x\"} 3\n\n")
    }

    func testDistributionScrapesKeepCumulativeTotalsAndWindowQuantiles() async {
        let metrics = PoolObservability(distributionWindowSize: 1)
        await metrics.recordHistogram("histogram", value: 1, labels: ["pool": "a"])
        await metrics.recordSummary("summary", value: 2, labels: ["pool": "a"])
        _ = await metrics.captureSnapshot().prometheusFormat()
        await metrics.recordHistogram("histogram", value: 3, labels: ["pool": "a"])
        await metrics.recordSummary("summary", value: 4, labels: ["pool": "a"])
        let result = await metrics.captureSnapshot().prometheusFormatWithDiagnostics()
        XCTAssertEqual(result.rejectedSeriesCount, 0)
        XCTAssertTrue(result.text.contains("# TYPE histogram summary\n"))
        XCTAssertTrue(result.text.contains("histogram_count{pool=\"a\"} 2\n"))
        XCTAssertTrue(result.text.contains("histogram_sum{pool=\"a\"} 4\n"))
        XCTAssertTrue(result.text.contains("histogram{pool=\"a\",quantile=\"0.5\"} 3\n"))
        XCTAssertTrue(result.text.contains("summary_count{pool=\"a\"} 2\n"))
        XCTAssertTrue(result.text.contains("summary_sum{pool=\"a\"} 6\n"))
        XCTAssertTrue(result.text.contains("summary{pool=\"a\",quantile=\"0.5\"} 4\n"))
    }

    func testNonFiniteSamplesAreReportedWithoutPoisoningOtherSeries() async {
        let snapshot = MetricsSnapshot(
            timestamp: Date(), counters: [:],
            gauges: ["keep": 1, "nan": .nan, "positive_infinity": .infinity, "negative_infinity": -.infinity],
            histograms: ["overflow": HistogramStats(count: 2, sum: .infinity, mean: .infinity,
                                                   min: 1, max: 1, p50: 1, p95: 1, p99: 1)],
            summaries: [:], labels: [:], metricNames: [:]
        )
        let result = snapshot.prometheusFormatWithDiagnostics()
        XCTAssertEqual(result.rejectedSeriesCount, 4)
        XCTAssertEqual(result.text, "# TYPE keep gauge\nkeep 1\n\n")
    }
}
