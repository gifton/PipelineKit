import XCTest
@testable import PipelineKitCore

private actor MetricsStartGate {
    private let expected: Int
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func arriveAndWait() async {
        await withCheckedContinuation { continuation in
            arrivals.append(continuation)
            if arrivals.count == expected {
                for arrival in arrivals {
                    arrival.resume()
                }
                arrivals.removeAll()
            }
        }
    }
}

final class CommandContextMetricsMergeTests: XCTestCase {
    func testConcurrentDisjointMetricsUpdatesAreConserved() async {
        let context = CommandContext()
        let count = 2_000
        let gate = MetricsStartGate(expected: count)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    await gate.arriveAndWait()
                    context.updateMetrics(["metric-\(index)": index])
                }
            }
        }
        let metrics = context.getMetrics()
        XCTAssertEqual(metrics.count, count)
        for index in 0..<count {
            XCTAssertEqual(metrics["metric-\(index)"] as? Int, index, "metric-\(index)")
        }
    }

    func testConcurrentSetAndUpdatePreserveDisjointKeys() async {
        let context = CommandContext()
        let count = 400
        let gate = MetricsStartGate(expected: count)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    await gate.arriveAndWait()
                    if index.isMultiple(of: 2) {
                        context.setMetric("metric-\(index)", value: index)
                    } else {
                        context.updateMetrics(["metric-\(index)": index])
                    }
                }
            }
        }
        let metrics = context.getMetrics()
        XCTAssertEqual(metrics.count, count)
        for index in 0..<count {
            XCTAssertEqual(metrics["metric-\(index)"] as? Int, index, "metric-\(index)")
        }
    }

    func testLastCompletedWriterWinsAndPreservesOtherMetrics() {
        let context = CommandContext()
        context.setMetrics(["shared": 0, "retained": 7])
        context.updateMetrics(["shared": 1, "added": 8])
        context.updateMetrics(["shared": 2])
        let metrics = context.getMetrics()
        XCTAssertEqual(metrics.count, 3)
        XCTAssertEqual(metrics["shared"] as? Int, 2)
        XCTAssertEqual(metrics["retained"] as? Int, 7)
        XCTAssertEqual(metrics["added"] as? Int, 8)
    }

    func testMetricsUpdatesLeaveOrdinaryMetadataIsolated() {
        let context = CommandContext()
        context.setMetadata(["shared": "metadata", "other": 42])
        context.updateMetrics(["shared": "metric"])
        XCTAssertEqual(context.getMetadata("shared") as? String, "metadata")
        XCTAssertEqual(context.getMetadata("other") as? Int, 42)
        XCTAssertEqual(context.getMetric("shared") as? String, "metric")
        XCTAssertEqual(context.getMetadata().count, 2)
    }
}
