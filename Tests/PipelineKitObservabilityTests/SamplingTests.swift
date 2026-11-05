import XCTest
@testable import PipelineKitObservability

final class SamplingTests: XCTestCase {
    func testSamplingConfiguration() {
        let config = StatsDExporter.Configuration(sampleRate: 0.5,
                                                  sampleRatesByType: ["counter": 0.1, "gauge": 1],
                                                  criticalPatterns: ["error", "fatal"])
        XCTAssertEqual(config.sampleRate, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(config.sampleRatesByType["counter"] ?? -1, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(config.sampleRatesByType["gauge"] ?? -1, 1, accuracy: 0.000_001)
        XCTAssertEqual(config.criticalPatterns, ["error", "fatal"])
    }

    func testSampleRateClamping() {
        let config = StatsDExporter.Configuration(sampleRate: 1.5, sampleRatesByType: ["counter": -0.5])
        XCTAssertEqual(config.sampleRate, 1, accuracy: 0.000_001)
        XCTAssertEqual(config.sampleRatesByType["counter"] ?? -1, 0, accuracy: 0.000_001)
    }

    func testCriticalMetricsAlwaysSampled() async throws {
        let lines = try await capture(configuration: .init(sampleRate: 0, criticalPatterns: ["error", "timeout", "fatal"]),
                                      snapshots: ["api.error.count", "request.timeout", "fatal.exception", "normal.metric"]
                                        .map { .counter($0) })
        XCTAssertEqual(lines.sorted(), ["api.error.count:1.0|c", "fatal.exception:1.0|c", "request.timeout:1.0|c"])
    }

    func testDeterministicSampling() async throws {
        let snapshots = (0..<100).flatMap { index in
            Array(repeating: MetricSnapshot.counter("metric.\(index)"), count: 10)
        }
        let lines = try await capture(configuration: .init(sampleRate: 0.5), snapshots: snapshots)
        let grouped = Dictionary(grouping: lines, by: { $0.split(separator: ":")[0] })
        XCTAssertGreaterThan(grouped.count, 30)
        XCTAssertLessThan(grouped.count, 70)
        for metrics in grouped.values { XCTAssertEqual(metrics.count, 10) }
        let repeated = try await capture(configuration: .init(sampleRate: 0.5), snapshots: snapshots)
        XCTAssertEqual(lines.sorted(), repeated.sorted())
    }

    func testPerTypeSampling() async throws {
        let snapshots = (0..<10).flatMap { index -> [MetricSnapshot] in
            [.counter("counter.\(index)"), .gauge("gauge.\(index)", value: Double(index)),
             .timer("timer.\(index)", duration: 0.001)]
        }
        let lines = try await capture(configuration: .init(sampleRatesByType: ["counter": 0, "gauge": 1, "timer": 0.5]),
                                      snapshots: snapshots)
        XCTAssertFalse(lines.contains { $0.contains("|c") })
        XCTAssertEqual(lines.filter { $0.contains("|g") }.count, 10)
        let timers = lines.filter { $0.contains("|ms") }
        XCTAssertFalse(timers.isEmpty)
        XCTAssertLessThan(timers.count, 10)
        XCTAssertTrue(timers.allSatisfy { $0.hasSuffix(":1.0|ms|@0.5") })
    }

    func testSampleRateInWireFormatKeepsRawCounterAmount() async throws {
        let lines = try await capture(configuration: .init(sampleRate: 0.25),
                                      snapshots: (0..<100).map { .counter("format.test.\($0)", value: 10) })
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix(":10.0|c|@0.25") })
    }

    func testSampledGaugeKeepsAbsoluteAmountWithoutRateMarker() async throws {
        let lines = try await capture(configuration: .init(sampleRate: 0.1),
                                      snapshots: (0..<100).map { .gauge("gauge.test.\($0)", value: 42) })
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix(":42.0|g") })
    }

    func testConcurrentSamplingDecisions() async throws {
        let transport = try await MockTransport(configuration: .init())
        let exporter = StatsDExporter(configuration: .init(maxBatchSize: 1000, flushInterval: 60, sampleRate: 0.5),
                                      transport: transport)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask { await exporter.counter("concurrent.\(index % 10)") }
            }
        }
        await exporter.forceFlush()
        let lines = await transport.getMetricsAsStrings()
        XCTAssertFalse(lines.isEmpty)
        let grouped = Dictionary(grouping: lines, by: { $0.split(separator: ":")[0] })
        for metrics in grouped.values { XCTAssertEqual(metrics.count, 10) }
        await exporter.close()
    }

    private func capture(configuration: StatsDExporter.Configuration, snapshots: [MetricSnapshot]) async throws -> [String] {
        let transport = try await MockTransport(configuration: .init())
        let exporter = StatsDExporter(configuration: configuration, transport: transport)
        await exporter.recordBatch(snapshots)
        await exporter.forceFlush()
        let lines = await transport.getMetricsAsStrings()
        await exporter.close()
        return lines
    }
}
