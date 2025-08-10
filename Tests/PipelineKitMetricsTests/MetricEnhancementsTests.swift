import XCTest
@testable import PipelineKitMetrics
@testable import PipelineKitCore

final class MetricEnhancementsTests: XCTestCase {

    // MARK: - Unit Conversion Tests

    func testTimeUnitConversion() {
        // Test all time conversions
        XCTAssertEqual(MetricUnit.seconds.convert(1, to: .milliseconds), 1000)
        XCTAssertEqual(MetricUnit.milliseconds.convert(1000, to: .seconds), 1)
        XCTAssertEqual(MetricUnit.minutes.convert(1, to: .seconds), 60)
        XCTAssertEqual(MetricUnit.hours.convert(1, to: .minutes), 60)
        XCTAssertEqual(MetricUnit.microseconds.convert(1000, to: .milliseconds), 1)
        XCTAssertEqual(MetricUnit.nanoseconds.convert(1000, to: .microseconds), 1)
    }

    func testByteUnitConversion() {
        // Test all byte conversions
        XCTAssertEqual(MetricUnit.kilobytes.convert(1, to: .bytes), 1024)
        XCTAssertEqual(MetricUnit.megabytes.convert(1, to: .kilobytes), 1024)
        XCTAssertEqual(MetricUnit.gigabytes.convert(1, to: .megabytes), 1024)
        XCTAssertEqual(MetricUnit.terabytes.convert(1, to: .gigabytes), 1024)
        XCTAssertEqual(MetricUnit.bytes.convert(1024, to: .kilobytes), 1)
    }

    func testRateUnitConversion() {
        // Test rate conversions
        XCTAssertEqual(MetricUnit.perMinute.convert(60, to: .perSecond), 1)
        XCTAssertEqual(MetricUnit.perHour.convert(3600, to: .perSecond), 1)
        XCTAssertEqual(MetricUnit.perSecond.convert(1, to: .perMinute), 60)
    }

    func testTemperatureConversion() {
        // Celsius to Fahrenheit
        XCTAssertEqual(MetricUnit.celsius.convert(0, to: .fahrenheit)!, 32, accuracy: 0.01)
        XCTAssertEqual(MetricUnit.celsius.convert(100, to: .fahrenheit)!, 212, accuracy: 0.01)

        // Fahrenheit to Celsius
        XCTAssertEqual(MetricUnit.fahrenheit.convert(32, to: .celsius)!, 0, accuracy: 0.01)
        XCTAssertEqual(MetricUnit.fahrenheit.convert(212, to: .celsius)!, 100, accuracy: 0.01)

        // Kelvin conversions
        XCTAssertEqual(MetricUnit.celsius.convert(0, to: .kelvin)!, 273.15, accuracy: 0.01)
        XCTAssertEqual(MetricUnit.kelvin.convert(273.15, to: .celsius)!, 0, accuracy: 0.01)
    }

    func testIncompatibleUnitConversion() {
        // Cannot convert between different categories
        XCTAssertNil(MetricUnit.bytes.convert(100, to: .seconds))
        XCTAssertNil(MetricUnit.celsius.convert(100, to: .bytes))
        XCTAssertNil(MetricUnit.perSecond.convert(100, to: .megabytes))
    }

    func testMetricValueConversion() {
        let value = MetricValue(1024, unit: .bytes)
        let converted = value.converted(to: .kilobytes)

        XCTAssertNotNil(converted)
        XCTAssertEqual(converted?.value, 1)
        XCTAssertEqual(converted?.unit, .kilobytes)
    }

    func testSuggestedUnit() {
        // Time suggestions
        XCTAssertEqual(MetricUnit.nanoseconds.suggestedUnit(for: 500), .nanoseconds)
        XCTAssertEqual(MetricUnit.nanoseconds.suggestedUnit(for: 5000), .microseconds)
        XCTAssertEqual(MetricUnit.nanoseconds.suggestedUnit(for: 5_000_000), .milliseconds)
        XCTAssertEqual(MetricUnit.nanoseconds.suggestedUnit(for: 5_000_000_000), .seconds)

        // Byte suggestions
        XCTAssertEqual(MetricUnit.bytes.suggestedUnit(for: 512), .bytes)
        XCTAssertEqual(MetricUnit.bytes.suggestedUnit(for: 5120), .kilobytes)
        XCTAssertEqual(MetricUnit.bytes.suggestedUnit(for: 5_242_880), .megabytes)
    }

    func testHumanizedFormatting() {
        let largeBytes = MetricValue(5_242_880, unit: .bytes)
        XCTAssertEqual(largeBytes.humanized(decimalPlaces: 1), "5.0 megabytes")

        let smallTime = MetricValue(0.0005, unit: .seconds)
        XCTAssertEqual(smallTime.humanized(decimalPlaces: 0), "500 microseconds")
    }

    // MARK: - Tag Builder DSL Tests

    func testTagBuilderBasic() {
        @MetricTagBuilder
        func buildTags() -> MetricTags {
            MetricTag("key1", "value1")
            MetricTag("key2", "value2")
        }

        let tags = buildTags()
        XCTAssertEqual(tags["key1"], "value1")
        XCTAssertEqual(tags["key2"], "value2")
    }

    func testTagBuilderConditional() {
        let includeDebug = true

        @MetricTagBuilder
        func buildTags() -> MetricTags {
            MetricTag.environment("production")
            MetricTag.service("api")

            if includeDebug {
                MetricTag("debug", "true")
            }
        }

        let tags = buildTags()
        XCTAssertEqual(tags["environment"], "production")
        XCTAssertEqual(tags["service"], "api")
        XCTAssertEqual(tags["debug"], "true")
    }

    func testTagBuilderConvenienceMethods() {
        @MetricTagBuilder
        func buildTags() -> MetricTags {
            MetricTag.environment("staging")
            MetricTag.service("worker")
            MetricTag.version("1.2.3")
            MetricTag.host("server-01")
            MetricTag.region("us-west-2")
            MetricTag.status("success")
            MetricTag.method("POST")
            MetricTag.endpoint("/api/users")
            MetricTag.cacheStatus(true)
        }

        let tags = buildTags()
        XCTAssertEqual(tags["environment"], "staging")
        XCTAssertEqual(tags["service"], "worker")
        XCTAssertEqual(tags["version"], "1.2.3")
        XCTAssertEqual(tags["host"], "server-01")
        XCTAssertEqual(tags["region"], "us-west-2")
        XCTAssertEqual(tags["status"], "success")
        XCTAssertEqual(tags["method"], "POST")
        XCTAssertEqual(tags["endpoint"], "/api/users")
        XCTAssertEqual(tags["cache"], "hit")
    }

    func testMetricWithTagBuilder() {
        let counter = Metric<Counter>.counter("test.counter", value: 10) {
            MetricTag.environment("test")
            MetricTag.service("unit-test")
        }

        XCTAssertEqual(counter.tags["environment"], "test")
        XCTAssertEqual(counter.tags["service"], "unit-test")
    }

    func testCommonTagSets() {
        let envTags = CommonTags.environment(env: "prod", service: "api", version: "2.0.0")
        XCTAssertEqual(envTags["environment"], "prod")
        XCTAssertEqual(envTags["service"], "api")
        XCTAssertEqual(envTags["version"], "2.0.0")

        let httpTags = CommonTags.httpRequest(method: "GET", endpoint: "/health", status: 200)
        XCTAssertEqual(httpTags["method"], "GET")
        XCTAssertEqual(httpTags["endpoint"], "/health")
        XCTAssertEqual(httpTags["status"], "200")
    }

    // MARK: - Clock Tests

    func testSystemClock() {
        let clock = SystemClock()
        let now1 = clock.now()
        Thread.sleep(forTimeInterval: 0.01)
        let now2 = clock.now()

        XCTAssertTrue(now2 > now1)
    }

    func testMockClock() async {
        let clock = MockClock(startTime: Date(timeIntervalSince1970: 1000))

        let time1 = await clock.now()
        XCTAssertEqual(time1.timeIntervalSince1970, 1000)

        await clock.advance(by: 60)
        let time2 = await clock.now()
        XCTAssertEqual(time2.timeIntervalSince1970, 1060)

        await clock.set(to: Date(timeIntervalSince1970: 2000))
        let time3 = await clock.now()
        XCTAssertEqual(time3.timeIntervalSince1970, 2000)
    }

    func testMockClockAutoAdvance() async {
        let clock = MockClock(startTime: Date(timeIntervalSince1970: 0))
        await clock.setAutoAdvance(10)

        let time1 = await clock.now()
        XCTAssertEqual(time1.timeIntervalSince1970, 0)

        let time2 = await clock.now()
        XCTAssertEqual(time2.timeIntervalSince1970, 10)

        let time3 = await clock.now()
        XCTAssertEqual(time3.timeIntervalSince1970, 20)
    }

    func testClockMeasure() async {
        let clock = MockClock(startTime: Date(timeIntervalSince1970: 0))
        await clock.setAutoAdvance(1)

        let (result, duration) = await clock.measure {
            return 42
        }

        XCTAssertEqual(result, 42)
        XCTAssertEqual(duration, 1)
    }

    // MARK: - Enhanced Operations Tests

    func testCounterDecrement() {
        let counter = Metric<Counter>.counter("test", value: 10)
        let decremented = counter.decrement(by: 3)
        XCTAssertEqual(decremented.value.value, 7)
    }

    func testCounterRate() {
        let counter = Metric<Counter>.counter("requests", value: 1000)
        let rate = counter.rate(over: 60, unit: .perSecond)
        XCTAssertEqual(rate.value.value, 1000.0 / 60.0, accuracy: 0.01)
        XCTAssertEqual(rate.value.unit, .perSecond)

        let ratePerMinute = counter.rate(over: 60, unit: .perMinute)
        XCTAssertEqual(ratePerMinute.value.value, 1000.0, accuracy: 0.01)
    }

    func testGaugeCompareAndSet() {
        let gauge = Metric<Gauge>.gauge("test", value: 10)

        let updated = gauge.compareAndSet(expecting: 10, newValue: 20)
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.value.value, 20)

        let failed = gauge.compareAndSet(expecting: 30, newValue: 40)
        XCTAssertNil(failed)
    }

    func testGaugeDelta() {
        let gauge1 = Metric<Gauge>.gauge("memory", value: 100)
        let gauge2 = Metric<Gauge>.gauge("memory", value: 75)

        let delta = gauge1.delta(from: gauge2)
        XCTAssertEqual(delta, 25)
    }

    func testHistogramBucketing() {
        let linearBuckets = BucketingPolicy.linear(start: 0, width: 10, count: 5)
        XCTAssertEqual(linearBuckets.boundaries(), [0, 10, 20, 30, 40])

        let exponentialBuckets = BucketingPolicy.exponential(start: 1, factor: 2, count: 4)
        XCTAssertEqual(exponentialBuckets.boundaries(), [1, 2, 4, 8])

        let logBuckets = BucketingPolicy.logarithmic(start: 1, count: 4)
        XCTAssertEqual(logBuckets.boundaries(), [1, 2, 4, 8])

        let customBuckets = BucketingPolicy.custom(boundaries: [5, 10, 25, 50, 100])
        XCTAssertEqual(customBuckets.boundaries(), [5, 10, 25, 50, 100])
    }

    // MARK: - Snapshot Optimization Tests

    func testSnapshotBuilder() {
        var builder = MetricSnapshotBuilder()
        let snapshot = builder
            .withName("test.metric")
            .withType("counter")
            .withValue(42)
            .withTag("env", "test")
            .withUnit("count")
            .build()

        XCTAssertEqual(snapshot.name, "test.metric")
        XCTAssertEqual(snapshot.type, "counter")
        XCTAssertEqual(snapshot.value, 42)
        XCTAssertEqual(snapshot.tags["env"], "test")
        XCTAssertEqual(snapshot.unit, "count")
    }

    func testCOWMetricSnapshot() {
        let original = MetricSnapshot(name: "test", type: "gauge", value: 10)
        let cow = COWMetricSnapshot(original)

        let modified = cow.withValue(20)
        XCTAssertEqual(cow.snapshot.value, 10)
        XCTAssertEqual(modified.snapshot.value, 20)
    }

    func testMetricSnapshotView() {
        let snapshot = MetricSnapshot(name: "test", type: "counter", value: 100)
        let view = MetricSnapshotView(from: snapshot)

        XCTAssertEqual(view.name, snapshot.name)
        XCTAssertEqual(view.value, snapshot.value)

        let matches = view.matches { $0.value > 50 }
        XCTAssertTrue(matches)
    }

    func testBatchOperations() {
        let snapshots = [
            MetricSnapshot(name: "metric1", type: "counter", value: 10),
            MetricSnapshot(name: "metric2", type: "gauge", value: 20),
            MetricSnapshot(name: "metric3", type: "counter", value: 30)
        ]

        let filtered = MetricSnapshotBatch.filter(snapshots) { view in
            view.type == "counter"
        }
        XCTAssertEqual(filtered.count, 2)

        let values = MetricSnapshotBatch.map(snapshots) { view in
            view.value
        }
        XCTAssertEqual(values, [10, 20, 30])

        let grouped = MetricSnapshotBatch.groupBy(snapshots) { view in
            view.type
        }
        XCTAssertEqual(grouped["counter"]?.count, 2)
        XCTAssertEqual(grouped["gauge"]?.count, 1)
    }
}

