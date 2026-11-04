import Foundation
import XCTest
@testable import PipelineKitPooling

@MainActor
final class PoolTelemetryContractTests: XCTestCase {
    func testHistogramKeepsLifetimeAggregatesAndRecentQuantiles() async throws {
        let metrics = PoolObservability()
        let name = "histogram_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        for value in 1...10_000 {
            await metrics.recordHistogram(name, value: Double(value))
        }
        let result = await metrics.getHistogram(name)
        let stats = try XCTUnwrap(result)
        XCTAssertEqual(stats.count, 10_000)
        XCTAssertEqual(stats.sum, 50_005_000, accuracy: 0.001)
        XCTAssertEqual(stats.mean, 5000.5, accuracy: 0.001)
        XCTAssertEqual(stats.min, 1, accuracy: 0.001)
        XCTAssertEqual(stats.max, 10_000, accuracy: 0.001)
        XCTAssertEqual(stats.p50, 9500, accuracy: 0.001)
        XCTAssertEqual(stats.p95, 9950, accuracy: 0.001)
        XCTAssertEqual(stats.p99, 9990, accuracy: 0.001)
    }

    func testSummaryKeepsLifetimeTotalsAfterWindowWraps() async throws {
        let metrics = PoolObservability()
        let name = "summary_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        for value in 1...1001 {
            await metrics.recordSummary(name, value: Double(value))
        }
        let result = await metrics.getSummary(name)
        let stats = try XCTUnwrap(result)
        XCTAssertEqual(stats.count, 1001)
        XCTAssertEqual(stats.sum, 501501, accuracy: 0.001)
        XCTAssertEqual(stats.p50, 501, accuracy: 0.001)
    }

    func testLabelDelimitersCannotAliasDistinctSeries() async {
        let metrics = PoolObservability()
        let name = "identity_\(UUID())"
        let first = ["a": "x,b=y"]
        let second = ["a": "x", "b": "y"]
        await metrics.incrementCounter(name, by: 2, labels: first)
        await metrics.incrementCounter(name, by: 3, labels: second)
        let firstValue = await metrics.getCounter(name, labels: first)
        let secondValue = await metrics.getCounter(name, labels: second)
        XCTAssertEqual(firstValue, 2)
        XCTAssertEqual(secondValue, 3)
    }

    func testPrometheusQuotesLabelsPlacesSuffixesAndMergesQuantiles() async {
        let metrics = PoolObservability()
        let name = "export_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let labels = ["pool": "a\"b\\c\nd", "empty": ""]
        await metrics.incrementCounter(name + "_total", by: 2, labels: labels)
        await metrics.setGauge(name + "_size", value: 4, labels: labels)
        await metrics.recordHistogram(name + "_latency", value: 7, labels: labels)
        await metrics.recordSummary(name + "_summary", value: 8, labels: labels)
        let output = await metrics.captureSnapshot().prometheusFormat()
        let encodedLabels = "empty=\"\",pool=\"a\\\"b\\\\c\\nd\""
        XCTAssertTrue(output.contains("\(name)_total{\(encodedLabels)} 2\n"))
        XCTAssertTrue(output.contains("\(name)_size{\(encodedLabels)} 4\n"))
        XCTAssertTrue(output.contains("\(name)_latency_count{\(encodedLabels)} 1\n"))
        XCTAssertTrue(output.contains("\(name)_latency_sum{\(encodedLabels)} 7\n"))
        XCTAssertTrue(output.contains("\(name)_latency{\(encodedLabels),quantile=\"0.5\"} 7\n"))
        XCTAssertTrue(output.contains("\(name)_summary{\(encodedLabels),quantile=\"0.99\"} 8\n"))
        XCTAssertTrue(output.hasSuffix("\n"))
    }

    func testStartedCollectorReleasesOwnerAndExporterWhenDropped() async throws {
        let firstExport = expectation(description: "first collection exported")
        var exporterLifetime: PoolExporterLifetime? = PoolExporterLifetime()
        let weakExporter = PoolTelemetryWeakReference(value: exporterLifetime)
        var collector: PoolMetricsCollector? = PoolMetricsCollector(collectionInterval: 3600)
        let weakCollector = PoolTelemetryWeakReference(value: collector)
        var thresholds = AlertThresholds()
        thresholds.minHitRate = -.infinity
        thresholds.minEfficiency = -.infinity
        await collector?.configureAlerts(thresholds)
        await collector?.registerExporter { [exporterLifetime = exporterLifetime!] snapshot in
            if snapshot.alert == nil {
                withExtendedLifetime(exporterLifetime) { firstExport.fulfill() }
            }
        }
        exporterLifetime = nil
        await collector?.startCollecting()
        await fulfillment(of: [firstExport], timeout: 2)
        collector = nil
        let deadline = ContinuousClock.now + .seconds(1)
        while weakCollector.value != nil && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNil(weakCollector.value)
        XCTAssertNil(weakExporter.value)
        // Clean up the failing baseline without leaking its task into later tests.
        await weakCollector.value?.stopCollecting()
    }

    func testDistributionRetentionIsBoundedAcrossRepeatedWraps() {
        for capacity in [1, 2, 7, 1000] {
            var distribution = PoolDistribution(capacity: capacity)
            for value in 1...10_000 {
                distribution.record(Double(value))
                XCTAssertLessThanOrEqual(distribution.retainedSampleCount, capacity)
            }
            XCTAssertEqual(distribution.retainedSampleCount, capacity)
            XCTAssertEqual(distribution.histogramStatistics().count, 10_000)
        }
    }

    func testCustomWindowAndResetApplyToBothDistributionKinds() async throws {
        let metrics = PoolObservability(distributionWindowSize: 2)
        for value in [1.0, 2, 3, 4, 5] {
            await metrics.recordHistogram("hist", value: value)
            await metrics.recordSummary("sum", value: value)
        }
        let histogram = await metrics.getHistogram("hist")
        let summary = await metrics.getSummary("sum")
        XCTAssertEqual(try XCTUnwrap(histogram).p50, 4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary).p50, 4, accuracy: 0.001)
        XCTAssertEqual(histogram?.count, 5)
        XCTAssertEqual(summary?.count, 5)
        await metrics.reset()
        await metrics.recordHistogram("hist", value: 9)
        await metrics.recordSummary("sum", value: 8)
        let resetHistogram = await metrics.getHistogram("hist")
        let resetSummary = await metrics.getSummary("sum")
        XCTAssertEqual(resetHistogram?.count, 1)
        XCTAssertEqual(resetSummary?.count, 1)
        XCTAssertEqual(try XCTUnwrap(resetHistogram).sum, 9, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(resetSummary).sum, 8, accuracy: 0.001)
    }

    func testSeriesLimitPreservesAdmittedIdentitiesAndCountsEveryRejection() async {
        let metrics = PoolObservability(maximumSeries: 4)
        await metrics.incrementCounter("same", by: 1)
        await metrics.setGauge("same", value: 2)
        await metrics.recordHistogram("same", value: 3)
        await metrics.recordSummary("same", value: 4)
        for value in 1...20 {
            await metrics.incrementCounter("rejected", labels: ["pool": String(value)])
        }
        await metrics.incrementCounter("same", by: 2)
        let count = await metrics.getCounter("same")
        let dropped = await metrics.droppedSeriesCount
        let snapshot = await metrics.captureSnapshot()
        XCTAssertEqual(count, 3)
        XCTAssertEqual(dropped, 20)
        XCTAssertEqual(snapshot.counters.count + snapshot.gauges.count + snapshot.histograms.count + snapshot.summaries.count, 4)
        await metrics.reset()
        await metrics.incrementCounter("new")
        let resetDropped = await metrics.droppedSeriesCount
        let newCount = await metrics.getCounter("new")
        XCTAssertEqual(resetDropped, 0)
        XCTAssertEqual(newCount, 1)
    }

    func testZeroCapacityAndInvalidDistributionsDoNotRetainSeries() async {
        let zero = PoolObservability(maximumSeries: 0)
        await zero.incrementCounter("counter")
        await zero.setGauge("gauge", value: 1)
        await zero.recordHistogram("histogram", value: 1)
        await zero.recordSummary("summary", value: 1)
        let dropped = await zero.droppedSeriesCount
        let empty = await zero.captureSnapshot()
        XCTAssertEqual(dropped, 4)
        XCTAssertTrue(empty.labels.isEmpty)

        let finite = PoolObservability(maximumSeries: 1)
        for value in [Double.nan, .infinity, -.infinity] {
            await finite.recordHistogram("invalid", value: value)
            await finite.recordSummary("invalid", value: value)
        }
        await finite.recordHistogram("valid", value: 7)
        let invalid = await finite.invalidObservationCount
        let accepted = await finite.getHistogram("valid")
        let rejected = await finite.getSummary("invalid")
        XCTAssertEqual(invalid, 6)
        XCTAssertEqual(accepted?.count, 1)
        XCTAssertNil(rejected)
    }

    func testCounterOverflowSaturatesAndReportsEachOverflowingAddition() async {
        let metrics = PoolObservability()
        await metrics.incrementCounter("large", by: .max)
        await metrics.incrementCounter("large", by: 1)
        await metrics.incrementCounter("large", by: 2)
        let value = await metrics.getCounter("large")
        let overflows = await metrics.saturatedCounterCount
        XCTAssertEqual(value, .max)
        XCTAssertEqual(overflows, 2)
        await metrics.reset()
        let resetOverflows = await metrics.saturatedCounterCount
        XCTAssertEqual(resetOverflows, 0)
    }

    func testInvalidGaugeObservationsNeitherMutateValuesNorConsumeSeriesCapacity() async {
        let metrics = PoolObservability(maximumSeries: 2)
        for value in [Double.nan, .infinity, -.infinity] {
            await metrics.setGauge("invalid", value: value)
            await metrics.incrementGauge("invalid", by: value)
            await metrics.decrementGauge("invalid", by: value)
        }
        await metrics.setGauge("stable", value: 3)
        await metrics.incrementGauge("stable", by: .infinity)
        await metrics.decrementGauge("stable", by: .nan)
        await metrics.setGauge("overflow", value: .greatestFiniteMagnitude)
        await metrics.incrementGauge("overflow", by: .greatestFiniteMagnitude)
        await metrics.decrementGauge("overflow", by: -.greatestFiniteMagnitude)
        let invalid = await metrics.getGauge("invalid")
        let stable = await metrics.getGauge("stable")
        let overflow = await metrics.getGauge("overflow")
        let dropped = await metrics.droppedSeriesCount
        let invalidCount = await metrics.invalidObservationCount
        XCTAssertNil(invalid)
        XCTAssertEqual(stable ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(overflow ?? -1, .greatestFiniteMagnitude, accuracy: Double.greatestFiniteMagnitude.ulp)
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(invalidCount, 13)
    }

    func testOverflowingDistributionSumRejectsObservationWithoutChangingTotals() async throws {
        let metrics = PoolObservability(distributionWindowSize: 1)
        for value in [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude / 2] {
            await metrics.recordHistogram("hist", value: value)
            await metrics.recordSummary("summary", value: value)
        }
        let hist = await metrics.getHistogram("hist")
        let summary = await metrics.getSummary("summary")
        let invalidCount = await metrics.invalidObservationCount
        XCTAssertEqual(hist?.count, 1)
        XCTAssertEqual(summary?.count, 1)
        XCTAssertEqual(try XCTUnwrap(hist).sum, .greatestFiniteMagnitude, accuracy: Double.greatestFiniteMagnitude.ulp)
        XCTAssertEqual(try XCTUnwrap(summary).sum, .greatestFiniteMagnitude, accuracy: Double.greatestFiniteMagnitude.ulp)
        XCTAssertEqual(try XCTUnwrap(hist).p50, .greatestFiniteMagnitude, accuracy: Double.greatestFiniteMagnitude.ulp)
        XCTAssertEqual(try XCTUnwrap(summary).p50, .greatestFiniteMagnitude, accuracy: Double.greatestFiniteMagnitude.ulp)
        XCTAssertEqual(invalidCount, 2)
    }

    func testStatsDSnapshotRepresentsCumulativeCountersAsGauges() async {
        let metrics = PoolObservability()
        await metrics.incrementCounter("total", by: 3)
        let first = await metrics.captureSnapshot().statsdFormat()
        let second = await metrics.captureSnapshot().statsdFormat()
        XCTAssertEqual(first, ["total:3|g"])
        XCTAssertEqual(second, ["total:3|g"])
    }

    func testPoolUtilizationHandlesNonnegativeCountsWhoseSumExceedsInt() async {
        let metrics = PoolObservability()
        await metrics.updatePoolSize(poolName: "large", available: .max, inUse: .max, maxSize: .max)
        let value = await metrics.getGauge("pool_utilization_percent", labels: ["pool": "large"])
        XCTAssertEqual(value ?? -1, 50, accuracy: 0.001)
    }

    func testPoolUtilizationPreservesSignedCountCompatibility() async {
        let metrics = PoolObservability()
        let cases: [(available: Int, inUse: Int, expected: Double)] = [
            (3, 1, 25), (0, 0, 0), (-Int.max + 1, .max, 9.223372036854776e20),
            (.min, .max, 0), (.min, .min, 0)
        ]
        for value in cases {
            await metrics.updatePoolSize(poolName: "signed", available: value.available, inUse: value.inUse, maxSize: .max)
            let actual = await metrics.getGauge("pool_utilization_percent", labels: ["pool": "signed"])
            XCTAssertEqual(actual ?? -1, value.expected, accuracy: max(0.001, abs(value.expected) * 1e-12))
        }
    }
}

private final class PoolExporterLifetime: Sendable {}

struct PoolTelemetryWeakReference<Value: AnyObject> {
    weak var value: Value?
}
