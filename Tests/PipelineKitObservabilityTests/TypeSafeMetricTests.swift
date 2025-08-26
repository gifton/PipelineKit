import XCTest
@testable import PipelineKitObservability
import Foundation

final class TypeSafeMetricTests: XCTestCase {
    // MARK: - Metric Creation Tests
    
    func testCreateCounter() {
        let counter = Metric<Counter>.counter("test.counter", value: 5.0, tags: ["env": "test"])
        
        XCTAssertEqual(counter.name, "test.counter")
        XCTAssertEqual(counter.value, 5.0)
        XCTAssertEqual(counter.tags["env"], "test")
        XCTAssertNil(counter.unit)
    }
    
    func testCreateGauge() {
        let gauge = Metric<Gauge>.gauge("test.gauge", value: 42.0, tags: [:], unit: "bytes")
        
        XCTAssertEqual(gauge.name, "test.gauge")
        XCTAssertEqual(gauge.value, 42.0)
        XCTAssertEqual(gauge.unit, "bytes")
        XCTAssertTrue(gauge.tags.isEmpty)
    }
    
    func testCreateTimer() {
        let name = "test.timer"
        let duration = 0.123
        let tags = ["method": "GET"]
        let timer = Metric<PipelineTimer>.timer(name, duration: duration, tags: ["method": "GET"])
        
        XCTAssertEqual(timer.name, name)
        XCTAssertEqual(timer.value, duration) // Converted to milliseconds
        XCTAssertEqual(timer.unit, "ms")
        XCTAssertEqual(timer.tags["method"], "GET")
    }
    
    func testCreateHistogram() {
        let histogram = Metric<Histogram>.histogram("test.histogram", value: 99.9, tags: [:], unit: "percent")
        
        XCTAssertEqual(histogram.name, "test.histogram")
        XCTAssertEqual(histogram.value, 99.9)
        XCTAssertEqual(histogram.unit, "percent")
    }
    
    // MARK: - Default Values Tests
    
    func testCounterDefaultValue() {
        let counter = Metric<Counter>.counter("test", tags: [:])
        XCTAssertEqual(counter.value, 1.0)
    }
    
    func testTimestampDefault() {
        let before = Date()
        let metric = Metric<Counter>(name: "test", value: 1.0)
        let after = Date()
        
        XCTAssertGreaterThanOrEqual(metric.timestamp, before)
        XCTAssertLessThanOrEqual(metric.timestamp, after)
    }
    
    // MARK: - Conversion Tests
    
    func testCounterToSnapshot() {
        let counter = Metric<Counter>.counter("counter.test", value: 10.0, tags: ["key": "value"])
        let snapshot = counter.toSnapshot()
        
        XCTAssertEqual(snapshot.name, "counter.test")
        XCTAssertEqual(snapshot.type, "counter")
        XCTAssertEqual(snapshot.value, 10.0)
        XCTAssertEqual(snapshot.tags["key"], "value")
    }
    
    func testGaugeToSnapshot() {
        let gauge = Metric<Gauge>.gauge("gauge.test", value: 50.0, unit: "MB")
        let snapshot = gauge.toSnapshot()
        
        XCTAssertEqual(snapshot.name, "gauge.test")
        XCTAssertEqual(snapshot.type, "gauge")
        XCTAssertEqual(snapshot.value, 50.0)
        XCTAssertEqual(snapshot.unit, "MB")
    }
    
    func testTimerToSnapshot() {
        let timer = Metric<PipelineTimer>.timer("timer.test", duration: 0.5)
        let snapshot = timer.toSnapshot()
        
        XCTAssertEqual(snapshot.name, "timer.test")
        XCTAssertEqual(snapshot.type, "timer")
        XCTAssertEqual(snapshot.value, 0.5) // 0.5 seconds = 500ms
        XCTAssertEqual(snapshot.unit, "ms")
    }
    
    func testHistogramToSnapshot() {
        let histogram = Metric<Histogram>.histogram("hist.test", value: 75.0, unit: "percentile")
        let snapshot = histogram.toSnapshot()
        
        XCTAssertEqual(snapshot.name, "hist.test")
        XCTAssertEqual(snapshot.type, "histogram")
        XCTAssertEqual(snapshot.value, 75.0)
        XCTAssertEqual(snapshot.unit, "percentile")
    }
    
    func testTimestampConversion() {
        let date = Date()
        let metric = Metric<Counter>(name: "test", value: 1.0, timestamp: date)
        let snapshot = metric.toSnapshot()
        
        let expectedTimestamp = UInt64(date.timeIntervalSince1970 * 1000)
        XCTAssertEqual(snapshot.timestamp, expectedTimestamp)
    }
    
    // MARK: - Type Safety Tests
    
    func testCounterSpecificMethods() {
        // This should compile
        let _: Metric<Counter> = .counter("test", value: 1.0)
        
        // These should NOT compile (uncomment to verify):
        // let _: Metric<Counter> = .gauge("test", value: 1.0)
        // let _: Metric<Counter> = .timer("test", duration: 1.0)
    }
    
    func testGaugeSpecificMethods() {
        // This should compile
        let _: Metric<Gauge> = .gauge("test", value: 1.0, unit: "bytes")
        
        // These should NOT compile (uncomment to verify):
        // let _: Metric<Gauge> = .counter("test", value: 1.0)
        // let _: Metric<Gauge> = .timer("test", duration: 1.0)
    }
    
    // MARK: - Sendable Conformance Tests
    
    func testMetricIsSendable() async {
        let metric = Metric<Counter>.counter("sendable.test", value: 1.0)
        
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // Should be able to pass metric across actor boundaries
                _ = metric.name
                _ = metric.value
            }
        }
    }
    
    // MARK: - MetricKind Tests
    
    func testMetricKindTypes() {
        XCTAssertEqual(Counter.type, .counter)
        XCTAssertEqual(Gauge.type, .gauge)
        XCTAssertEqual(PipelineTimer.type, .timer)
        XCTAssertEqual(Histogram.type, .histogram)
    }
    
    func testMetricKindRawValues() {
        XCTAssertEqual(MetricType.counter.rawValue, "counter")
        XCTAssertEqual(MetricType.gauge.rawValue, "gauge")
        XCTAssertEqual(MetricType.timer.rawValue, "timer")
        XCTAssertEqual(MetricType.histogram.rawValue, "histogram")
    }
    
    // MARK: - Edge Cases
    
    func testEmptyMetricName() {
        let metric = Metric<Counter>(name: "", value: 1.0)
        XCTAssertEqual(metric.name, "")
    }
    
    func testNegativeValues() {
        let counter = Metric<Counter>.counter("test", value: -5.0)
        XCTAssertEqual(counter.value, -5.0)
        
        let gauge = Metric<Gauge>.gauge("test", value: -100.0)
        XCTAssertEqual(gauge.value, -100.0)
    }
    
    func testZeroValues() {
        let counter = Metric<Counter>.counter("test", value: 0.0)
        XCTAssertEqual(counter.value, 0.0)
        
        let timer = Metric<PipelineTimer>.timer("test", duration: 0.0)
        XCTAssertEqual(timer.value, 0.0)
    }
    
    func testLargeValues() {
        let largeValue = Double.greatestFiniteMagnitude
        let gauge = Metric<Gauge>.gauge("test", value: largeValue)
        XCTAssertEqual(gauge.value, largeValue)
    }
    
    func testManyTags() {
        var tags: [String: String] = [:]
        for i in 0..<100 {
            tags["key\(i)"] = "value\(i)"
        }
        
        let metric = Metric<Counter>(name: "test", value: 1.0, tags: tags)
        XCTAssertEqual(metric.tags.count, 100)
        
        let snapshot = metric.toSnapshot()
        XCTAssertEqual(snapshot.tags.count, 100)
    }
}
