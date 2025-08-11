import XCTest
@testable import PipelineKitMetrics
import PipelineKitCore

final class TypeSafeMetricsTests: XCTestCase {

    // MARK: - Factory Method Tests

    func testCounterCreation() {
        let counter = Metric<Counter>.counter("api.requests", value: 5)

        XCTAssertEqual(counter.name.value, "api.requests")
        XCTAssertEqual(counter.value.value, 5)
        XCTAssertEqual(counter.value.unit, .count)
        XCTAssertTrue(counter.tags.isEmpty)
    }

    func testGaugeCreation() {
        let gauge = Metric<Gauge>.gauge("temperature", value: 22.5, unit: .celsius)

        XCTAssertEqual(gauge.name.value, "temperature")
        XCTAssertEqual(gauge.value.value, 22.5)
        XCTAssertEqual(gauge.value.unit, .celsius)
    }

    func testHistogramCreation() {
        let histogram = Metric<Histogram>.histogram("response.time", value: 125.5)

        XCTAssertEqual(histogram.name.value, "response.time")
        XCTAssertEqual(histogram.value.value, 125.5)
        XCTAssertEqual(histogram.value.unit, .milliseconds)
    }

    func testTimerCreation() {
        let timer = Metric<Timer>.timer("db.query", duration: 45.2, unit: .milliseconds)

        XCTAssertEqual(timer.name.value, "db.query")
        XCTAssertEqual(timer.value.value, 45.2)
        XCTAssertEqual(timer.value.unit, .milliseconds)
    }

    // MARK: - Type-Specific Operation Tests

    func testCounterIncrement() {
        let counter = Metric<Counter>.counter("test", value: 10)
        let incremented = counter.increment(by: 5)

        XCTAssertEqual(incremented.value.value, 15)
        XCTAssertEqual(counter.value.value, 10) // Original unchanged (immutable)
    }

    func testCounterAddition() {
        let counter1 = Metric<Counter>.counter("test", value: 10)
        let counter2 = Metric<Counter>.counter("test", value: 5)
        let sum = counter1 + counter2

        XCTAssertEqual(sum.value.value, 15)
    }

    func testGaugeAdjustment() {
        let gauge = Metric<Gauge>.gauge("test", value: 50)
        let increased = gauge.adjust(by: 10)
        let decreased = gauge.adjust(by: -20)

        XCTAssertEqual(increased.value.value, 60)
        XCTAssertEqual(decreased.value.value, 30)
        XCTAssertEqual(gauge.value.value, 50) // Original unchanged
    }

    func testGaugeClamping() {
        let gauge = Metric<Gauge>.gauge("test", value: 150)
        let clamped = gauge.clamped(min: 0, max: 100)

        XCTAssertEqual(clamped.value.value, 100)
    }

    func testHistogramObservation() {
        let histogram = Metric<Histogram>.histogram("test", value: 100)
        let observed = histogram.observe(200)

        XCTAssertEqual(observed.value.value, 200)
        XCTAssertEqual(histogram.value.value, 100) // Original unchanged
    }

    // MARK: - Common Operation Tests

    func testMetricWithTags() {
        let counter = Metric<Counter>.counter("test")
        let tagged = counter.with(tags: ["env": "prod", "host": "server1"])

        XCTAssertEqual(tagged.tags["env"], "prod")
        XCTAssertEqual(tagged.tags["host"], "server1")
        XCTAssertTrue(counter.tags.isEmpty) // Original unchanged
    }

    func testMetricTimestampUpdate() {
        let oldDate = Date(timeIntervalSince1970: 0)
        let newDate = Date()

        let counter = Metric<Counter>.counter("test", at: oldDate)
        let updated = counter.at(timestamp: newDate)

        XCTAssertEqual(counter.timestamp, oldDate)
        XCTAssertEqual(updated.timestamp, newDate)
    }

    // MARK: - Semantic Type Tests

    func testMetricNameSanitization() {
        let name = MetricName("my metric/name-test")
        XCTAssertEqual(name.value, "my_metric_name_test")
    }

    func testMetricNameWithNamespace() {
        let name = MetricName("requests", namespace: "api")
        XCTAssertEqual(name.fullyQualified, "api.requests")
    }

    func testMetricValueFromLiterals() {
        let floatValue: MetricValue = 3.14
        let intValue: MetricValue = 42

        XCTAssertEqual(floatValue.value, 3.14)
        XCTAssertEqual(intValue.value, 42.0)
        XCTAssertNil(floatValue.unit)
        XCTAssertNil(intValue.unit)
    }

    // MARK: - Unit Conversion Tests

    func testTimeUnitConversion() {
        let unit = MetricUnit.milliseconds

        XCTAssertEqual(unit.convert(1000, to: .seconds), 1.0)
        XCTAssertEqual(unit.convert(1, to: .microseconds), 1000.0)
        XCTAssertNil(unit.convert(1, to: .bytes)) // Incompatible
    }

    func testSizeUnitConversion() {
        let unit = MetricUnit.kilobytes

        XCTAssertEqual(unit.convert(1, to: .bytes), 1024.0)
        XCTAssertEqual(unit.convert(1024, to: .megabytes), 1.0)
        XCTAssertNil(unit.convert(1, to: .seconds)) // Incompatible
    }

    func testTemperatureConversion() {
        let celsius = MetricUnit.celsius

        XCTAssertEqual(celsius.convert(0, to: .fahrenheit), 32.0)
        XCTAssertEqual(celsius.convert(100, to: .fahrenheit), 212.0)
    }

    // MARK: - Bridge Tests

    func testMetricSnapshotConversion() {
        let counter = Metric<Counter>.counter(
            "test.counter",
            value: 42,
            tags: ["env": "test"]
        )

        let snapshot = MetricSnapshot(from: counter)

        XCTAssertEqual(snapshot.name, "test.counter")
        XCTAssertEqual(snapshot.type, "counter")
        XCTAssertEqual(snapshot.value, 42)
        XCTAssertEqual(snapshot.tags["env"], "test")
        XCTAssertEqual(snapshot.unit, "count")
    }

    func testMetricsRecordableProtocol() {
        let counter = Metric<Counter>.counter("test")
        let recordable: MetricsRecordable = counter

        let snapshot = recordable.toSnapshot()
        XCTAssertEqual(snapshot.name, "test")
        XCTAssertEqual(recordable.metricName, "test")
        XCTAssertEqual(recordable.metricType, "counter")
    }

    // MARK: - Timer Specific Tests

    func testTimerMeasurement() {
        let (metric, result) = Metric<Timer>.time("operation") {
            // Simulate work
            Thread.sleep(forTimeInterval: 0.1)
            return 42
        }

        XCTAssertEqual(result, 42)
        XCTAssertGreaterThan(metric.value.value, 99) // At least 99ms
        XCTAssertLessThan(metric.value.value, 200) // But less than 200ms
        XCTAssertEqual(metric.value.unit, .milliseconds)
    }

    func testTimerFromDates() {
        let start = Date()
        let end = start.addingTimeInterval(1.5) // 1.5 seconds later

        let timer = Metric<Timer>.duration(
            "operation",
            from: start,
            to: end,
            unit: .seconds
        )

        XCTAssertEqual(timer.value.value, 1.5, accuracy: 0.01)
        XCTAssertEqual(timer.value.unit, .seconds)
    }

    // MARK: - Collection Operation Tests

    func testCounterSum() {
        let counters = [
            Metric<Counter>.counter("test", value: 10),
            Metric<Counter>.counter("test", value: 20),
            Metric<Counter>.counter("test", value: 30)
        ]

        let sum = counters.sum()
        XCTAssertEqual(sum?.value.value, 60)
    }

    func testGaugeAverage() {
        let gauges = [
            Metric<Gauge>.gauge("test", value: 10),
            Metric<Gauge>.gauge("test", value: 20),
            Metric<Gauge>.gauge("test", value: 30)
        ]

        let average = gauges.average()
        XCTAssertEqual(average?.value.value, 20)
    }

    func testGaugeMinMax() {
        let gauges = [
            Metric<Gauge>.gauge("test", value: 10),
            Metric<Gauge>.gauge("test", value: 5),
            Metric<Gauge>.gauge("test", value: 20)
        ]

        XCTAssertEqual(gauges.minimum()?.value.value, 5)
        XCTAssertEqual(gauges.maximum()?.value.value, 20)
    }

    // MARK: - Compile-Time Safety Tests
    // These tests verify that certain operations are NOT available

    func testCompileTimeSafety() {
        let counter = Metric<Counter>.counter("test")
        let gauge = Metric<Gauge>.gauge("test", value: 50)

        // These should compile
        _ = counter.increment()
        _ = gauge.adjust(by: 10)

        // These should NOT compile (uncomment to verify):
        // _ = counter.adjust(by: 10) // ❌ No such method
        // _ = gauge.increment() // ❌ No such method
        // _ = counter.clamped(min: 0, max: 100) // ❌ No such method
    }

    // MARK: - Performance Tests

    func testMetricCreationPerformance() {
        measure {
            for i in 0..<10000 {
                _ = Metric<Counter>.counter("test.metric.\(i)", value: Double(i))
            }
        }
    }

    func testMetricOperationPerformance() {
        let counter = Metric<Counter>.counter("test", value: 0)

        measure {
            var current = counter
            for _ in 0..<10000 {
                current = current.increment()
            }
        }
    }

    func testSnapshotConversionPerformance() {
        let metrics = (0..<1000).map { i in
            Metric<Counter>.counter("test.\(i)", value: Double(i))
        }

        measure {
            _ = metrics.toSnapshots()
        }
    }
}

