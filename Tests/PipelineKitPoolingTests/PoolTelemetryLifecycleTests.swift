import Foundation
import XCTest
@testable import PipelineKitPooling

@MainActor
final class PoolTelemetryLifecycleTests: XCTestCase {
    func testAllocationRateUsesPreviousSampleAndRejectsResetOrInvalidTime() {
        let before = snapshot(allocations: 100, time: 10)
        let cases: [(Int, TimeInterval, Double?)] = [
            (130, 12, 15), (100, 12, 0), (99, 12, nil),
            (130, 10, nil), (130, 9, nil), (130, .infinity, nil),
            (Int.max, 10 + Double.leastNonzeroMagnitude, nil)
        ]
        for (allocations, time, expected) in cases {
            let result = PoolMetricsCollector.allocationRate(from: before, to: snapshot(allocations: allocations, time: time))
            if let expected { XCTAssertEqual(result ?? -1, expected, accuracy: 0.001) }
            else { XCTAssertNil(result) }
        }
        XCTAssertNil(PoolMetricsCollector.allocationRate(from: snapshot(allocations: -1, time: 10), to: before))
    }

    func testAllocationAlertUsesPreviousSampleEvenWithoutRetainedHistory() async {
        for historySize in [0, 2] {
            let slept = expectation(description: "first collection slept")
            let second = expectation(description: "second snapshot exported")
            let sleeper = PoolManualSleeper { count in if count == 1 { slept.fulfill() } }
            let source = PoolSnapshotSequence([snapshot(allocations: 100, time: 10), snapshot(allocations: 130, time: 12)])
            let sink = PoolSnapshotSink()
            let collector = PoolMetricsCollector(
                maxHistorySize: historySize,
                snapshotProvider: { await source.next() },
                sleep: { try await sleeper.sleep($0) },
                memoryPressure: .inert
            )
            var thresholds = silentThresholds()
            thresholds.maxAllocationRate = 10
            await collector.configureAlerts(thresholds)
            await collector.registerExporter { value in
                await sink.record(value)
                if value.alert == nil && value.totalAllocations == 130 { second.fulfill() }
            }
            await collector.startCollecting()
            await fulfillment(of: [slept], timeout: 2)
            await sleeper.advanceFirst()
            await fulfillment(of: [second], timeout: 2)
            let rates = await sink.values.compactMap { value -> Double? in
                if case .highAllocationRate(let rate) = value.alert { return rate }
                return nil
            }
            let history = await collector.history
            XCTAssertEqual(rates.count, 1)
            XCTAssertEqual(rates.first ?? -1, 15, accuracy: 0.001)
            XCTAssertEqual(history.count, historySize)
            await collector.stopCollecting()
        }
    }

    func testExporterMayStopCollectorWithoutJoiningItself() async {
        let stopped = expectation(description: "exporter returned from stop")
        let collector = PoolMetricsCollector(collectionInterval: 3600)
        await collector.configureAlerts(silentThresholds())
        await collector.registerExporter { [weak collector] _ in
            await collector?.stopCollecting()
            stopped.fulfill()
        }
        await collector.startCollecting()
        await fulfillment(of: [stopped], timeout: 2)
        let history = await collector.history
        XCTAssertTrue(history.isEmpty)
        await collector.stopCollecting()
    }

    func testStopDuringRegistrationCannotReplaceRestartedHandler() async {
        let registrationEntered = expectation(description: "first registration suspended")
        let firstCollectionSlept = expectation(description: "first run collected")
        let secondCollectionSlept = expectation(description: "second run collected")
        let barrier = PoolAsyncBarrier { registrationEntered.fulfill() }
        let detector = PoolDetectorProbe(firstRegistrationBarrier: barrier)
        let sleeper = PoolManualSleeper { count in
            if count == 1 { firstCollectionSlept.fulfill() }
            if count == 2 { secondCollectionSlept.fulfill() }
        }
        let source = PoolSnapshotSequence([snapshot(allocations: 1, time: 1)])
        let collector = PoolMetricsCollector(
            snapshotProvider: { await source.next() },
            sleep: { try await sleeper.sleep($0) },
            memoryPressure: detector.client
        )
        await collector.configureAlerts(silentThresholds())
        let firstStart = Task { await collector.startCollecting() }
        await fulfillment(of: [registrationEntered, firstCollectionSlept], timeout: 2)
        await collector.stopCollecting()
        let sink = PoolSnapshotSink()
        await collector.registerExporter { await sink.record($0) }
        await collector.startCollecting()
        await barrier.release()
        await firstStart.value
        await fulfillment(of: [secondCollectionSlept], timeout: 2)
        let registered = await detector.activeIDs
        let removed = await detector.removedIDs
        XCTAssertEqual(registered.count, 1)
        XCTAssertEqual(removed.count, 1)
        let beforeStaleCallback = await sink.values.count
        await detector.invokeFirstHandler()
        let afterStaleCallback = await sink.values.count
        XCTAssertEqual(afterStaleCallback, beforeStaleCallback)
        await collector.stopCollecting()
        let finalIDs = await detector.activeIDs
        XCTAssertTrue(finalIDs.isEmpty)
    }

    func testDroppingCollectorWhileSnapshotSuspendsReleasesOwner() async {
        let sourceEntered = expectation(description: "snapshot suspended")
        let barrier = PoolAsyncBarrier { sourceEntered.fulfill() }
        var collector: PoolMetricsCollector? = PoolMetricsCollector(
            snapshotProvider: {
                await barrier.wait()
                return snapshot(allocations: 1, time: 1)
            },
            sleep: { try await Task.sleep(nanoseconds: $0) },
            memoryPressure: .inert
        )
        let witness = PoolTelemetryWeakReference(value: collector)
        await collector?.startCollecting()
        await fulfillment(of: [sourceEntered], timeout: 2)
        collector = nil
        XCTAssertNil(witness.value)
        await barrier.release()
    }

    func testDropUnregistersCollectorsMemoryPressureHandler() async {
        let slept = expectation(description: "collector idle")
        let unregistered = expectation(description: "handler unregistered on drop")
        let sleeper = PoolManualSleeper { _ in slept.fulfill() }
        let detector = PoolDetectorProbe(onUnregister: { unregistered.fulfill() })
        var collector: PoolMetricsCollector? = PoolMetricsCollector(
            snapshotProvider: { snapshot(allocations: 1, time: 1) },
            sleep: { try await sleeper.sleep($0) },
            memoryPressure: detector.client
        )
        let witness = PoolTelemetryWeakReference(value: collector)
        await collector?.configureAlerts(silentThresholds())
        await collector?.startCollecting()
        await fulfillment(of: [slept], timeout: 2)
        collector = nil
        XCTAssertNil(witness.value)
        await fulfillment(of: [unregistered], timeout: 2)
        let handlers = await detector.activeIDs
        XCTAssertTrue(handlers.isEmpty)
    }

    func testPeriodicExporterStopsWhileSleepingAndCanRestart() async {
        let firstSleep = expectation(description: "first export sleep")
        let firstCancelled = expectation(description: "first export sleep cancelled")
        let secondSleep = expectation(description: "restart export sleep")
        let exported = expectation(description: "restarted export delivered")
        let sleeper = PoolManualSleeper(onCancellation: { count in
            if count == 1 { firstCancelled.fulfill() }
        }) { count in
            if count == 1 { firstSleep.fulfill() }
            if count == 2 { secondSleep.fulfill() }
        }
        let metrics = PoolObservability(sleep: { try await sleeper.sleep($0) })
        let sink = PoolExportCount()
        await metrics.registerExporter { _ in
            await sink.increment()
            exported.fulfill()
        }
        await metrics.startExporting(interval: 3600)
        await fulfillment(of: [firstSleep], timeout: 2)
        await metrics.stopExporting()
        await fulfillment(of: [firstCancelled], timeout: 2)
        await metrics.startExporting(interval: 3600)
        await fulfillment(of: [secondSleep], timeout: 2)
        await sleeper.advanceFirst()
        await fulfillment(of: [exported], timeout: 2)
        await metrics.stopExporting()
        let count = await sink.value
        XCTAssertEqual(count, 1)
    }

    func testPeriodicExporterMayStopFromItsCallbackAndOwnerDrops() async {
        let sleeping = expectation(description: "export sleep")
        let stopped = expectation(description: "callback stopped run")
        let sleeper = PoolManualSleeper { _ in sleeping.fulfill() }
        var metrics: PoolObservability? = PoolObservability(sleep: { try await sleeper.sleep($0) })
        let witness = PoolTelemetryWeakReference(value: metrics)
        await metrics?.registerExporter { [weak metrics] _ in
            await metrics?.stopExporting()
            stopped.fulfill()
        }
        await metrics?.startExporting(interval: 3600)
        await fulfillment(of: [sleeping], timeout: 2)
        await sleeper.advanceFirst()
        await fulfillment(of: [stopped], timeout: 2)
        metrics = nil
        let deadline = ContinuousClock.now + .seconds(1)
        while witness.value != nil && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNil(witness.value)
    }

    private func silentThresholds() -> AlertThresholds {
        var thresholds = AlertThresholds()
        thresholds.minHitRate = -.infinity
        thresholds.minEfficiency = -.infinity
        thresholds.maxAllocationRate = .infinity
        return thresholds
    }
}

private func snapshot(allocations: Int, time: TimeInterval) -> PoolMetricsSnapshot {
    PoolMetricsSnapshot(timestamp: Date(timeIntervalSince1970: time), poolStatistics: [], overallHitRate: 100,
                        overallEfficiency: 2, totalAllocations: allocations, memoryPressureEvents: 0, currentMemoryUsage: 0)
}

private extension PoolMetricsMemoryPressureClient {
    static let inert = Self(register: { _ in UUID() }, unregister: { _ in }, start: {})
}

private actor PoolSnapshotSequence {
    private var values: [PoolMetricsSnapshot]
    private var index = 0
    init(_ values: [PoolMetricsSnapshot]) { self.values = values }
    func next() -> PoolMetricsSnapshot {
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

private actor PoolSnapshotSink {
    var values: [PoolMetricsSnapshot] = []
    func record(_ value: PoolMetricsSnapshot) { values.append(value) }
}

private actor PoolExportCount {
    var value = 0
    func increment() { value += 1 }
}

private actor PoolAsyncBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private let onEnter: @Sendable () -> Void
    init(onEnter: @escaping @Sendable () -> Void) { self.onEnter = onEnter }
    func wait() async {
        onEnter()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor PoolManualSleeper {
    private var pending: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var count = 0
    private var cancellationCount = 0
    private let onCancellation: @Sendable (Int) -> Void
    private let onSleep: @Sendable (Int) -> Void
    init(onCancellation: @escaping @Sendable (Int) -> Void = { _ in }, onSleep: @escaping @Sendable (Int) -> Void) {
        self.onCancellation = onCancellation
        self.onSleep = onSleep
    }
    func sleep(_ nanoseconds: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pending.append((id, continuation))
                    count += 1
                    onSleep(count)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func advanceFirst() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().1.resume()
    }
    private func cancel(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.0 == id }) else { return }
        pending.remove(at: index).1.resume(throwing: CancellationError())
        cancellationCount += 1
        onCancellation(cancellationCount)
    }
}

private actor PoolDetectorProbe {
    private var handlers: [(UUID, @Sendable () async -> Void)] = []
    private(set) var removedIDs: [UUID] = []
    private let firstRegistrationBarrier: PoolAsyncBarrier?
    private let onUnregister: @Sendable () -> Void
    init(firstRegistrationBarrier: PoolAsyncBarrier? = nil, onUnregister: @escaping @Sendable () -> Void = {}) {
        self.firstRegistrationBarrier = firstRegistrationBarrier
        self.onUnregister = onUnregister
    }
    nonisolated var client: PoolMetricsMemoryPressureClient {
        .init(register: { await self.register($0) }, unregister: { await self.unregister($0) }, start: {})
    }
    var activeIDs: [UUID] { handlers.map(\.0).filter { !removedIDs.contains($0) } }
    func register(_ handler: @escaping @Sendable () async -> Void) async -> UUID {
        let id = UUID()
        handlers.append((id, handler))
        if handlers.count == 1 { await firstRegistrationBarrier?.wait() }
        return id
    }
    func unregister(_ id: UUID) {
        removedIDs.append(id)
        onUnregister()
    }
    func invokeFirstHandler() async { await handlers.first?.1() }
}
