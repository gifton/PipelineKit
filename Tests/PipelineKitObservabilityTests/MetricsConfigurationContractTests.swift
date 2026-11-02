import Foundation
import Synchronization
import XCTest
@testable import PipelineKitObservability

final class MetricsConfigurationContractTests: XCTestCase {
    private var savedConfiguration: Metrics.Configuration?

    override func setUp() async throws {
        savedConfiguration = Metrics.configuration
        await Metrics.configure(.init(storage: MetricsStorage(), exporter: ConfigurationRecorder()))
    }

    override func tearDown() async throws {
        if let savedConfiguration { await Metrics.configure(savedConfiguration) }
        savedConfiguration = nil
    }

    func testRecordUsesOneConfigurationAcrossSuspension() async {
        let storageA = MetricsStorage()
        let storageB = MetricsStorage()
        let recorderA = ConfigurationRecorder()
        let recorderB = ConfigurationRecorder()
        let gate = ConfigurationGate()
        await Metrics.configure(.init(storage: storageA, exporter: recorderA))
        let recording = Task {
            await Metrics.record(.counter("generation.a"), afterStorage: { await gate.pause() })
        }
        await gate.waitForEntry()
        await Metrics.configure(.init(storage: storageB, exporter: recorderB))
        await gate.release()
        await recording.value

        let storedA = await storageA.getAll()
        let storedB = await storageB.getAll()
        let exportedA = await recorderA.names
        let exportedB = await recorderB.names
        XCTAssertEqual(storedA.map(\.name), ["generation.a"])
        XCTAssertEqual(exportedA, ["generation.a"])
        XCTAssertTrue(storedB.isEmpty)
        XCTAssertTrue(exportedB.isEmpty)

        await Metrics.counter("generation.b.counter")
        await Metrics.gauge("generation.b.gauge", value: 2)
        await Metrics.timer("generation.b.timer", duration: 0.25)
        let laterStored = await storageB.getAll()
        let laterExported = await recorderB.names
        XCTAssertEqual(laterStored.map(\.name).sorted(), laterExported.sorted())
        XCTAssertEqual(laterExported, ["generation.b.counter", "generation.b.gauge", "generation.b.timer"])
        let unchangedA = await recorderA.names
        XCTAssertEqual(unchangedA, ["generation.a"])
    }

    func testDisablePreservesStorageAndInFlightConfiguration() async {
        let storageA = MetricsStorage()
        let storageB = MetricsStorage()
        let recorderA = ConfigurationRecorder()
        let recorderB = ConfigurationRecorder()
        let gate = ConfigurationGate()
        await Metrics.configure(.init(storage: storageA, exporter: recorderA))
        let recording = Task {
            await Metrics.record(.counter("before.disable"), afterStorage: { await gate.pause() })
        }
        await gate.waitForEntry()
        Metrics.disable()
        XCTAssertTrue(Metrics.configuration.storage === storageA)
        await Metrics.counter("while.disabled")
        await Metrics.configure(.init(storage: storageB, exporter: recorderB))
        await gate.release()
        await recording.value
        await Metrics.counter("after.configure")

        let storedA = await storageA.getAll()
        let storedB = await storageB.getAll()
        let exportedA = await recorderA.names
        let exportedB = await recorderB.names
        XCTAssertEqual(storedA.map(\.name).sorted(), ["before.disable", "while.disabled"])
        XCTAssertEqual(exportedA, ["before.disable"])
        XCTAssertEqual(storedB.map(\.name), ["after.configure"])
        XCTAssertEqual(exportedB, ["after.configure"])
    }

    func testFlushDoesNotRecordSnapshotsAgain() async {
        let recorder = ConfigurationRecorder()
        let storage = MetricsStorage()
        await Metrics.configure(.init(storage: storage, exporter: recorder))
        await Metrics.counter("only.once")
        await Metrics.flush()
        let firstDrain = await storage.drain()
        XCTAssertTrue(firstDrain.isEmpty)
        await Metrics.flush()
        let names = await recorder.names
        let flushes = await recorder.flushCount
        XCTAssertEqual(names, ["only.once"])
        XCTAssertEqual(flushes, 2)
    }

    func testFlushKeepsCapturedConfigurationDuringConfigureAndDisable() async {
        for disableDuringFlush in [false, true] {
            let storageA = MetricsStorage()
            let storageB = MetricsStorage()
            let gate = ConfigurationGate()
            let recorderA = ConfigurationRecorder(flushGate: gate)
            let recorderB = ConfigurationRecorder()
            await Metrics.configure(.init(storage: storageA, exporter: recorderA))
            await Metrics.counter("flush.a")
            let flushing = Task { await Metrics.flush() }
            await gate.waitForEntry()
            if disableDuringFlush { Metrics.disable() }
            await Metrics.configure(.init(storage: storageB, exporter: recorderB))
            await Metrics.counter("flush.b")
            await Metrics.flush()
            await gate.release()
            await flushing.value

            let namesA = await recorderA.names
            let namesB = await recorderB.names
            let flushesA = await recorderA.flushCount
            let flushesB = await recorderB.flushCount
            let remainingA = await storageA.getAll()
            let remainingB = await storageB.getAll()
            XCTAssertEqual(namesA, ["flush.a"])
            XCTAssertEqual(namesB, ["flush.b"])
            XCTAssertEqual(flushesA, 1)
            XCTAssertEqual(flushesB, 1)
            XCTAssertTrue(remainingA.isEmpty)
            XCTAssertTrue(remainingB.isEmpty)
        }
    }

    func testFlushDoesNotPromiseABarrierForConcurrentRecords() async {
        let gate = ConfigurationGate()
        let storage = MetricsStorage()
        let recorder = ConfigurationRecorder(flushGate: gate)
        await Metrics.configure(.init(storage: storage, exporter: recorder))
        await Metrics.counter("before.drain")
        let flushing = Task { await Metrics.flush() }
        await gate.waitForEntry()
        await Metrics.counter("after.drain")
        await gate.release()
        await flushing.value
        let stored = await storage.getAll()
        let names = await recorder.names
        XCTAssertEqual(stored.map(\.name), ["after.drain"])
        XCTAssertEqual(names, ["before.drain", "after.drain"])
    }

    func testConfigurationCallbacksCanReenterAndRelease() async {
        let events = ConfigurationEvents()
        let gate = ConfigurationGate()
        await installReentrantCaptures(events: events)
        let recording = Task {
            await Metrics.record(.counter("retained"), afterStorage: { await gate.pause() })
        }
        await gate.waitForEntry()
        await Metrics.configure(.init(storage: MetricsStorage(), exporter: ConfigurationRecorder()))
        XCTAssertTrue(events.values.isEmpty, "The in-flight snapshot still owns both captures")
        await gate.release()
        await recording.value
        XCTAssertEqual(events.values.first, "recorded:retained")
        XCTAssertEqual(events.values.sorted(), ["callback.released", "exporter.released", "recorded:retained"])
    }

    func testReplacingOrDisablingLastOwnedExporterReleasesOutsideLock() async {
        for disable in [false, true] {
            let events = ConfigurationEvents()
            await installReentrantCaptures(events: events)
            if disable {
                Metrics.disable()
                // disable retains the configured callback; replacing the full snapshot releases it.
                XCTAssertEqual(events.values, ["exporter.released"])
            }
            await Metrics.configure(.init(storage: MetricsStorage(), exporter: ConfigurationRecorder()))
            XCTAssertEqual(events.values.sorted(), ["callback.released", "exporter.released"])
        }
    }

    func testFlushRetainsCallbackUntilCapturedExporterSettles() async {
        let events = ConfigurationEvents()
        let gate = ConfigurationGate()
        await installFlushCapture(events: events, gate: gate)
        let flushing = Task { await Metrics.flush() }
        await gate.waitForEntry()
        await Metrics.configure(.init(storage: MetricsStorage(), exporter: ConfigurationRecorder()))
        XCTAssertTrue(events.values.isEmpty)
        await gate.release()
        await flushing.value
        XCTAssertEqual(events.values, ["callback.released"])
    }

    func testStatsDCallbackCanReenterConfigureAndDisable() async throws {
        let transport = try await MockTransport(configuration: .init(shouldFail: true))
        let exporter = StatsDExporter(configuration: statsDConfiguration(), transport: transport)
        let storage = MetricsStorage()
        let replacementStorage = MetricsStorage()
        let replacementRecorder = ConfigurationRecorder()
        let events = ConfigurationEvents()
        let callbackTask = Mutex<Task<Void, Never>?>(nil)
        await Metrics.configure(.init(storage: storage, exporter: exporter, errorHandler: { _ in
            XCTAssertTrue(Metrics.configuration.storage === storage)
            Metrics.disable()
            events.append("callback")
            let task = Task { @concurrent in
                await Metrics.configure(.init(storage: replacementStorage, exporter: replacementRecorder))
            }
            callbackTask.withLock { $0 = task }
        }))
        await Metrics.counter("failure")
        let task = callbackTask.withLock { $0 }
        XCTAssertNotNil(task)
        await task?.value
        XCTAssertEqual(events.values, ["callback"])
        XCTAssertTrue(Metrics.configuration.storage === replacementStorage)
        await Metrics.counter("replacement")
        let names = await replacementRecorder.names
        XCTAssertEqual(names, ["replacement"])
        await exporter.close()
    }

    func testConfigurePreparesAndClearsStatsDCallback() async throws {
        let events = ConfigurationEvents()
        let transport = try await MockTransport(configuration: .init(shouldFail: true))
        let exporter = StatsDExporter(configuration: statsDConfiguration(), transport: transport)
        await exporter.setErrorHandler { _ in events.append("stale") }
        await Metrics.configure(.init(storage: MetricsStorage(), exporter: exporter,
                                      errorHandler: { _ in events.append("configured") }))
        await Metrics.counter("configured.failure")
        await Metrics.configure(.init(storage: MetricsStorage(), exporter: exporter))
        await Metrics.counter("cleared.failure")
        XCTAssertEqual(events.values, ["configured"])
        await exporter.close()
    }

    func testConveniencesPreserveSnapshotStorageAndHandler() async throws {
        let storage = MetricsStorage()
        let events = ConfigurationEvents()
        await Metrics.configure(.init(storage: storage, exporter: ConfigurationRecorder(),
                                      errorHandler: { _ in events.append("configured") }))
        await Metrics.configure(host: "127.0.0.1", port: 0, maxBatchSize: 1)
        XCTAssertTrue(Metrics.configuration.storage === storage)
        let hostExporter = try XCTUnwrap(Metrics.configuration.exporter as? StatsDExporter)
        await Metrics.counter("invalid.port")
        XCTAssertEqual(events.values, ["configured"])
        await hostExporter.close()

        let transport = try await MockTransport(configuration: .init(shouldFail: true))
        let custom = StatsDExporter(configuration: statsDConfiguration(), transport: transport)
        await Metrics.configure(with: custom)
        XCTAssertTrue(Metrics.configuration.storage === storage)
        await Metrics.counter("custom.failure")
        XCTAssertEqual(events.values, ["configured", "configured"])
        await custom.close()
    }

    func testStatsDFlushProtocolDeliversBufferedRecordOnlyOnce() async throws {
        let transport = try await MockTransport(configuration: .init())
        let exporter = StatsDExporter(configuration: statsDConfiguration(maxBatchSize: 20), transport: transport)
        await Metrics.configure(.init(storage: MetricsStorage(), exporter: exporter))
        await Metrics.counter("buffered")
        let before = await transport.getSendCount()
        XCTAssertEqual(before, 0)
        await Metrics.flush()
        await Metrics.flush()
        let packets = await transport.getMetricsAsStrings()
        XCTAssertEqual(packets, ["buffered:1.0|c"])
        await exporter.close()
    }

    func testReusingRecorderSharesStateAndDoesNotCloseRetiredExporter() async throws {
        let transport = try await MockTransport(configuration: .init())
        let exporter = StatsDExporter(configuration: statsDConfiguration(maxBatchSize: 20), transport: transport)
        let storageA = MetricsStorage()
        let storageB = MetricsStorage()
        await Metrics.configure(.init(storage: storageA, exporter: exporter))
        await Metrics.counter("shared.a")
        await Metrics.configure(.init(storage: storageB, exporter: exporter))
        await Metrics.counter("shared.b")
        await Metrics.flush()
        let packets = await transport.getMetricsAsStrings()
        XCTAssertEqual(packets, ["shared.a:1.0|c", "shared.b:1.0|c"])
        await Metrics.configure(with: ConfigurationRecorder())
        let closed = await exporter.isClosed
        XCTAssertFalse(closed)
        // The caller still owns the retired exporter and can flush it explicitly.
        await exporter.counter("retired")
        await exporter.flush()
        let retainedPackets = await transport.getMetricsAsStrings()
        XCTAssertEqual(retainedPackets, ["shared.a:1.0|c", "shared.b:1.0|c", "retired:1.0|c"])
        let retainedStorage = await storageA.getAll()
        XCTAssertEqual(retainedStorage.map(\.name), ["shared.a"])
        await exporter.close()
    }

    private func statsDConfiguration(maxBatchSize: Int = 1) -> StatsDExporter.Configuration {
        .init(maxBatchSize: maxBatchSize, flushInterval: 60, aggregation: .init(enabled: false))
    }

    private func installReentrantCaptures(events: ConfigurationEvents) async {
        let capture = ConfigurationReleaseProbe {
            _ = Metrics.configuration
            Metrics.disable()
            events.append("callback.released")
        }
        let recorder = ReentrantLifetimeRecorder(events: events)
        await Metrics.configure(.init(storage: MetricsStorage(), exporter: recorder,
                                      errorHandler: { [capture] _ in withExtendedLifetime(capture) {} }))
    }

    private func installFlushCapture(events: ConfigurationEvents, gate: ConfigurationGate) async {
        let capture = ConfigurationReleaseProbe {
            _ = Metrics.configuration
            Metrics.disable()
            events.append("callback.released")
        }
        await Metrics.configure(.init(storage: MetricsStorage(), exporter: ConfigurationRecorder(flushGate: gate),
                                      errorHandler: { [capture] _ in withExtendedLifetime(capture) {} }))
    }
}

private actor ConfigurationRecorder: FlushableMetricRecorder {
    private(set) var names: [String] = []
    private(set) var flushCount = 0
    private let flushGate: ConfigurationGate?

    init(flushGate: ConfigurationGate? = nil) { self.flushGate = flushGate }
    func record(_ snapshot: MetricSnapshot) { names.append(snapshot.name) }
    func flush() async {
        flushCount += 1
        await flushGate?.pause()
    }
}

private actor ConfigurationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }

    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class ConfigurationEvents: Sendable {
    private let events = Mutex<[String]>([])
    var values: [String] { events.withLock { $0 } }
    func append(_ event: String) { events.withLock { $0.append(event) } }
}

private final class ConfigurationReleaseProbe: Sendable {
    private let onRelease: @Sendable () -> Void
    init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

private final class ReentrantLifetimeRecorder: MetricRecorder {
    private let events: ConfigurationEvents
    init(events: ConfigurationEvents) { self.events = events }
    func record(_ snapshot: MetricSnapshot) async { events.append("recorded:\(snapshot.name)") }
    deinit {
        _ = Metrics.configuration
        Metrics.disable()
        events.append("exporter.released")
    }
}
