import Foundation
import PipelineKit
import PipelineKitResilience
import Synchronization
import XCTest
@testable import _ResilienceFoundation

final class BackPressurePolicyContractTests: XCTestCase {
    private static let strategies: [BackPressureStrategy] = [
        .suspend, .error(timeout: nil), .error(timeout: 60), .dropNewest, .dropOldest
    ]

    func testEveryStrategyEnforcesOutstandingBoundWhenAllSlotsAreActive() async throws {
        for strategy in Self.strategies {
            for concurrency in [1, 3] {
                for explicitTimeout in [false, true] {
                    let semaphore = BackPressureSemaphore(maxConcurrency: concurrency, maxOutstanding: 1, strategy: strategy)
                    let held = try await semaphore.acquire()
                    let ledger = PolicyLedger()
                    let excess = enqueue("excess", semaphore: semaphore, ledger: ledger, timeout: explicitTimeout ? 60 : nil)
                    let observed = await eventually {
                        let result = await ledger.name("excess")
                        let queuedCount = await semaphore.getStats().queuedOperations
                        return result != nil || queuedCount > 0
                    }
                    XCTAssertTrue(observed)
                    let stats = await semaphore.getStats()
                    let rejection = await ledger.name("excess")
                    XCTAssertEqual(stats.totalOutstanding, 1, "\(strategy), concurrency \(concurrency), explicit \(explicitTimeout)")
                    XCTAssertEqual(stats.queuedOperations, 0)
                    XCTAssertEqual(rejection, strategy == .dropNewest ? "dropped" : "full")
                    await finish(semaphore, held: held, tasks: [excess])
                }
            }
        }
    }

    func testEveryStrategyBoundsActivePlusQueuedWork() async throws {
        for strategy in Self.strategies {
            let semaphore = BackPressureSemaphore(maxConcurrency: 1, maxOutstanding: 3, strategy: strategy)
            let held = try await semaphore.acquire()
            let ledger = PolicyLedger()
            let first = enqueue("first", semaphore: semaphore, ledger: ledger)
            await assertQueued(1, semaphore)
            let second = enqueue("second", semaphore: semaphore, ledger: ledger)
            await assertQueued(2, semaphore)
            let incoming = enqueue("incoming", semaphore: semaphore, ledger: ledger)
            let observed = await eventually {
                let names = await ledger.names()
                let count = await semaphore.getStats().queuedOperations
                return !names.isEmpty || count > 2
            }
            XCTAssertTrue(observed)
            let stats = await semaphore.getStats()
            let names = await ledger.names()
            XCTAssertEqual(stats.totalOutstanding, 3, "\(strategy)")
            XCTAssertEqual(stats.queuedOperations, 2, "\(strategy)")
            let expected = strategy == .dropOldest ? ["first": "dropped"] :
                ["incoming": strategy == .dropNewest ? "dropped" : "full"]
            XCTAssertEqual(names, expected, "\(strategy)")
            await finish(semaphore, held: held, tasks: [first, second, incoming])
        }
    }

    func testDropOldestAndPriorityFIFOIgnoreEqualOrReversedWallClock() async throws {
        for offsets: [TimeInterval] in [[0, 10, 20], [0, 0, 0], [0, -10, -20]] {
            let clock = PolicyWallClock()
            let semaphore = BackPressureSemaphore(options: .init(
                maxConcurrency: 1, maxOutstanding: 4, backPressureStrategy: .dropOldest
            ), now: { clock.now() })
            let held = try await semaphore.acquire()
            let ledger = PolicyLedger()
            var tasks: [Task<PolicyOutcome, Never>] = []
            for (index, priority) in [BackPressureSemaphore.QueuePriority.low, .high, .high].enumerated() {
                clock.set(1_000 + offsets[index])
                tasks.append(enqueue("w\(index)", semaphore: semaphore, ledger: ledger, priority: priority))
                await assertQueued(index + 1, semaphore)
            }
            clock.set(1_100)
            tasks.append(enqueue("incoming", semaphore: semaphore, ledger: ledger))
            let evicted = await eventually { !(await ledger.names()).isEmpty }
            XCTAssertTrue(evicted)
            let names = await ledger.names()
            XCTAssertEqual(names, ["w0": "dropped"], "\(offsets)")
            let stats = await semaphore.getStats()
            XCTAssertEqual(stats.oldestWaiterAge ?? -1, 100 - offsets[1], accuracy: 0.000_001)
            held.release()
            await drainGrants(3, ledger: ledger)
            let grants = await ledger.grants()
            XCTAssertEqual(grants, ["w1", "w2", "incoming"], "\(offsets)")
            await finish(semaphore, held: held, tasks: tasks)
        }
    }

    func testDropOldestChecksReplacementMemoryBeforeEvicting() async throws {
        for incomingSize in [8, 9] {
            let semaphore = BackPressureSemaphore(
                maxConcurrency: 1, maxOutstanding: 3, maxQueueMemory: 10, strategy: .dropOldest
            )
            let held = try await semaphore.acquire()
            let ledger = PolicyLedger()
            let oldest = enqueue("oldest", semaphore: semaphore, ledger: ledger, priority: .low, size: 8)
            await assertQueued(1, semaphore)
            let newest = enqueue("newest", semaphore: semaphore, ledger: ledger, priority: .high, size: 2)
            await assertQueued(2, semaphore)
            let incoming = enqueue("incoming", semaphore: semaphore, ledger: ledger, size: incomingSize)
            let observed = await eventually { !(await ledger.names()).isEmpty }
            XCTAssertTrue(observed)
            let names = await ledger.names()
            XCTAssertEqual(names, incomingSize == 8 ? ["oldest": "dropped"] : ["incoming": "memory"])
            let stats = await semaphore.getStats()
            XCTAssertEqual(stats.queuedOperations, 2)
            XCTAssertEqual(stats.queueMemoryUsage, 10)
            await finish(semaphore, held: held, tasks: [oldest, newest, incoming])
        }
    }

    func testImmediateOnlyTimeoutNeverEvictsOrRegistersAcrossStrategies() async throws {
        for strategy in Self.strategies {
            for timeout: TimeInterval in [-1, 0] {
                let semaphore = BackPressureSemaphore(maxConcurrency: 1, maxOutstanding: 2, strategy: strategy)
                let held = try await semaphore.acquire()
                let ledger = PolicyLedger()
                let queued = enqueue("queued", semaphore: semaphore, ledger: ledger)
                await assertQueued(1, semaphore)
                let result = await policyAcquire(semaphore, timeout: timeout)
                XCTAssertEqual(result.name, "timeout")
                let stats = await semaphore.getStats()
                XCTAssertEqual(stats.totalOutstanding, 2)
                XCTAssertEqual(stats.queuedOperations, 1)
                let names = await ledger.names()
                XCTAssertTrue(names.isEmpty)
                result.token?.release()
                await finish(semaphore, held: held, tasks: [queued])
            }
        }
    }

    func testCancellationAtEveryQueuePositionPreservesBothOrders() async throws {
        for cancelledIndex in 0..<3 {
            let clock = PolicyWallClock()
            let semaphore = BackPressureSemaphore(options: .init(
                maxConcurrency: 1, maxOutstanding: 4, backPressureStrategy: .dropOldest
            ), now: { clock.now() })
            let held = try await semaphore.acquire()
            let ledger = PolicyLedger()
            var tasks: [Task<PolicyOutcome, Never>] = []
            for (index, priority) in [BackPressureSemaphore.QueuePriority.low, .critical, .high].enumerated() {
                tasks.append(enqueue("w\(index)", semaphore: semaphore, ledger: ledger, priority: priority))
                await assertQueued(index + 1, semaphore)
            }
            tasks[cancelledIndex].cancel()
            let cancelled = await eventually { await ledger.name("w\(cancelledIndex)") != nil }
            XCTAssertTrue(cancelled)
            let cancellation = await ledger.name("w\(cancelledIndex)")
            XCTAssertEqual(cancellation, "cancelled")
            tasks.append(enqueue("replacement", semaphore: semaphore, ledger: ledger))
            await assertQueued(3, semaphore)
            tasks.append(enqueue("overflow", semaphore: semaphore, ledger: ledger))
            let evicted = await eventually { (await ledger.names()).count == 2 }
            XCTAssertTrue(evicted)
            let droppedID = cancelledIndex == 0 ? "w1" : "w0"
            let dropped = await ledger.name(droppedID)
            XCTAssertEqual(dropped, "dropped")
            held.release()
            await drainGrants(3, ledger: ledger)
            let grants = await ledger.grants()
            let survivor = cancelledIndex == 2 ? "w1" : "w2"
            XCTAssertEqual(grants, [survivor, "replacement", "overflow"])
            await finish(semaphore, held: held, tasks: tasks)
        }
    }

    func testTimeoutAndShutdownClearQueueOrderBeforeReuse() async throws {
        for removal in ["timeout", "shutdown"] {
            let semaphore = BackPressureSemaphore(maxConcurrency: 1, maxOutstanding: 2, strategy: .dropOldest)
            let held = try await semaphore.acquire()
            let ledger = PolicyLedger()
            // Expiration is the tested outcome, not a delay used to order tasks.
            let first = enqueue("removed", semaphore: semaphore, ledger: ledger, timeout: removal == "timeout" ? 0.01 : nil)
            if removal == "shutdown" {
                await assertQueued(1, semaphore)
                await semaphore.shutdown()
            }
            let removed = await eventually { await ledger.name("removed") != nil }
            XCTAssertTrue(removed)
            let result = await ledger.name("removed")
            XCTAssertEqual(result, removal == "timeout" ? "timeout" : "dropped")
            await assertQueued(0, semaphore)
            let next = enqueue("next", semaphore: semaphore, ledger: ledger, priority: .high)
            await assertQueued(1, semaphore)
            let replacement = enqueue("replacement", semaphore: semaphore, ledger: ledger, priority: .low)
            let evicted = await eventually { await ledger.name("next") != nil }
            XCTAssertTrue(evicted)
            let dropped = await ledger.name("next")
            XCTAssertEqual(dropped, "dropped")
            held.release()
            await drainGrants(1, ledger: ledger)
            let grants = await ledger.grants()
            XCTAssertEqual(grants, ["replacement"])
            await finish(semaphore, held: held, tasks: [first, next, replacement])
        }
    }

    func testSettledPublicExecutionReleasesCapacityBeforeReturning() async throws {
        for strategy in Self.strategies {
            for route in SettledPolicyRoute.allCases {
                for firstFails in [false, true] {
                    let middleware = BackPressureMiddleware(maxConcurrency: 1, maxOutstanding: 1, strategy: strategy)
                    let pipeline = ConcurrentPipeline(options: .init(
                        maxConcurrency: 1, maxOutstanding: 1, backPressureStrategy: strategy
                    ))
                    await pipeline.register(SettledPolicyCommand.self, pipeline: StandardPipeline(handler: SettledPolicyHandler()))
                    let failure = SettledPolicyFailure()
                    // Consecutive awaited calls exercise the public handoff itself;
                    // no polling or delay gives a deferred release time to catch up.
                    for index in 0..<2 {
                        let shouldFail = firstFails && index == 0
                        let command = SettledPolicyCommand(failure: shouldFail ? failure : nil)
                        do {
                            let result: Int
                            switch route {
                            case .middleware:
                                result = try await middleware.execute(command, context: CommandContext()) { command, _ in
                                    try command.resolve()
                                }
                            case .middlewareSized:
                                result = try await middleware.execute(command, context: CommandContext(), estimatedSize: 1) { command, _ in
                                    try command.resolve()
                                }
                            case .pipeline:
                                result = try await pipeline.execute(command)
                            case .pipelineTimed:
                                result = try await pipeline.execute(command, timeout: 60)
                            }
                            XCTAssertFalse(shouldFail)
                            XCTAssertEqual(result, 7)
                        } catch {
                            XCTAssertTrue(shouldFail, "\(strategy), \(route), call \(index): \(error)")
                            XCTAssertTrue((error as? SettledPolicyFailure) === failure, "Handler error identity changed: \(error)")
                        }
                    }
                    switch route {
                    case .middleware, .middlewareSized:
                        let stats = await middleware.getStats()
                        XCTAssertEqual(stats.activeOperations, 0, "\(strategy), \(route), failed first \(firstFails)")
                        XCTAssertEqual(stats.queuedRequests, 0)
                    case .pipeline, .pipelineTimed:
                        let stats = await pipeline.getCapacityStats()
                        XCTAssertEqual(stats.activeOperations, 0, "\(strategy), \(route), failed first \(firstFails)")
                        XCTAssertEqual(stats.totalOutstanding, 0)
                    }
                }
            }
        }
    }

    func testAcknowledgedTokenReleaseJoinsDuplicateAndCancelledCallers() async {
        let probe = AcknowledgedReleaseProbe()
        let token = SemaphoreToken(asyncReleaseHandler: { await probe.callback() })
        token.release()
        let started = await eventually { await probe.callbackCount == 1 }
        XCTAssertTrue(started)
        XCTAssertTrue(token.isReleased)

        let first = Task {
            await probe.joinStarted("first")
            await token.releaseAndWait()
            await probe.joinCompleted("first")
        }
        let cancelled = Task {
            await probe.joinStarted("cancelled")
            await token.releaseAndWait()
            await probe.joinCompleted("cancelled")
        }
        let joining = await eventually { await probe.startedCount == 2 }
        XCTAssertTrue(joining)
        cancelled.cancel()
        token.release()

        // Observe the forbidden early completion while the callback is acknowledged
        // as suspended. The bounded observation is not used to order callback entry.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(20))
        var returnedEarly = false
        while ContinuousClock.now < deadline {
            if await probe.completedCount != 0 { returnedEarly = true; break }
            await Task.yield()
        }
        XCTAssertFalse(returnedEarly)
        await probe.open()
        await first.value
        await cancelled.value
        await token.releaseAndWait()
        token.release()
        let callbackCount = await probe.callbackCount
        let completedCount = await probe.completedCount
        let earlyCompletions = await probe.earlyCompletions
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(completedCount, 2)
        XCTAssertTrue(earlyCompletions.isEmpty)
    }

    func testPublicTokenKeepsSynchronousReleaseAndDeinitSemantics() async {
        let counter = SynchronousReleaseCounter()
        let token = SemaphoreToken { counter.increment() }
        token.release()
        XCTAssertEqual(counter.count(), 1)
        token.release()
        await token.releaseAndWait()
        XCTAssertEqual(counter.count(), 1)
        do {
            let automatic = SemaphoreToken { counter.increment() }
            XCTAssertFalse(automatic.isReleased)
        }
        XCTAssertEqual(counter.count(), 2)
    }

    private func enqueue(
        _ id: String,
        semaphore: BackPressureSemaphore,
        ledger: PolicyLedger,
        priority: BackPressureSemaphore.QueuePriority = .normal,
        size: Int = 1,
        timeout: TimeInterval? = nil
    ) -> Task<PolicyOutcome, Never> {
        Task { @concurrent in
            let outcome = await policyAcquire(semaphore, priority: priority, size: size, timeout: timeout)
            await ledger.record(id, outcome)
            return outcome
        }
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private func assertQueued(_ count: Int, _ semaphore: BackPressureSemaphore) async {
        let observed = await eventually { await semaphore.getStats().queuedOperations == count }
        XCTAssertTrue(observed, "Expected \(count) queued operations")
    }

    private func drainGrants(_ count: Int, ledger: PolicyLedger) async {
        for index in 0..<count {
            let granted = await eventually { await ledger.grants().count > index }
            XCTAssertTrue(granted)
            guard granted else { return }
            await ledger.releaseGrant(at: index)
        }
    }

    private func finish(_ semaphore: BackPressureSemaphore, held: SemaphoreToken, tasks: [Task<PolicyOutcome, Never>]) async {
        tasks.forEach { $0.cancel() }
        held.release()
        await semaphore.shutdown()
        for task in tasks { (await task.value).token?.release() }
        let conserved = await eventually {
            let stats = await semaphore.getStats()
            return stats.activeOperations == 0 && stats.queuedOperations == 0 && stats.availableResources == stats.maxConcurrency
        }
        XCTAssertTrue(conserved)
    }
}

private enum PolicyOutcome: Sendable {
    case granted(SemaphoreToken)
    case rejected(String)

    var name: String {
        switch self {
        case .granted: "granted"
        case .rejected(let name): name
        }
    }

    var token: SemaphoreToken? {
        if case .granted(let token) = self { return token }
        return nil
    }
}

private func policyAcquire(
    _ semaphore: BackPressureSemaphore,
    priority: BackPressureSemaphore.QueuePriority = .normal,
    size: Int = 1,
    timeout: TimeInterval? = nil
) async -> PolicyOutcome {
    do {
        if let timeout {
            guard let token = try await semaphore.acquire(timeout: timeout, priority: priority, estimatedSize: size) else {
                return .rejected("unexpected nil token")
            }
            return .granted(token)
        }
        return .granted(try await semaphore.acquire(priority: priority, estimatedSize: size))
    } catch PipelineError.backPressure(.queueFull) { return .rejected("full") } catch PipelineError.backPressure(.commandDropped) { return .rejected("dropped") } catch PipelineError.backPressure(.memoryPressure) { return .rejected("memory") } catch PipelineError.backPressure(.timeout) { return .rejected("timeout") } catch let error as PipelineError where error.isCancellation { return .rejected("cancelled") } catch { return .rejected("unexpected: \(error)") }
}

private actor PolicyLedger {
    private var outcomes: [String: PolicyOutcome] = [:]
    private var grantOrder: [String] = []

    func record(_ id: String, _ outcome: PolicyOutcome) {
        outcomes[id] = outcome
        if outcome.token != nil { grantOrder.append(id) }
    }

    func name(_ id: String) -> String? { outcomes[id]?.name }
    func names() -> [String: String] { outcomes.mapValues(\.name) }
    func grants() -> [String] { grantOrder }
    func releaseGrant(at index: Int) { outcomes[grantOrder[index]]?.token?.release() }
}

private final class PolicyWallClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_000))
    func now() -> Date { date.withLock { $0 } }
    func set(_ seconds: TimeInterval) { date.withLock { $0 = Date(timeIntervalSince1970: seconds) } }
}

private enum SettledPolicyRoute: CaseIterable {
    case middleware, middlewareSized, pipeline, pipelineTimed
}

private final class SettledPolicyFailure: Error, Sendable {}

private struct SettledPolicyCommand: Command {
    typealias Result = Int
    let failure: SettledPolicyFailure?

    func resolve() throws -> Int {
        if let failure { throw failure }
        return 7
    }
}

private struct SettledPolicyHandler: CommandHandler {
    func handle(_ command: SettledPolicyCommand, context: CommandContext) async throws -> Int {
        try command.resolve()
    }
}

private actor AcknowledgedReleaseProbe {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var started: Set<String> = []
    private var completed: Set<String> = []
    private(set) var callbackCount = 0
    private(set) var earlyCompletions: Set<String> = []

    var startedCount: Int { started.count }
    var completedCount: Int { completed.count }

    func callback() async {
        callbackCount += 1
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func joinStarted(_ id: String) { started.insert(id) }
    func joinCompleted(_ id: String) {
        completed.insert(id)
        if !opened { earlyCompletions.insert(id) }
    }

    func open() {
        opened = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private final class SynchronousReleaseCounter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    func count() -> Int { value.withLock { $0 } }
}
