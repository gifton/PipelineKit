import XCTest
import Foundation
import PipelineKitCore
@testable import PipelineKitObservability

final class ObservabilitySystemLifecycleTests: XCTestCase {
    func testStaleHubReplacementCannotDisplaceOrRetireInstalledRoute() async {
        let hub = EventHub()
        let owner = UUID()
        let first = SystemEventSubscriber()
        let stale = SystemEventSubscriber()
        let latest = SystemEventSubscriber()
        let initial = EventSubscriptionGeneration()
        _ = await hub.replaceSubscription(owner: owner, generation: initial, with: first)
        let superseded = EventSubscriptionGeneration()
        superseded.invalidate()
        let skipped = await hub.replaceSubscription(owner: owner, generation: superseded, with: stale)
        XCTAssertFalse(skipped.installed)
        XCTAssertNil(skipped.retired)
        await hub.emit(metricEvent("before.swap"))
        let next = EventSubscriptionGeneration()
        let switched = await hub.replaceSubscription(owner: owner, generation: next, with: latest)
        XCTAssertTrue(switched.installed)
        XCTAssertTrue(switched.retired === first)
        _ = await hub.replaceSubscription(owner: owner, generation: superseded, with: stale)
        await hub.emit(metricEvent("after.swap"))
        let firstEvents = await first.events
        let staleEvents = await stale.events
        let latestEvents = await latest.events
        XCTAssertEqual(firstEvents, ["before.swap"])
        XCTAssertTrue(staleEvents.isEmpty)
        XCTAssertEqual(latestEvents, ["after.swap"])
        let removed = await hub.replaceSubscription(owner: owner, generation: EventSubscriptionGeneration(), with: nil)
        XCTAssertTrue(removed.retired === latest)
        let count = await hub.subscriberCount
        XCTAssertEqual(count, 0)
    }

    func testEventsUseReplacementWhileRetiredTransportIsClosing() async {
        let system = await ObservabilitySystem(configuration: .init(enableMetrics: false, logEvents: false))
        let gate = SystemCloseGate()
        await system.setStatsDExporter(makeExporter(SystemLifecycleTransport(closeGate: gate)))
        let latest = SystemLifecycleTransport()
        let latestExporter = makeExporter(latest)
        let replacing = Task { await system.setStatsDExporter(latestExporter) }
        await gate.waitUntilEntered()
        let hub = await system.getEventHub()
        await hub.emit(metricEvent("during.retirement"))
        let packets = await latest.packets
        XCTAssertEqual(packets, ["during.retirement:1.0|c"])
        await gate.release()
        await replacing.value
        await system.disableStatsD()
    }

    func testReplacementAttemptsBufferedRecordsBeforeRetiringExporter() async {
        let system = await ObservabilitySystem(configuration: .init(enableMetrics: true, logEvents: false))
        let transport = SystemLifecycleTransport()
        let exporter = StatsDExporter(configuration: .init(maxBatchSize: 10, flushInterval: 60), transport: transport)
        await system.setStatsDExporter(exporter)
        await system.recordCounter(name: "buffered", value: 7)
        await system.setStatsDExporter(makeExporter(SystemLifecycleTransport()))
        let packets = await transport.packets
        XCTAssertEqual(packets, ["buffered:7.0|c"])
        await system.disableStatsD()
    }

    func testRepeatedStatsDConfigurationRetainsOneEventBridge() async {
        let system = await ObservabilitySystem(configuration: .init(enableMetrics: false, logEvents: false))
        let hub = await system.getEventHub()
        await system.enableStatsD(host: "127.0.0.1", port: 8125)
        await system.enableStatsD(host: "127.0.0.1", port: 8126)
        await system.enableStatsD(host: "127.0.0.1", port: 8127)
        let count = await hub.subscriberCount
        XCTAssertEqual(count, 1)
        await system.disableStatsD()
    }

    func testReplacementClosesRetiredExporterAndRoutesEachEventOnce() async {
        let system = await ObservabilitySystem(configuration: .init(enableMetrics: false, logEvents: false))
        let hub = await system.getEventHub()
        let first = SystemLifecycleTransport()
        let second = SystemLifecycleTransport()
        await system.setStatsDExporter(makeExporter(first))
        await hub.emit(metricEvent("first"))
        await system.setStatsDExporter(makeExporter(second))
        await hub.emit(metricEvent("second"))
        await system.disableStatsD()
        await system.disableStatsD()
        await hub.emit(metricEvent("disabled"))
        let firstPackets = await first.packets
        let secondPackets = await second.packets
        let firstCloses = await first.closes
        let secondCloses = await second.closes
        let subscribers = await hub.subscriberCount
        XCTAssertEqual(firstPackets, ["first:1.0|c"])
        XCTAssertEqual(secondPackets, ["second:1.0|c"])
        XCTAssertEqual(firstCloses, 1)
        XCTAssertEqual(secondCloses, 1)
        XCTAssertEqual(subscribers, 0)
    }

    func testOverlappingReplacementCannotRestoreAnOlderBridge() async {
        let system = await ObservabilitySystem(configuration: .init(enableMetrics: false, logEvents: false))
        let gate = SystemCloseGate()
        let first = SystemLifecycleTransport(closeGate: gate)
        let middle = SystemLifecycleTransport()
        let latest = SystemLifecycleTransport()
        await system.setStatsDExporter(makeExporter(first))
        let middleExporter = makeExporter(middle)
        let replacing = Task { await system.setStatsDExporter(middleExporter) }
        await gate.waitUntilEntered()
        await system.setStatsDExporter(makeExporter(latest))
        await gate.release()
        await replacing.value
        let hub = await system.getEventHub()
        await hub.emit(metricEvent("latest"))
        let middlePackets = await middle.packets
        let latestPackets = await latest.packets
        let subscribers = await hub.subscriberCount
        XCTAssertTrue(middlePackets.isEmpty)
        XCTAssertEqual(latestPackets, ["latest:1.0|c"])
        XCTAssertEqual(subscribers, 1)
        await system.disableStatsD()
    }

    private func makeExporter(_ transport: SystemLifecycleTransport) -> StatsDExporter {
        StatsDExporter(configuration: .init(maxBatchSize: 1), transport: transport)
    }

    private func metricEvent(_ name: String) -> PipelineEvent {
        PipelineEvent(name: "metric.counter.recorded",
                      properties: ["metric_name": name, "metric_value": 1.0], correlationID: "lifecycle")
    }
}

private actor SystemEventSubscriber: EventSubscriber {
    private(set) var events: [String] = []
    func process(_ event: PipelineEvent) {
        events.append(event.properties["metric_name"]?.get(String.self) ?? event.name)
    }
}

private actor SystemLifecycleTransport: MetricsTransport {
    struct Configuration: Sendable {}
    private let closeGate: SystemCloseGate?
    private(set) var packets: [String] = []
    private(set) var closes = 0
    init(closeGate: SystemCloseGate? = nil) { self.closeGate = closeGate }
    init(configuration: Configuration) async throws { closeGate = nil }
    func send(_ data: Data) async throws { packets.append(String(decoding: data, as: UTF8.self)) }
    func sendBatch(_ batch: [Data]) async throws { for data in batch { try await send(data) } }
    func close() async {
        if let closeGate { await closeGate.pause() }
        closes += 1
    }
}

private actor SystemCloseGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
