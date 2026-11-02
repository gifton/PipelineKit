import Foundation
import Synchronization
import XCTest
@testable import PipelineKitObservability

final class StatsDStartupContractTests: XCTestCase {
    private func configuration(maxBatchSize: Int = 1) -> StatsDExporter.Configuration {
        .init(maxBatchSize: maxBatchSize, flushInterval: 60,
              aggregation: .init(enabled: false))
    }

    func testConcurrentNonemptyBatchesWaitForOneStartup() async throws {
        let factory = StartupFactory()
        let transport = StartupTransport()
        let exporter = StatsDExporter(configuration: configuration(), transportFactory: { try await factory.make() })
        let lazyStarts = await factory.starts
        XCTAssertEqual(lazyStarts, 0)
        let names = ["startup.first", "startup.second", "startup.third"]
        let calls = names.map { name in Task { await exporter.counter(name) } }
        await waitForStartupWaiters(3, exporter: exporter)
        let explicitStart = Task { try await exporter.start() }
        await waitForStartupWaiters(4, exporter: exporter)
        await factory.waitForStarts(1)
        let before = await transport.packets
        XCTAssertTrue(before.isEmpty)
        let starts = await factory.starts
        XCTAssertEqual(starts, 1)
        await factory.succeed(1, with: transport)
        for call in calls { await call.value }
        if case .failure(let error) = await explicitStart.result { XCTFail("Unexpected start error: \(error)") }
        let packets = await transport.packets
        XCTAssertEqual(packets.sorted(), names.map { "\($0):1.0|c" }.sorted())
        let waiters = await exporter.startupWaiterCount
        XCTAssertEqual(waiters, 0)
        await exporter.close()
        let settled = await factory.settled
        XCTAssertEqual(settled, 1)
        let closes = await transport.closes
        XCTAssertEqual(closes, 1)
    }

    func testStartupFailureSettlesEveryBatchAndCanRestart() async throws {
        let factory = StartupFactory()
        let errors = StartupErrors()
        let transport = StartupTransport()
        let exporter = StatsDExporter(configuration: configuration(), transportFactory: { try await factory.make() })
        await exporter.setErrorHandler { errors.append($0) }
        let failed = (1...3).map { index in Task { await exporter.counter("failed.\(index)") } }
        await waitForStartupWaiters(3, exporter: exporter)
        await factory.waitForStarts(1)
        await factory.fail(1)
        // A new generation can enter as soon as an old caller observes failure;
        // joining the other old callers must not clear that new generation.
        while errors.values.isEmpty { await Task.yield() }
        let retry = Task { await exporter.counter("retry.first") }
        await factory.waitForStarts(2)
        for call in failed { await call.value }
        XCTAssertEqual(errors.values, Array(repeating: "connection:fixture-startup", count: 3))
        let second = Task { await exporter.counter("retry.second") }
        let third = Task { await exporter.counter("retry.third") }
        await waitForStartupWaiters(3, exporter: exporter)
        let before = await transport.packets
        XCTAssertTrue(before.isEmpty)
        await factory.succeed(2, with: transport)
        await retry.value
        await second.value
        await third.value
        try await exporter.start()
        let starts = await factory.starts
        XCTAssertEqual(starts, 2)
        let packets = await transport.packets
        XCTAssertEqual(packets.sorted(), ["retry.first:1.0|c", "retry.second:1.0|c", "retry.third:1.0|c"])
        let settled = await factory.settled
        XCTAssertEqual(settled, 2)
        await exporter.close()
    }

    func testCloseDuringStartupClosesLateTransport() async {
        let factory = StartupFactory()
        let errors = StartupErrors()
        let transport = StartupTransport()
        let exporter = StatsDExporter(configuration: configuration(), transportFactory: { try await factory.make() })
        await exporter.setErrorHandler { errors.append($0) }
        let calls = (1...3).map { index in Task { await exporter.counter("closing.\(index)") } }
        await waitForStartupWaiters(3, exporter: exporter)
        await factory.waitForStarts(1)
        let finishedClose = StartupCloseCounter()
        let firstClose = Task {
            await exporter.close()
            finishedClose.increment()
        }
        let secondClose = Task {
            await exporter.close()
            finishedClose.increment()
        }
        while !(await exporter.isClosed) { await Task.yield() }
        while !factory.cancellationObserved.withLock({ $0 }) { await Task.yield() }
        XCTAssertEqual(finishedClose.value, 0)
        await exporter.counter("after.close.entry")
        XCTAssertEqual(errors.values, ["closed"])
        // The fixture deliberately ignores cancellation until released here.
        await factory.succeed(1, with: transport)
        await firstClose.value
        await secondClose.value
        for call in calls { await call.value }
        await exporter.close()
        XCTAssertEqual(finishedClose.value, 2)
        XCTAssertEqual(errors.values, Array(repeating: "closed", count: 4))
        let packets = await transport.packets
        let closes = await transport.closes
        let settled = await factory.settled
        let waiters = await exporter.startupWaiterCount
        XCTAssertTrue(packets.isEmpty)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(settled, 1)
        XCTAssertEqual(waiters, 0)
    }

    func testRecordAfterCloseReportsFailure() async throws {
        let transport = StartupTransport()
        let errors = StartupErrors()
        let exporter = StatsDExporter(configuration: .init(sampleRate: 0), transport: transport)
        await exporter.setErrorHandler { errors.append($0) }
        await exporter.close()
        await exporter.counter("unsampled.after.close")
        XCTAssertEqual(errors.values, ["closed"])
        await exporter.setErrorHandler(nil)
        await exporter.counter("handler.cleared")
        do {
            try await exporter.start()
            XCTFail("Closed exporter started")
        } catch TransportError.transportClosed {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(errors.values, ["closed"])
        let packets = await transport.packets
        let closes = await transport.closes
        XCTAssertTrue(packets.isEmpty)
        XCTAssertEqual(closes, 1)
    }

    func testNonemptyForceFlushReportsStartupFailureAndRetries() async {
        let factory = StartupFactory()
        let errors = StartupErrors()
        let transport = StartupTransport()
        let exporter = StatsDExporter(configuration: configuration(maxBatchSize: 10),
                                      transportFactory: { try await factory.make() })
        await exporter.setErrorHandler { errors.append($0) }
        await exporter.counter("flush.failed.first")
        await exporter.counter("flush.failed.second")
        let failedFlush = Task { await exporter.forceFlush() }
        await waitForStartupWaiters(1, exporter: exporter)
        await factory.waitForStarts(1)
        await factory.fail(1)
        await failedFlush.value
        XCTAssertEqual(errors.values, ["connection:fixture-startup"])
        await exporter.counter("flush.retry")
        let retryFlush = Task { await exporter.forceFlush() }
        await factory.waitForStarts(2)
        await factory.succeed(2, with: transport)
        await retryFlush.value
        let packets = await transport.packets
        XCTAssertEqual(packets, ["flush.retry:1.0|c"])
        await exporter.close()
        let settled = await factory.settled
        XCTAssertEqual(settled, 2)
    }

    func testInjectedTransportIsReadyAndClosesOnce() async throws {
        let transport = StartupTransport()
        let exporter = StatsDExporter(configuration: configuration(), transport: transport)
        try await exporter.start()
        for index in 1...3 { await exporter.counter("injected.\(index)") }
        await exporter.forceFlush()
        await exporter.close()
        await exporter.close()
        let packets = await transport.packets
        let closes = await transport.closes
        XCTAssertEqual(packets, (1...3).map { "injected.\($0):1.0|c" })
        XCTAssertEqual(closes, 1)
    }

    func testCloseDiscardsBufferedRecordsAndJoinsFlushTimer() async {
        let transport = StartupTransport()
        let exporter = StatsDExporter(configuration: configuration(maxBatchSize: 10), transport: transport)
        await exporter.counter("buffered.unsent")
        await exporter.close()
        await exporter.forceFlush()
        let packets = await transport.packets
        let closes = await transport.closes
        XCTAssertTrue(packets.isEmpty)
        XCTAssertEqual(closes, 1)
    }

    func testCloseJoinsTimerAlreadyWaitingForStartup() async {
        let factory = StartupFactory()
        let errors = StartupErrors()
        let transport = StartupTransport()
        let exporter = StatsDExporter(configuration: .init(maxBatchSize: 10, flushInterval: 0),
                                      transportFactory: { try await factory.make() })
        await exporter.setErrorHandler { errors.append($0) }
        await exporter.counter("timer.pending")
        await factory.waitForStarts(1)
        await waitForStartupWaiters(1, exporter: exporter)
        let closing = Task { await exporter.close() }
        while !(await exporter.isClosed) { await Task.yield() }
        while !factory.cancellationObserved.withLock({ $0 }) { await Task.yield() }
        await factory.succeed(1, with: transport)
        await closing.value
        let waiters = await exporter.startupWaiterCount
        let closes = await transport.closes
        let packets = await transport.packets
        let settled = await factory.settled
        XCTAssertEqual(waiters, 0)
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(packets.isEmpty)
        XCTAssertEqual(settled, 1)
        XCTAssertEqual(errors.values, ["closed"])
    }

    func testExplicitStartAndDefaultBatchReportInvalidConfiguration() async {
        let errors = StartupErrors()
        let exporter = StatsDExporter(configuration: .init(port: 0, maxBatchSize: 1))
        await exporter.setErrorHandler { errors.append($0) }
        do {
            try await exporter.start()
            XCTFail("Invalid default transport configuration started")
        } catch TransportError.invalidConfiguration {} catch { XCTFail("Unexpected error: \(error)") }
        await exporter.counter("default.invalid")
        XCTAssertEqual(errors.values.count, 2)
        XCTAssertTrue(errors.values.allSatisfy { $0.hasPrefix("invalid:") })
        await exporter.close()
    }

    #if !canImport(Network)
    func testDefaultConstructorReportsNetworkUnavailable() async {
        let errors = StartupErrors()
        let exporter = StatsDExporter(configuration: configuration())
        await exporter.setErrorHandler { errors.append($0) }
        do {
            try await exporter.start()
            XCTFail("Network-unavailable startup succeeded")
        } catch TransportError.connectionFailed(let message) {
            XCTAssertEqual(message, "Network framework not available")
        } catch { XCTFail("Unexpected error: \(error)") }
        await exporter.counter("unavailable.first")
        XCTAssertEqual(errors.values, Array(repeating: "connection:Network framework not available", count: 2))
        await exporter.close()
    }
    #endif

    private func waitForStartupWaiters(_ count: Int, exporter: StatsDExporter) async {
        // Observe actual registration, not an elapsed scheduling delay. The
        // external run_check.py watchdog bounds a broken registration path.
        while await exporter.startupWaiterCount != count { await Task.yield() }
    }
}

private final class StartupCloseCounter: Sendable {
    private let storage = Mutex<Int>(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}

private final class StartupErrors: Sendable {
    private let storage = Mutex<[String]>([])
    var values: [String] { storage.withLock { $0 } }
    func append(_ error: any Error) {
        let value: String
        switch error {
        case TransportError.transportClosed: value = "closed"
        case TransportError.connectionFailed(let message): value = "connection:\(message)"
        case TransportError.invalidConfiguration(let message): value = "invalid:\(message)"
        default: value = String(describing: error)
        }
        storage.withLock { $0.append(value) }
    }
}

private actor StartupFactory {
    private(set) var starts = 0
    private(set) var settled = 0
    nonisolated let cancellationObserved = Mutex(false)
    private var pending: [Int: CheckedContinuation<any MetricsTransport, any Error>] = [:]

    func make() async throws -> any MetricsTransport {
        defer { settled += 1 }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                starts += 1
                pending[starts] = continuation
            }
        } onCancel: {
            self.cancellationObserved.withLock { $0 = true }
        }
    }

    func waitForStarts(_ count: Int) async {
        while starts < count { await Task.yield() }
    }

    func succeed(_ generation: Int, with transport: any MetricsTransport) {
        pending.removeValue(forKey: generation)!.resume(returning: transport)
    }

    func fail(_ generation: Int) {
        pending.removeValue(forKey: generation)!.resume(throwing: TransportError.connectionFailed("fixture-startup"))
    }
}

private actor StartupTransport: MetricsTransport {
    struct Configuration: Sendable {}
    private(set) var packets: [String] = []
    private(set) var closes = 0
    init() {}
    init(configuration: Configuration) async throws {}
    func send(_ data: Data) async throws {
        guard closes == 0 else { throw TransportError.transportClosed }
        packets.append(String(decoding: data, as: UTF8.self))
    }
    func sendBatch(_ batch: [Data]) async throws {
        for packet in batch { try await send(packet) }
    }
    func close() async { closes += 1 }
}
