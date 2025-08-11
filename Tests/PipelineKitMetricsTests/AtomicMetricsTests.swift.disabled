import XCTest
import Atomics
@testable import PipelineKitMetrics
@testable import PipelineKitCore

final class AtomicMetricsTests: XCTestCase {

    // MARK: - Atomic Counter Tests

    func testAtomicCounterIncrement() async {
        let counter = Metric<Counter>.atomic("test.counter")

        let newValue = await counter.increment(by: 5)
        XCTAssertEqual(newValue, 5)

        let value = await counter.value
        XCTAssertEqual(value, 5)
    }

    func testAtomicCounterConcurrentIncrement() async {
        let counter = Metric<Counter>.atomic("concurrent.counter")
        let iterations = 1000

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<iterations {
                        await counter.increment()
                    }
                }
            }
        }

        let finalValue = await counter.value
        XCTAssertEqual(finalValue, Double(10 * iterations))
    }

    func testAtomicCounterDecrement() async {
        let counter = Metric<Counter>.atomic("test.counter")
        await counter.increment(by: 10)

        let newValue = await counter.decrement(by: 3)
        XCTAssertEqual(newValue, 7)
    }

    func testAtomicCounterReset() async {
        let counter = Metric<Counter>.atomic("test.counter")
        await counter.increment(by: 100)
        await counter.reset()

        let value = await counter.value
        XCTAssertEqual(value, 0)
    }

    func testAtomicCounterGetAndReset() async {
        let counter = Metric<Counter>.atomic("test.counter")
        await counter.increment(by: 50)

        let oldValue = await counter.getAndReset()
        XCTAssertEqual(oldValue, 50)

        let newValue = await counter.value
        XCTAssertEqual(newValue, 0)
    }

    // MARK: - Atomic Gauge Tests

    func testAtomicGaugeSet() async {
        let gauge = Metric<Gauge>.atomic("test.gauge", initialValue: 10)

        await gauge.set(to: 25.5)
        let value = await gauge.value
        XCTAssertEqual(value, 25.5)
    }

    func testAtomicGaugeAdjust() async {
        let gauge = Metric<Gauge>.atomic("test.gauge", initialValue: 100)

        let increased = await gauge.adjust(by: 25)
        XCTAssertEqual(increased, 125)

        let decreased = await gauge.adjust(by: -50)
        XCTAssertEqual(decreased, 75)
    }

    func testAtomicGaugeCompareAndSet() async {
        let gauge = Metric<Gauge>.atomic("test.gauge", initialValue: 10)

        // Should succeed
        let success = await gauge.compareAndSet(expecting: 10, newValue: 20)
        XCTAssertTrue(success)

        let value1 = await gauge.value
        XCTAssertEqual(value1, 20)

        // Should fail
        let failure = await gauge.compareAndSet(expecting: 10, newValue: 30)
        XCTAssertFalse(failure)

        let value2 = await gauge.value
        XCTAssertEqual(value2, 20)
    }

    func testAtomicGaugeGetAndSet() async {
        let gauge = Metric<Gauge>.atomic("test.gauge", initialValue: 100)

        let oldValue = await gauge.getAndSet(200)
        XCTAssertEqual(oldValue, 100)

        let newValue = await gauge.value
        XCTAssertEqual(newValue, 200)
    }

    func testAtomicGaugeUpdate() async {
        let gauge = Metric<Gauge>.atomic("test.gauge", initialValue: 10)

        let result = await gauge.update { value in
            value * 2 + 5
        }
        XCTAssertEqual(result, 25)

        let value = await gauge.value
        XCTAssertEqual(value, 25)
    }

    func testAtomicGaugeConcurrentUpdate() async {
        let gauge = Metric<Gauge>.atomic("concurrent.gauge", initialValue: 0)
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<iterations {
                        await gauge.adjust(by: 1)
                    }
                }
            }
        }

        let finalValue = await gauge.value
        XCTAssertEqual(finalValue, Double(10 * iterations))
    }

    // MARK: - Snapshot Tests

    func testAtomicMetricSnapshot() async {
        let counter = Metric<Counter>.atomic("snapshot.counter", tags: ["env": "test"])
        await counter.increment(by: 42)

        let snapshot = await counter.snapshot()
        XCTAssertEqual(snapshot.name, "snapshot.counter")
        XCTAssertEqual(snapshot.type, "counter")
        XCTAssertEqual(snapshot.value, 42)
        XCTAssertEqual(snapshot.tags["env"], "test")
        XCTAssertEqual(snapshot.unit, "count")
    }

    func testAtomicMetricToRegularMetric() async {
        let atomicGauge = Metric<Gauge>.atomic("conversion.gauge", initialValue: 75.5, unit: .percent)
        let regularMetric = await atomicGauge.toMetric()

        XCTAssertEqual(regularMetric.name.value, "conversion.gauge")
        XCTAssertEqual(regularMetric.value.value, 75.5)
        XCTAssertEqual(regularMetric.value.unit, .percent)
    }

    // MARK: - Tag Operations

    func testAtomicMetricWithTags() async {
        let counter = Metric<Counter>.atomic("tagged.counter", tags: ["initial": "value"])
        let tagged = await counter.with(tags: ["additional": "tag", "initial": "updated"])

        await tagged.increment(by: 10)

        let snapshot = await tagged.snapshot()
        XCTAssertEqual(snapshot.tags["initial"], "updated")
        XCTAssertEqual(snapshot.tags["additional"], "tag")
        XCTAssertEqual(snapshot.value, 10)
    }

    // MARK: - Performance Tests

    func testAtomicCounterPerformance() {
        let counter = AtomicCounterStorage()

        measure {
            for _ in 0..<100_000 {
                _ = counter.increment(by: 1)
            }
        }
    }

    func testAtomicGaugePerformance() {
        let gauge = AtomicGaugeStorage()

        measure {
            for i in 0..<100_000 {
                gauge.store(Double(i))
            }
        }
    }

    func testCompareAndSetPerformance() {
        let gauge = AtomicGaugeStorage(initialValue: 0)

        measure {
            for i in 0..<10_000 {
                let expected = Double(i)
                let new = Double(i + 1)
                _ = gauge.compareExchange(expected: expected, desired: new)
            }
        }
    }
}

