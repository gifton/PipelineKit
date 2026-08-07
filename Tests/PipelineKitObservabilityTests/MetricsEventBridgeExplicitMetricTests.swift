import XCTest
import PipelineKitCore
import PipelineKitObservability

private actor CapturingRecorder: MetricRecorder {
    private(set) var snapshots: [MetricSnapshot] = []
    func record(_ snapshot: MetricSnapshot) async { snapshots.append(snapshot) }
    func all() -> [MetricSnapshot] { snapshots }
}

final class MetricsEventBridgeExplicitMetricTests: XCTestCase {
    // Explicit records are user intent: they must work under .production,
    // whose includePatterns/recordCounts gates govern derived metrics only.
    func testExplicitCounterBypassesProductionGates() async {
        let recorder = CapturingRecorder()
        let bridge = MetricsEventBridge(recorder: recorder, config: .production)
        await bridge.process(PipelineEvent(
            name: "metric.counter.recorded",
            properties: [
                "metric_name": "checkout.completed",
                "metric_type": "counter",
                "metric_value": 3.0,
                "metric_tags": ["tenant": "acme"]
            ],
            correlationID: "t1"
        ))
        let snaps = await recorder.all()
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.name, "checkout.completed")
        XCTAssertEqual(snaps.first?.type, "counter")
        XCTAssertEqual(snaps.first?.value, 3.0)
        XCTAssertEqual(snaps.first?.tags, ["tenant": "acme"])
    }

    func testExplicitGaugePropagatesUnit() async {
        let recorder = CapturingRecorder()
        let bridge = MetricsEventBridge(recorder: recorder, config: .default)
        await bridge.process(PipelineEvent(
            name: "metric.gauge.recorded",
            properties: [
                "metric_name": "pool.utilization",
                "metric_type": "gauge",
                "metric_value": 0.75,
                "metric_tags": [String: String](),
                "metric_unit": "ratio"
            ],
            correlationID: "t2"
        ))
        let snaps = await recorder.all()
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.type, "gauge")
        XCTAssertEqual(snaps.first?.value, 0.75)
        XCTAssertEqual(snaps.first?.unit, "ratio")
    }

    // recordTimer packs metric_value ALREADY in milliseconds. The bridge must
    // not re-convert (MetricSnapshot.timer(duration:) multiplies by 1000).
    func testExplicitTimerValueIsNotDoubleConverted() async {
        let recorder = CapturingRecorder()
        let bridge = MetricsEventBridge(recorder: recorder, config: .default)
        await bridge.process(PipelineEvent(
            name: "metric.timer.recorded",
            properties: [
                "metric_name": "db.query",
                "metric_type": "timer",
                "metric_value": 250.0, // 0.25s, as CommandContext packs it
                "metric_tags": [String: String](),
                "metric_unit": "ms"
            ],
            correlationID: "t3"
        ))
        let snaps = await recorder.all()
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.type, "timer")
        XCTAssertEqual(snaps.first?.value, 250.0, "bridge must not re-convert an already-ms value")
        XCTAssertEqual(snaps.first?.unit, "ms")
    }

    // Malformed explicit events (missing metric_name) fall through to the
    // pre-existing generic fallback — never crash, never vanish silently
    // under a config whose fallback would have recorded something.
    func testMalformedExplicitEventFallsThroughToFallback() async {
        let recorder = CapturingRecorder()
        let bridge = MetricsEventBridge(recorder: recorder, config: .default) // recordCounts: true
        await bridge.process(PipelineEvent(
            name: "metric.counter.recorded",
            properties: ["metric_value": 3.0], // no metric_name
            correlationID: "t4"
        ))
        let snaps = await recorder.all()
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.type, "counter")
        XCTAssertEqual(snaps.first?.value, 1.0, "fallback semantics, not the explicit value")
    }

    // Derived metrics are untouched: a commandCompleted event still produces
    // its duration timer + completion counter under .default.
    func testDerivedCommandCompletedBehaviorUnchanged() async {
        let recorder = CapturingRecorder()
        let bridge = MetricsEventBridge(recorder: recorder, config: .default)
        await bridge.process(PipelineEvent(
            name: PipelineEvent.Name.commandCompleted,
            properties: ["commandType": "ProbeCommand", "duration": 0.5],
            correlationID: "t5"
        ))
        let snaps = await recorder.all()
        XCTAssertTrue(snaps.contains { $0.name == "command.completed" && $0.type == "counter" })
        XCTAssertTrue(snaps.contains { $0.name == "command.duration" && $0.type == "timer" })
    }

    // End-to-end: context.recordCounter under .production reaches getMetrics().
    func testContextRecordCounterReachesMetricsUnderProduction() async {
        let context = CommandContext()
        await context.setupObservability(.production)
        await context.recordCounter(name: "orders.placed", value: 2.0, tags: ["region": "us"])

        // EventHub.emit() awaits full subscriber fan-out, so delivery is
        // synchronous; the poll is belt-and-braces robustness only.
        var hit: MetricSnapshot?
        for _ in 0..<50 {
            let metrics = await context.observability?.getMetrics() ?? []
            if let found = metrics.first(where: { $0.name == "orders.placed" }) { hit = found; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(hit, "explicit record must work under .production")
        XCTAssertEqual(hit?.type, "counter")
        XCTAssertEqual(hit?.value, 2.0)
        XCTAssertEqual(hit?.tags, ["region": "us"])
    }
}
