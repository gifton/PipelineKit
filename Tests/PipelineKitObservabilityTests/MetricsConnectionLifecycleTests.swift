import Foundation
import XCTest
import PipelineKitCore
@testable import PipelineKitObservability

final class MetricsConnectionLifecycleTests: XCTestCase {
    func testConnectionRecordsMetricAfterConnectReturns() async throws {
        let hub = EventHub()
        let storage = MetricsStorage()
        await hub.connectMetrics(storage, config: .production)

        await hub.emit(PipelineEvent(
            name: "metric.gauge.recorded",
            properties: [
                "metric_name": "connection.utilization",
                "metric_value": 0.75,
                "metric_tags": ["region": "west"],
                "metric_unit": "ratio"
            ],
            correlationID: "metrics-connection"
        ))

        let snapshots = await storage.getAll()
        XCTAssertEqual(snapshots.count, 1)
        let snapshot = try XCTUnwrap(snapshots.first)
        let value = try XCTUnwrap(snapshot.value)
        XCTAssertEqual(snapshot.name, "connection.utilization")
        XCTAssertEqual(snapshot.type, "gauge")
        XCTAssertEqual(value, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.tags, ["region": "west"])
        XCTAssertEqual(snapshot.unit, "ratio")
    }

    func testConnectedRecorderLivesUntilHubDeallocates() async {
        let recorderReleased = expectation(description: "Connected recorder released")
        weak var weakHub: EventHub?
        weak var weakRecorder: ConnectionLifetimeRecorder?

        do {
            let hub = EventHub()
            weakHub = hub
            do {
                let recorder = ConnectionLifetimeRecorder(onDeinit: { recorderReleased.fulfill() })
                weakRecorder = recorder
                await hub.connectMetrics(recorder)
            }

            XCTAssertNotNil(weakRecorder, "The hub must retain a recorder connected without a retained result")
        }

        await fulfillment(of: [recorderReleased], timeout: 2)
        XCTAssertNil(weakHub)
        XCTAssertNil(weakRecorder)
    }

    func testOrdinarySubscriptionRemainsWeak() async {
        let hub = EventHub()
        let storage = MetricsStorage()
        weak var weakBridge: MetricsEventBridge?

        do {
            let bridge = MetricsEventBridge(recorder: storage)
            weakBridge = bridge
            await hub.subscribe(bridge)
        }

        XCTAssertNil(weakBridge)
        await hub.emit(PipelineEvent(
            name: "ordinary.subscription",
            properties: [:],
            correlationID: "weak-subscription"
        ))
        let snapshots = await storage.getAll()
        let subscriberCount = await hub.subscriberCount
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertEqual(subscriberCount, 0)
    }

    func testConcurrentConnectionsToSameRecorderDisconnectIndependently() async {
        let hub = EventHub()
        let storage = MetricsStorage()
        async let firstConnection = hub.connectMetrics(storage)
        async let secondConnection = hub.connectMetrics(storage)
        let (firstID, secondID) = await (firstConnection, secondConnection)
        XCTAssertNotEqual(firstID, secondID)

        await hub.emit(connectionMetricEvent("both.connections"))
        await hub.disconnectMetrics(firstID)
        await hub.disconnectMetrics(firstID)
        await hub.disconnectMetrics(UUID())
        await hub.emit(connectionMetricEvent("remaining.connection"))

        let snapshots = await storage.getAll()
        let remainingCount = await hub.subscriberCount
        XCTAssertEqual(snapshots.map(\.name).sorted(), ["both.connections", "both.connections", "remaining.connection"])
        XCTAssertEqual(remainingCount, 1)

        await hub.disconnectMetrics(secondID)
        await hub.emit(connectionMetricEvent("after.disconnect"))
        let finalSnapshots = await storage.getAll()
        let finalCount = await hub.subscriberCount
        XCTAssertEqual(finalSnapshots.count, 3)
        XCTAssertEqual(finalCount, 0)
    }

    func testDisconnectReleasesIdleRecorderWhileHubRemainsAlive() async {
        let hub = EventHub()
        let recorderReleased = expectation(description: "Disconnected recorder released")
        weak var weakRecorder: ConnectionLifetimeRecorder?
        let connectionID: UUID
        do {
            let recorder = ConnectionLifetimeRecorder(onDeinit: { recorderReleased.fulfill() })
            weakRecorder = recorder
            connectionID = await hub.connectMetrics(recorder)
        }

        XCTAssertNotNil(weakRecorder)
        await hub.disconnectMetrics(connectionID)
        await fulfillment(of: [recorderReleased], timeout: 2)
        XCTAssertNil(weakRecorder)
        withExtendedLifetime(hub) {}
    }

    func testDisconnectReturnsBeforeAdmittedDeliverySettles() async {
        let hub = EventHub()
        let storage = MetricsStorage()
        let entered = expectation(description: "Recorder entered an admitted delivery")
        let disconnected = expectation(description: "Disconnect returned before delivery settled")
        let recorderReleased = expectation(description: "Admitted delivery released its recorder")
        let gate = ConnectionDeliveryGate(onEntry: { entered.fulfill() })
        weak var weakRecorder: GatedConnectionRecorder?
        let connectionID: UUID
        do {
            let recorder = GatedConnectionRecorder(
                storage: storage,
                gate: gate,
                onDeinit: { recorderReleased.fulfill() }
            )
            weakRecorder = recorder
            connectionID = await hub.connectMetrics(recorder)
        }

        let emission = Task { await hub.emit(connectionMetricEvent("admitted.delivery")) }
        await fulfillment(of: [entered], timeout: 2)
        let disconnect = Task {
            await hub.disconnectMetrics(connectionID)
            disconnected.fulfill()
        }
        await fulfillment(of: [disconnected], timeout: 2)
        XCTAssertNotNil(weakRecorder, "An admitted delivery retains its recorder until it settles")

        // Release and join even if disconnect incorrectly waited for the delivery.
        await gate.release()
        await emission.value
        await disconnect.value
        await fulfillment(of: [recorderReleased], timeout: 2)
        XCTAssertNil(weakRecorder)

        await hub.emit(connectionMetricEvent("after.disconnect"))
        let snapshots = await storage.getAll()
        XCTAssertEqual(snapshots.map(\.name), ["admitted.delivery"])
    }

    func testRecorderCanDisconnectItsOwnConnection() async {
        let hub = EventHub()
        let storage = MetricsStorage()
        let disconnected = expectation(description: "Recorder returned from its own disconnect")
        let recorder = SelfDisconnectingRecorder(hub: hub, storage: storage, onDisconnect: { disconnected.fulfill() })
        let connectionID = await hub.connectMetrics(recorder)
        await recorder.setConnectionID(connectionID)

        let emission = Task { await hub.emit(connectionMetricEvent("self.disconnect")) }
        await fulfillment(of: [disconnected], timeout: 2)
        await emission.value
        await hub.emit(connectionMetricEvent("after.self.disconnect"))

        let snapshots = await storage.getAll()
        let subscriberCount = await hub.subscriberCount
        XCTAssertEqual(snapshots.map(\.name), ["self.disconnect"])
        XCTAssertEqual(subscriberCount, 0)
    }

    func testDisconnectAndHubReleaseDoNotCloseCallerOwnedExporter() async {
        let transport = ConnectionMetricsTransport()
        let exporter = StatsDExporter(configuration: .init(maxBatchSize: 1), transport: transport)
        let hubReleased = expectation(description: "Hub released its other connected recorder")
        weak var weakHub: EventHub?
        do {
            let hub = EventHub()
            weakHub = hub
            let connectionID = await hub.connectMetrics(exporter)
            await hub.emit(connectionMetricEvent("connected"))
            await hub.disconnectMetrics(connectionID)
            await exporter.record(.counter("after.disconnect"))
            await hub.connectMetrics(exporter)
            await hub.connectMetrics(ConnectionLifetimeRecorder(onDeinit: { hubReleased.fulfill() }))
        }
        await fulfillment(of: [hubReleased], timeout: 2)
        XCTAssertNil(weakHub)
        await exporter.record(.counter("after.hub.release"))

        let packets = await transport.packets
        let closesBeforeOwnerClose = await transport.closes
        XCTAssertEqual(packets, ["connected:1.0|c", "after.disconnect:1.0|c", "after.hub.release:1.0|c"])
        XCTAssertEqual(closesBeforeOwnerClose, 0)

        await exporter.close()
        let closesAfterOwnerClose = await transport.closes
        XCTAssertEqual(closesAfterOwnerClose, 1)
    }

    func testOwnedConnectionDoesNotChangeReplacementGenerationRouting() async {
        let hub = EventHub()
        let ownedStorage = MetricsStorage()
        let firstStorage = MetricsStorage()
        let latestStorage = MetricsStorage()
        let staleStorage = MetricsStorage()
        let first = MetricsEventBridge(recorder: firstStorage)
        let latest = MetricsEventBridge(recorder: latestStorage)
        let stale = MetricsEventBridge(recorder: staleStorage)
        let owner = UUID()
        let connectionID = await hub.connectMetrics(ownedStorage)
        _ = await hub.replaceSubscription(owner: owner, generation: EventSubscriptionGeneration(), with: first)
        await hub.emit(connectionMetricEvent("before.replacement"))

        let replacement = await hub.replaceSubscription(owner: owner, generation: EventSubscriptionGeneration(), with: latest)
        XCTAssertTrue(replacement.retired === first)
        let staleGeneration = EventSubscriptionGeneration()
        staleGeneration.invalidate()
        let skipped = await hub.replaceSubscription(owner: owner, generation: staleGeneration, with: stale)
        XCTAssertFalse(skipped.installed)
        XCTAssertNil(skipped.retired)
        await hub.disconnectMetrics(connectionID)
        await hub.emit(connectionMetricEvent("after.replacement"))

        let ownedSnapshots = await ownedStorage.getAll()
        let firstSnapshots = await firstStorage.getAll()
        let latestSnapshots = await latestStorage.getAll()
        let staleSnapshots = await staleStorage.getAll()
        XCTAssertEqual(ownedSnapshots.map(\.name), ["before.replacement"])
        XCTAssertEqual(firstSnapshots.map(\.name), ["before.replacement"])
        XCTAssertEqual(latestSnapshots.map(\.name), ["after.replacement"])
        XCTAssertTrue(staleSnapshots.isEmpty)
        withExtendedLifetime((first, latest, stale)) {}
    }

    func testReleasedSubscriptionIdentitiesDoNotBlockNewRegistrations() async {
        for priorKind in [ConnectionRegistrationKind.ordinary, .replaceable] {
            for nextKind in ConnectionRegistrationKind.allCases {
                let scenario = "\(priorKind.rawValue) -> \(nextKind.rawValue)"
                let identityAnchor = ConnectionIdentityAnchor()
                let hub = EventHub(cleanupInterval: 3600, subscriberIdentity: { _ in ObjectIdentifier(identityAnchor) })
                let oldOwner = UUID()
                let nextOwner = UUID()
                let priorReleased = expectation(description: "Prior recorder released: \(scenario)")
                weak var priorBridge: MetricsEventBridge?
                do {
                    let recorder = ConnectionLifetimeRecorder(onDeinit: { priorReleased.fulfill() })
                    let bridge = MetricsEventBridge(recorder: recorder)
                    priorBridge = bridge
                    if priorKind == .ordinary {
                        await hub.subscribe(bridge)
                    } else {
                        _ = await hub.replaceSubscription(owner: oldOwner, generation: EventSubscriptionGeneration(), with: bridge)
                    }
                }
                await fulfillment(of: [priorReleased], timeout: 2)
                guard priorBridge == nil else {
                    XCTFail("Cannot reuse identity before prior bridge deallocation: \(scenario)")
                    continue
                }

                let storage = MetricsStorage()
                let retainedBridge: MetricsEventBridge?
                let connectionID: UUID?
                if nextKind == .owned {
                    retainedBridge = nil
                    connectionID = await hub.connectMetrics(storage)
                } else {
                    let bridge = MetricsEventBridge(recorder: storage)
                    retainedBridge = bridge
                    connectionID = nil
                    if nextKind == .ordinary {
                        await hub.subscribe(bridge)
                    } else {
                        _ = await hub.replaceSubscription(owner: nextOwner, generation: EventSubscriptionGeneration(), with: bridge)
                    }
                }

                await hub.emit(connectionMetricEvent("before.old.owner.removal"))
                let beforeRemoval = await storage.getAll()
                XCTAssertEqual(beforeRemoval.map(\.name), ["before.old.owner.removal"], scenario)

                let removed = await hub.replaceSubscription(owner: oldOwner, generation: EventSubscriptionGeneration(), with: nil)
                XCTAssertNil(removed.retired, scenario)
                await hub.emit(connectionMetricEvent("after.old.owner.removal"))
                let afterRemoval = await storage.getAll()
                XCTAssertEqual(afterRemoval.map(\.name), ["before.old.owner.removal", "after.old.owner.removal"], scenario)

                if let connectionID { await hub.disconnectMetrics(connectionID) }
                withExtendedLifetime(retainedBridge) {}
            }
        }
    }

    func testUnsubscribedReplacementOwnerCannotRemoveReadmittedSubscriber() async {
        for nextKind in [ConnectionRegistrationKind.ordinary, .replaceable] {
            let hub = EventHub()
            let storage = MetricsStorage()
            let bridge = MetricsEventBridge(recorder: storage)
            let oldOwner = UUID()
            _ = await hub.replaceSubscription(owner: oldOwner, generation: EventSubscriptionGeneration(), with: bridge)
            await hub.unsubscribe(bridge)

            if nextKind == .ordinary {
                await hub.subscribe(bridge)
            } else {
                _ = await hub.replaceSubscription(owner: UUID(), generation: EventSubscriptionGeneration(), with: bridge)
            }
            await hub.emit(connectionMetricEvent("readmitted"))
            let removed = await hub.replaceSubscription(owner: oldOwner, generation: EventSubscriptionGeneration(), with: nil)
            XCTAssertNil(removed.retired, nextKind.rawValue)
            await hub.emit(connectionMetricEvent("after.old.owner.removal"))

            let snapshots = await storage.getAll()
            XCTAssertEqual(snapshots.map(\.name), ["readmitted", "after.old.owner.removal"], nextKind.rawValue)
            withExtendedLifetime(bridge) {}
        }
    }
}

private enum ConnectionRegistrationKind: String, CaseIterable {
    case ordinary, replaceable, owned
}

private final class ConnectionIdentityAnchor: Sendable {}

private func connectionMetricEvent(_ name: String) -> PipelineEvent {
    PipelineEvent(
        name: "metric.counter.recorded",
        properties: ["metric_name": name, "metric_value": 1.0],
        correlationID: "connection-lifecycle"
    )
}

private actor ConnectionLifetimeRecorder: MetricRecorder {
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit { onDeinit() }

    func record(_ snapshot: MetricSnapshot) {}
}

private actor ConnectionDeliveryGate {
    private let onEntry: @Sendable () -> Void
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(onEntry: @escaping @Sendable () -> Void) {
        self.onEntry = onEntry
    }

    func wait() async {
        if !entered {
            entered = true
            onEntry()
        }
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class GatedConnectionRecorder: MetricRecorder {
    private let storage: MetricsStorage
    private let gate: ConnectionDeliveryGate
    private let onDeinit: @Sendable () -> Void

    init(storage: MetricsStorage, gate: ConnectionDeliveryGate, onDeinit: @escaping @Sendable () -> Void) {
        self.storage = storage
        self.gate = gate
        self.onDeinit = onDeinit
    }

    deinit { onDeinit() }

    func record(_ snapshot: MetricSnapshot) async {
        await gate.wait()
        await storage.record(snapshot)
    }
}

private actor SelfDisconnectingRecorder: MetricRecorder {
    private weak var hub: EventHub?
    private let storage: MetricsStorage
    private let onDisconnect: @Sendable () -> Void
    private var connectionID: UUID?

    init(hub: EventHub, storage: MetricsStorage, onDisconnect: @escaping @Sendable () -> Void) {
        self.hub = hub
        self.storage = storage
        self.onDisconnect = onDisconnect
    }

    func setConnectionID(_ connectionID: UUID) { self.connectionID = connectionID }

    func record(_ snapshot: MetricSnapshot) async {
        if let connectionID { await hub?.disconnectMetrics(connectionID) }
        onDisconnect()
        await storage.record(snapshot)
    }
}

private actor ConnectionMetricsTransport: MetricsTransport {
    struct Configuration: Sendable {}
    private(set) var packets: [String] = []
    private(set) var closes = 0

    init() {}
    init(configuration: Configuration) async throws {}

    func send(_ data: Data) throws { packets.append(try XCTUnwrap(String(data: data, encoding: .utf8))) }
    func sendBatch(_ batch: [Data]) throws { for data in batch { try send(data) } }
    func close() { closes += 1 }
}
