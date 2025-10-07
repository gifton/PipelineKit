import XCTest
import Foundation
@testable import PipelineKitCore

final class MetricsCollectorTests: XCTestCase {
    // MARK: - Mock Collector
    
    /// Mock implementation for testing
    private actor MockMetricsCollector: MetricsCollector {
        var counters: [(name: String, value: Double, tags: [String: String])] = []
        var gauges: [(name: String, value: Double, tags: [String: String])] = []
        var timers: [(name: String, duration: TimeInterval, tags: [String: String])] = []
        var histograms: [(name: String, value: Double, tags: [String: String])] = []
        
        func recordCounter(_ name: String, value: Double, tags: [String: String]) async {
            counters.append((name, value, tags))
        }
        
        func recordGauge(_ name: String, value: Double, tags: [String: String]) async {
            gauges.append((name, value, tags))
        }
        
        func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async {
            timers.append((name, duration, tags))
        }
        
        func recordHistogram(_ name: String, value: Double, tags: [String: String]) async {
            histograms.append((name, value, tags))
        }
        
        func reset() {
            counters.removeAll()
            gauges.removeAll()
            timers.removeAll()
            histograms.removeAll()
        }
    }
    
    // MARK: - Protocol Conformance Tests
    
    func testProtocolRequirements() async {
        let collector: any MetricsCollector = MockMetricsCollector()
        
        // Verify all required methods exist
        await collector.recordCounter("test.counter", value: 1.0, tags: [:])
        await collector.recordGauge("test.gauge", value: 42.0, tags: [:])
        await collector.recordTimer("test.timer", duration: 0.5, tags: [:])
        await collector.recordHistogram("test.histogram", value: 100.0, tags: [:])
    }
    
    // MARK: - Counter Tests
    
    func testRecordCounter() async {
        let collector = MockMetricsCollector()
        
        await collector.recordCounter("commands.executed", value: 1.0,
                                     tags: ["command": "CreateUser"])
        
        let counters = await collector.counters
        XCTAssertEqual(counters.count, 1)
        XCTAssertEqual(counters[0].name, "commands.executed")
        XCTAssertEqual(counters[0].value, 1.0)
        XCTAssertEqual(counters[0].tags["command"], "CreateUser")
    }
    
    func testRecordMultipleCounters() async {
        let collector = MockMetricsCollector()
        
        await collector.recordCounter("api.requests", value: 1.0, tags: ["endpoint": "/users"])
        await collector.recordCounter("api.requests", value: 1.0, tags: ["endpoint": "/posts"])
        await collector.recordCounter("api.errors", value: 1.0, tags: ["code": "500"])
        
        let counters = await collector.counters
        XCTAssertEqual(counters.count, 3)
        XCTAssertEqual(counters[0].name, "api.requests")
        XCTAssertEqual(counters[1].name, "api.requests")
        XCTAssertEqual(counters[2].name, "api.errors")
    }
    
    func testCounterWithVariousValues() async {
        let collector = MockMetricsCollector()
        
        await collector.recordCounter("batch.processed", value: 10.0, tags: [:])
        await collector.recordCounter("bytes.transferred", value: 1024.5, tags: [:])
        await collector.recordCounter("items.skipped", value: 0.0, tags: [:])
        
        let counters = await collector.counters
        XCTAssertEqual(counters[0].value, 10.0)
        XCTAssertEqual(counters[1].value, 1024.5)
        XCTAssertEqual(counters[2].value, 0.0)
    }
    
    // MARK: - Gauge Tests
    
    func testRecordGauge() async {
        let collector = MockMetricsCollector()
        
        await collector.recordGauge("memory.usage", value: 75.5,
                                   tags: ["unit": "percent"])
        
        let gauges = await collector.gauges
        XCTAssertEqual(gauges.count, 1)
        XCTAssertEqual(gauges[0].name, "memory.usage")
        XCTAssertEqual(gauges[0].value, 75.5)
        XCTAssertEqual(gauges[0].tags["unit"], "percent")
    }
    
    func testGaugeFluctuations() async {
        let collector = MockMetricsCollector()
        
        // Gauges can go up and down
        await collector.recordGauge("queue.depth", value: 10.0, tags: [:])
        await collector.recordGauge("queue.depth", value: 15.0, tags: [:])
        await collector.recordGauge("queue.depth", value: 5.0, tags: [:])
        await collector.recordGauge("queue.depth", value: 0.0, tags: [:])
        
        let gauges = await collector.gauges
        XCTAssertEqual(gauges.count, 4)
        XCTAssertEqual(gauges[0].value, 10.0)
        XCTAssertEqual(gauges[1].value, 15.0)
        XCTAssertEqual(gauges[2].value, 5.0)
        XCTAssertEqual(gauges[3].value, 0.0)
    }
    
    func testGaugeWithNegativeValues() async {
        let collector = MockMetricsCollector()
        
        // Some gauges might have negative values (e.g., temperature, balance)
        await collector.recordGauge("temperature.celsius", value: -10.5, tags: [:])
        await collector.recordGauge("account.balance", value: -250.00, tags: [:])
        
        let gauges = await collector.gauges
        XCTAssertEqual(gauges[0].value, -10.5)
        XCTAssertEqual(gauges[1].value, -250.00)
    }
    
    // MARK: - Timer Tests
    
    func testRecordTimer() async {
        let collector = MockMetricsCollector()
        
        await collector.recordTimer("request.duration", duration: 0.125,
                                   tags: ["method": "GET", "status": "200"])
        
        let timers = await collector.timers
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers[0].name, "request.duration")
        XCTAssertEqual(timers[0].duration, 0.125)
        XCTAssertEqual(timers[0].tags["method"], "GET")
        XCTAssertEqual(timers[0].tags["status"], "200")
    }
    
    func testTimerWithVariousDurations() async {
        let collector = MockMetricsCollector()
        
        // Very fast operation
        await collector.recordTimer("cache.hit", duration: 0.0001, tags: [:])
        
        // Normal operation
        await collector.recordTimer("db.query", duration: 0.045, tags: [:])
        
        // Slow operation
        await collector.recordTimer("report.generation", duration: 5.5, tags: [:])
        
        let timers = await collector.timers
        XCTAssertEqual(timers[0].duration, 0.0001, accuracy: 0.00001)
        XCTAssertEqual(timers[1].duration, 0.045, accuracy: 0.001)
        XCTAssertEqual(timers[2].duration, 5.5, accuracy: 0.01)
    }
    
    func testTimerPrecision() async {
        let collector = MockMetricsCollector()
        
        // Test precise timing values
        await collector.recordTimer("precise.timer", duration: 0.123456789, tags: [:])
        
        let timers = await collector.timers
        XCTAssertEqual(timers[0].duration, 0.123456789, accuracy: 0.000000001)
    }
    
    // MARK: - Histogram Tests
    
    func testRecordHistogram() async {
        let collector = MockMetricsCollector()
        
        await collector.recordHistogram("response.size", value: 2048.0,
                                       tags: ["content_type": "json"])
        
        let histograms = await collector.histograms
        XCTAssertEqual(histograms.count, 1)
        XCTAssertEqual(histograms[0].name, "response.size")
        XCTAssertEqual(histograms[0].value, 2048.0)
        XCTAssertEqual(histograms[0].tags["content_type"], "json")
    }
    
    func testHistogramDistribution() async {
        let collector = MockMetricsCollector()
        
        // Simulate a distribution of values
        let values = [100.0, 150.0, 200.0, 250.0, 300.0, 1000.0, 50.0, 75.0]
        for value in values {
            await collector.recordHistogram("latency.distribution", value: value, tags: [:])
        }
        
        let histograms = await collector.histograms
        XCTAssertEqual(histograms.count, values.count)
        for (index, value) in values.enumerated() {
            XCTAssertEqual(histograms[index].value, value)
        }
    }
    
    func testHistogramWithPercentiles() async {
        let collector = MockMetricsCollector()
        
        // Record values that would typically be used for percentile calculations
        await collector.recordHistogram("request.percentiles", value: 10.0, tags: ["percentile": "p50"])
        await collector.recordHistogram("request.percentiles", value: 50.0, tags: ["percentile": "p90"])
        await collector.recordHistogram("request.percentiles", value: 100.0, tags: ["percentile": "p95"])
        await collector.recordHistogram("request.percentiles", value: 500.0, tags: ["percentile": "p99"])
        
        let histograms = await collector.histograms
        XCTAssertEqual(histograms.count, 4)
    }
    
    // MARK: - Tag Tests
    
    func testEmptyTags() async {
        let collector = MockMetricsCollector()
        
        await collector.recordCounter("no.tags", value: 1.0, tags: [:])
        await collector.recordGauge("no.tags", value: 1.0, tags: [:])
        await collector.recordTimer("no.tags", duration: 1.0, tags: [:])
        await collector.recordHistogram("no.tags", value: 1.0, tags: [:])
        
        let counters = await collector.counters
        let gauges = await collector.gauges
        let timers = await collector.timers
        let histograms = await collector.histograms
        
        XCTAssertTrue(counters[0].tags.isEmpty)
        XCTAssertTrue(gauges[0].tags.isEmpty)
        XCTAssertTrue(timers[0].tags.isEmpty)
        XCTAssertTrue(histograms[0].tags.isEmpty)
    }
    
    func testMultipleTags() async {
        let collector = MockMetricsCollector()
        
        let tags = [
            "environment": "production",
            "region": "us-west-2",
            "service": "api",
            "version": "1.2.3",
            "customer": "acme-corp"
        ]
        
        await collector.recordCounter("multi.tags", value: 1.0, tags: tags)
        
        let counters = await collector.counters
        XCTAssertEqual(counters[0].tags.count, 5)
        XCTAssertEqual(counters[0].tags["environment"], "production")
        XCTAssertEqual(counters[0].tags["region"], "us-west-2")
        XCTAssertEqual(counters[0].tags["service"], "api")
        XCTAssertEqual(counters[0].tags["version"], "1.2.3")
        XCTAssertEqual(counters[0].tags["customer"], "acme-corp")
    }
    
    func testTagsWithSpecialCharacters() async {
        let collector = MockMetricsCollector()
        
        let tags = [
            "path": "/api/v1/users/{id}",
            "error": "Connection refused: 127.0.0.1:5432",
            "query": "SELECT * FROM users WHERE id = ?",
            "emoji": "🚀"
        ]
        
        await collector.recordCounter("special.chars", value: 1.0, tags: tags)
        
        let counters = await collector.counters
        XCTAssertEqual(counters[0].tags["path"], "/api/v1/users/{id}")
        XCTAssertEqual(counters[0].tags["error"], "Connection refused: 127.0.0.1:5432")
        XCTAssertEqual(counters[0].tags["query"], "SELECT * FROM users WHERE id = ?")
        XCTAssertEqual(counters[0].tags["emoji"], "🚀")
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentMetricRecording() async {
        let collector = MockMetricsCollector()
        let iterations = 100
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    await collector.recordCounter("concurrent.counter",
                                                 value: Double(i),
                                                 tags: ["index": "\(i)"])
                }
            }
        }
        
        let counters = await collector.counters
        XCTAssertEqual(counters.count, iterations)
    }
    
    func testMixedConcurrentOperations() async {
        let collector = MockMetricsCollector()
        let iterations = 25
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                // Counter
                group.addTask {
                    await collector.recordCounter("concurrent.counter",
                                                 value: Double(i),
                                                 tags: ["index": "\(i)"])
                }
                
                // Gauge
                group.addTask {
                    await collector.recordGauge("concurrent.gauge",
                                               value: Double(i * 2),
                                               tags: ["index": "\(i)"])
                }
                
                // Timer
                group.addTask {
                    await collector.recordTimer("concurrent.timer",
                                               duration: TimeInterval(i) / 1000.0,
                                               tags: ["index": "\(i)"])
                }
                
                // Histogram
                group.addTask {
                    await collector.recordHistogram("concurrent.histogram",
                                                   value: Double(i * 10),
                                                   tags: ["index": "\(i)"])
                }
            }
        }
        
        let counters = await collector.counters
        let gauges = await collector.gauges
        let timers = await collector.timers
        let histograms = await collector.histograms
        
        XCTAssertEqual(counters.count, iterations)
        XCTAssertEqual(gauges.count, iterations)
        XCTAssertEqual(timers.count, iterations)
        XCTAssertEqual(histograms.count, iterations)
    }
    
    // MARK: - Default Collector Tests
    
    func testDefaultMetricsCollector() async {
        let collector = DefaultMetricsCollector()
        
        // Should not crash when recording metrics
        await collector.recordCounter("default.counter", value: 1.0, tags: [:])
        await collector.recordGauge("default.gauge", value: 42.0, tags: [:])
        await collector.recordTimer("default.timer", duration: 0.5, tags: [:])
        await collector.recordHistogram("default.histogram", value: 100.0, tags: [:])
    }
    
    // MARK: - Edge Case Tests
    
    func testZeroValues() async {
        let collector = MockMetricsCollector()
        
        await collector.recordCounter("zero.counter", value: 0.0, tags: [:])
        await collector.recordGauge("zero.gauge", value: 0.0, tags: [:])
        await collector.recordTimer("zero.timer", duration: 0.0, tags: [:])
        await collector.recordHistogram("zero.histogram", value: 0.0, tags: [:])
        
        let counters = await collector.counters
        let gauges = await collector.gauges
        let timers = await collector.timers
        let histograms = await collector.histograms
        
        XCTAssertEqual(counters[0].value, 0.0)
        XCTAssertEqual(gauges[0].value, 0.0)
        XCTAssertEqual(timers[0].duration, 0.0)
        XCTAssertEqual(histograms[0].value, 0.0)
    }
    
    func testNegativeValues() async {
        let collector = MockMetricsCollector()
        
        // Negative values might be valid for some gauges
        await collector.recordGauge("negative.gauge", value: -100.0, tags: [:])
        
        // But typically not for counters, timers, or histograms
        // (though the protocol doesn't enforce this)
        await collector.recordCounter("negative.counter", value: -1.0, tags: [:])
        await collector.recordTimer("negative.timer", duration: -0.1, tags: [:])
        await collector.recordHistogram("negative.histogram", value: -50.0, tags: [:])
        
        let gauges = await collector.gauges
        let counters = await collector.counters
        let timers = await collector.timers
        let histograms = await collector.histograms
        
        XCTAssertEqual(gauges[0].value, -100.0)
        XCTAssertEqual(counters[0].value, -1.0)
        XCTAssertEqual(timers[0].duration, -0.1)
        XCTAssertEqual(histograms[0].value, -50.0)
    }
    
    func testExtremeLargeValues() async {
        let collector = MockMetricsCollector()
        
        await collector.recordCounter("extreme.counter", value: Double.greatestFiniteMagnitude, tags: [:])
        await collector.recordGauge("extreme.gauge", value: Double.greatestFiniteMagnitude, tags: [:])
        await collector.recordHistogram("extreme.histogram", value: Double.greatestFiniteMagnitude, tags: [:])
        
        let counters = await collector.counters
        let gauges = await collector.gauges
        let histograms = await collector.histograms
        
        XCTAssertEqual(counters[0].value, Double.greatestFiniteMagnitude)
        XCTAssertEqual(gauges[0].value, Double.greatestFiniteMagnitude)
        XCTAssertEqual(histograms[0].value, Double.greatestFiniteMagnitude)
    }
    
    func testExtremeSmallValues() async {
        let collector = MockMetricsCollector()
        
        await collector.recordCounter("tiny.counter", value: Double.leastNormalMagnitude, tags: [:])
        await collector.recordTimer("tiny.timer", duration: Double.leastNormalMagnitude, tags: [:])
        
        let counters = await collector.counters
        let timers = await collector.timers
        
        XCTAssertEqual(counters[0].value, Double.leastNormalMagnitude)
        XCTAssertEqual(timers[0].duration, Double.leastNormalMagnitude)
    }
    
    // MARK: - Performance Tests
    
    func testRecordingPerformance() async {
        let collector = MockMetricsCollector()
        let operations = 10000
        
        let start = Date()
        for i in 0..<operations {
            await collector.recordCounter("perf.counter", value: Double(i), tags: [:])
        }
        let duration = Date().timeIntervalSince(start)
        
        let counters = await collector.counters
        XCTAssertEqual(counters.count, operations)
        
        print("Recording performance: \(operations) operations in \(duration)s")
        print("Operations per second: \(Double(operations) / duration)")
        
        XCTAssertLessThan(duration, 5.0) // Should complete in less than 5 seconds
    }
}
