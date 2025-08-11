import XCTest
@testable import PipelineKitCore

final class MetricsAggregatorTests: XCTestCase {

    // MARK: - Basic Statistics Tests

    func testCalculateBasicStatistics() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(collector: collector)

        // Add test data
        for i in 1...10 {
            await collector.recordHistogram("test.metric", value: Double(i), tags: [:])
        }

        await aggregator.updateHistory()

        let stats = await aggregator.calculateStatistics(
            metricName: "test.metric",
            tags: [:]
        )

        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.count, 10)
        XCTAssertEqual(stats?.mean, 5.5)
        XCTAssertEqual(stats?.min, 1.0)
        XCTAssertEqual(stats?.max, 10.0)
        XCTAssertEqual(stats?.sum, 55.0)
        XCTAssertEqual(stats?.median, 5.0)
    }

    func testPercentileCalculation() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(
            collector: collector,
            configuration: .init(percentiles: [0.5, 0.75, 0.9, 0.95, 0.99])
        )

        // Add 100 data points
        for i in 1...100 {
            await collector.recordHistogram("test.metric", value: Double(i), tags: [:])
        }

        await aggregator.updateHistory()

        let stats = await aggregator.calculateStatistics(
            metricName: "test.metric",
            tags: [:]
        )

        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.percentiles[0.5], 50.0)
        XCTAssertEqual(stats?.percentiles[0.9], 90.0)
        XCTAssertEqual(stats?.percentiles[0.95], 95.0)
        XCTAssertEqual(stats?.percentiles[0.99], 99.0)
    }

    // MARK: - Time Series Analysis Tests

    func testMovingAverage() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(collector: collector)

        // Add time series data
        for i in 0..<10 {
            await collector.recordGauge("test.gauge", value: Double(i * 10), tags: [:])
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        await aggregator.updateHistory()

        let movingAvg = await aggregator.movingAverage(
            metricName: "test.gauge",
            window: 0.5 // 500ms window
        )

        XCTAssertNotNil(movingAvg)
        // Should average the recent values
        XCTAssertGreaterThan(movingAvg!, 40.0) // Later values are higher
    }

    func testExponentialMovingAverage() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(collector: collector)

        // Add increasing values
        for i in 0..<10 {
            await collector.recordGauge("test.gauge", value: Double(i), tags: [:])
        }

        await aggregator.updateHistory()

        let ema = await aggregator.exponentialMovingAverage(
            metricName: "test.gauge",
            alpha: 0.3
        )

        XCTAssertNotNil(ema)
        // EMA should be weighted towards recent values
        XCTAssertGreaterThan(ema!, 4.5)
    }

    func testTrendDetection() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(collector: collector)

        // Add linearly increasing data
        for i in 0..<20 {
            await collector.recordGauge(
                "test.trend",
                value: Double(i * 2 + 10), // y = 2x + 10
                tags: [:]
            )
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        await aggregator.updateHistory()

        let trend = await aggregator.detectTrend(
            metricName: "test.trend",
            window: 2.0
        )

        XCTAssertNotNil(trend)
        XCTAssertEqual(trend?.direction, .increasing)
        XCTAssertGreaterThan(trend?.slope ?? 0, 0)
        XCTAssertGreaterThan(trend?.rSquared ?? 0, 0.9) // Good linear fit
    }

    // MARK: - Outlier Detection Tests

    func testOutlierDetectionIQR() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(
            collector: collector,
            configuration: .init(
                detectOutliers: true,
                outlierMethod: .iqr(multiplier: 1.5)
            )
        )

        // Add normal data with outliers
        let normalValues = Array(1...20).map { Double($0) }
        let outliers = [100.0, 150.0, -50.0]

        for value in normalValues + outliers {
            await collector.recordHistogram("test.outlier", value: value, tags: [:])
        }

        await aggregator.updateHistory()

        let stats = await aggregator.calculateStatistics(
            metricName: "test.outlier",
            tags: [:]
        )

        XCTAssertNotNil(stats)
        XCTAssertFalse(stats?.outliers.isEmpty ?? true)
        XCTAssertTrue(stats?.outliers.contains(100.0) ?? false)
        XCTAssertTrue(stats?.outliers.contains(150.0) ?? false)
        XCTAssertTrue(stats?.outliers.contains(-50.0) ?? false)
    }

    func testOutlierDetectionZScore() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(
            collector: collector,
            configuration: .init(
                detectOutliers: true,
                outlierMethod: .zscore(threshold: 2.0)
            )
        )

        // Add data with clear outliers
        for _ in 0..<100 {
            await collector.recordHistogram(
                "test.zscore",
                value: Double.random(in: 45...55), // Normal range
                tags: [:]
            )
        }

        // Add outliers
        await collector.recordHistogram("test.zscore", value: 100.0, tags: [:])
        await collector.recordHistogram("test.zscore", value: 0.0, tags: [:])

        await aggregator.updateHistory()

        let stats = await aggregator.calculateStatistics(
            metricName: "test.zscore",
            tags: [:]
        )

        XCTAssertNotNil(stats)
        XCTAssertTrue(stats?.outliers.contains(100.0) ?? false)
        XCTAssertTrue(stats?.outliers.contains(0.0) ?? false)
    }

    // MARK: - Correlation Analysis Tests

    func testCorrelationAnalysis() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(
            collector: collector,
            configuration: .init(calculateCorrelations: true)
        )

        // Add correlated data
        for i in 0..<20 {
            let x = Double(i)
            let y = x * 2 + Double.random(in: -1...1) // y ≈ 2x with noise

            await collector.recordGauge("metric.x", value: x, tags: [:])
            await collector.recordGauge("metric.y", value: y, tags: [:])
        }

        await aggregator.updateHistory()

        let correlation = await aggregator.correlation(
            metric1: "metric.x",
            metric2: "metric.y"
        )

        XCTAssertNotNil(correlation)
        XCTAssertGreaterThan(correlation ?? 0, 0.9) // Strong positive correlation
    }

    func testNegativeCorrelation() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(collector: collector)

        // Add negatively correlated data
        for i in 0..<20 {
            let x = Double(i)
            let y = -x + 20 // y = -x + 20

            await collector.recordGauge("metric.a", value: x, tags: [:])
            await collector.recordGauge("metric.b", value: y, tags: [:])
        }

        await aggregator.updateHistory()

        let correlation = await aggregator.correlation(
            metric1: "metric.a",
            metric2: "metric.b"
        )

        XCTAssertNotNil(correlation)
        XCTAssertLessThan(correlation ?? 0, -0.9) // Strong negative correlation
    }

    // MARK: - Report Generation Tests

    func testMetricReportGeneration() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(collector: collector)

        // Add varied data
        for i in 0..<50 {
            let value = Double(i) + Double.random(in: -5...5)
            await collector.recordHistogram("test.report", value: value, tags: ["env": "test"])
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }

        await aggregator.updateHistory()

        let report = await aggregator.generateReport(
            metricName: "test.report",
            tags: ["env": "test"],
            window: 2.0
        )

        XCTAssertNotNil(report)
        XCTAssertEqual(report?.metricName, "test.report")
        XCTAssertNotNil(report?.statistics)
        XCTAssertNotNil(report?.trend)
        XCTAssertNotNil(report?.movingAverage)
    }

    func testAnomalyDetection() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(
            collector: collector,
            configuration: .init(
                detectOutliers: true,
                outlierMethod: .iqr(multiplier: 1.5)
            )
        )

        // Add normal data
        for i in 0..<50 {
            await collector.recordHistogram(
                "normal.metric",
                value: Double(i % 10 + 45),
                tags: [:]
            )
        }

        // Add anomalous data
        await collector.recordHistogram("anomaly.metric", value: 50.0, tags: [:])
        await collector.recordHistogram("anomaly.metric", value: 200.0, tags: [:]) // Anomaly
        await collector.recordHistogram("anomaly.metric", value: 55.0, tags: [:])

        await aggregator.updateHistory()

        let anomalies = await aggregator.findAnomalies()

        XCTAssertFalse(anomalies.isEmpty)
        XCTAssertTrue(anomalies.contains { $0.metricName == "anomaly.metric" })
    }

    // MARK: - Window-based Analysis Tests

    func testWindowedStatistics() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(collector: collector)

        // Add data over time
        for i in 0..<30 {
            await collector.recordGauge(
                "windowed.metric",
                value: Double(i),
                tags: [:]
            )
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        await aggregator.updateHistory()

        // Get statistics for last 1 second
        let stats = await aggregator.calculateStatistics(
            metricName: "windowed.metric",
            window: 1.0
        )

        XCTAssertNotNil(stats)
        // Should only include recent values
        XCTAssertLessThan(stats?.count ?? 0, 30)
        XCTAssertGreaterThan(stats?.mean ?? 0, 15.0) // Recent values are higher
    }

    // MARK: - Performance Tests

    func testLargeDatasetPerformance() async throws {
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(
            collector: collector,
            configuration: .init(maxHistorySize: 10000)
        )

        measure {
            Task {
                // Add 10k data points
                for i in 0..<10000 {
                    await collector.recordHistogram(
                        "perf.metric",
                        value: Double(i % 100),
                        tags: ["batch": String(i / 1000)]
                    )
                }

                await aggregator.updateHistory()

                // Calculate statistics
                _ = await aggregator.calculateStatistics(
                    metricName: "perf.metric",
                    tags: ["batch": "5"]
                )
            }
        }
    }
}

