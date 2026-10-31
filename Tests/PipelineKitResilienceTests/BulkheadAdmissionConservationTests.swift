import XCTest
import PipelineKitCore
import PipelineKitResilience
import _ResilienceFoundation

// The schedules and handler ledger remain shared across all three wrappers.
struct BulkheadAdmissionSubject: Sendable {
    let name: String
    let execute: @Sendable (String, CommandContext, @escaping @Sendable () async throws -> String) async throws -> String
    let snapshot: @Sendable () async -> (active: Int, queued: Int)

    static func ordinary(capacity: Int, queue: Int) -> Self {
        let middleware = BulkheadMiddleware(configuration: .init(
            maxConcurrency: capacity, maxQueueSize: queue, rejectionPolicy: .queue
        ))
        return ordinary(middleware)
    }

    static func ordinary(_ middleware: BulkheadMiddleware) -> Self {
        Self(name: "ordinary", execute: { id, context, operation in
            try await middleware.execute(AdmissionCommand(id: id), context: context) { _, _ in
                try await operation()
            }
        }, snapshot: { await middleware.admissionSnapshot() })
    }

    static func legacy(capacity: Int, queue: Int) -> Self {
        let bulkhead = Bulkhead(name: "conservation", maxConcurrency: capacity, maxWaitingCalls: queue)
        return Self(name: "legacy", execute: { _, _, operation in
            try await bulkhead.execute(operation: operation)
        }, snapshot: {
            let stats = await bulkhead.getStats()
            return (stats.activeCalls, stats.waitingCalls)
        })
    }

    static func partitioned(capacity: Int, queue: Int) -> Self {
        partitioned(PartitionedBulkheadMiddleware(configuration: .init(
            partitions: ["default": .init(capacity: capacity, queueSize: queue)],
            partitionExtractor: { _, _ in "default" }, allowBorrowing: false
        )))
    }

    static func partitioned(_ middleware: PartitionedBulkheadMiddleware, partition: String = "default") -> Self {
        Self(name: "partitioned", execute: { id, context, operation in
            try await middleware.execute(AdmissionCommand(id: id), context: context) { _, _ in
                try await operation()
            }
        }, snapshot: { await middleware.admissionSnapshot(partition: partition) })
    }
}

struct AdmissionCommand: Command {
    typealias Result = String
    let id: String
}

enum BulkheadFixtureError: Error { case expected }

actor BulkheadHandlerLedger {
    private var open: Set<String> = []
    private var holds: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var active: Set<String> = []
    private(set) var entries: [String] = []
    private(set) var peak = 0
    private(set) var terminals: [String: String] = [:]
    private(set) var events: [String] = []

    func run(_ id: String, fails: Bool) async throws -> String {
        active.insert(id)
        entries.append(id)
        peak = max(peak, active.count)
        events.append("entered:\(id)")
        if !open.contains(id) {
            await withCheckedContinuation { holds[id] = $0 }
        }
        active.remove(id)
        events.append("settled:\(id)")
        if fails { throw BulkheadFixtureError.expected }
        return id
    }

    func release(_ id: String) {
        open.insert(id)
        events.append("release:\(id)")
        holds.removeValue(forKey: id)?.resume()
    }

    func record(_ event: String) { events.append(event) }
    func terminal(_ id: String, _ result: String) {
        terminals[id] = result
        events.append("terminal:\(id):\(result)")
    }
    func entered(_ id: String) -> Bool { entries.contains(id) }
    func finished(_ id: String) -> Bool { terminals[id] != nil }
}

func launchBulkhead(
    _ subject: BulkheadAdmissionSubject,
    id: String,
    ledger: BulkheadHandlerLedger,
    fails: Bool = false,
    context: CommandContext = CommandContext()
) -> Task<String, Never> {
    Task { @concurrent in
        await ledger.record("attempt:\(id)")
        let outcome: String
        do {
            _ = try await subject.execute(id, context) { try await ledger.run(id, fails: fails) }
            outcome = "success"
        } catch is CancellationError {
            outcome = "cancelled"
        } catch BulkheadFixtureError.expected {
            outcome = "handlerError"
        } catch PipelineError.middlewareError(_, _, let context) {
            outcome = context?.additionalInfo["type"] == "BulkheadTimeout" ? "timedOut" : "rejected"
        } catch PipelineError.resilience(reason: .bulkheadFull) {
            outcome = "rejected"
        } catch {
            outcome = "unexpected:\(type(of: error))"
        }
        await ledger.terminal(id, outcome)
        return outcome
    }
}

final class BulkheadAdmissionConservationTests: XCTestCase {
    private func subjects(capacity: Int, queue: Int) -> [BulkheadAdmissionSubject] {
        [
            .ordinary(capacity: capacity, queue: queue),
            .legacy(capacity: capacity, queue: queue),
            .partitioned(capacity: capacity, queue: queue)
        ]
    }

    private func entered(_ id: String, ledger: BulkheadHandlerLedger) async -> Bool {
        while !(await ledger.entered(id)) {
            if await ledger.finished(id) { return false }
            await Task.yield()
        }
        return true
    }

    private func queued(_ count: Int, subject: BulkheadAdmissionSubject, id: String, ledger: BulkheadHandlerLedger) async -> Bool {
        while await subject.snapshot().queued != count {
            if await ledger.finished(id) { return false }
            if await ledger.entered(id) { return false }
            await Task.yield()
        }
        await ledger.record("queued:\(id)")
        return true
    }

    private func assertSettled(_ subject: BulkheadAdmissionSubject, ledger: BulkheadHandlerLedger) async {
        let snapshot = await subject.snapshot()
        let active = await ledger.active
        XCTAssertEqual(snapshot.active, 0, subject.name)
        XCTAssertEqual(snapshot.queued, 0, subject.name)
        XCTAssertTrue(active.isEmpty, subject.name)
    }

    func testQueueBudgetIsReusableAcrossAcknowledgedWaves() async {
        for subject in subjects(capacity: 1, queue: 1) {
            let ledger = BulkheadHandlerLedger()
            // Eight contended waves exceed the one-place queue budget. Successful,
            // throwing and cancelled waiters each must return their queue position.
            for wave in 0..<8 {
                let holderID = "holder-\(wave)"
                let waiterID = "waiter-\(wave)"
                let holder = launchBulkhead(subject, id: holderID, ledger: ledger)
                let holderEntered = await entered(holderID, ledger: ledger)
                XCTAssertTrue(holderEntered, subject.name)
                let waiter = launchBulkhead(subject, id: waiterID, ledger: ledger, fails: wave % 3 == 1)
                let didQueue = await queued(1, subject: subject, id: waiterID, ledger: ledger)
                XCTAssertTrue(didQueue, "\(subject.name), wave \(wave)")
                if wave % 3 == 2 {
                    waiter.cancel()
                    await ledger.record("cancel:\(waiterID)")
                }
                await ledger.release(holderID)
                await ledger.release(waiterID)
                let holderResult = await holder.value
                let waiterResult = await waiter.value
                XCTAssertEqual(holderResult, "success", subject.name)
                let expected = wave % 3 == 2 ? "cancelled" : wave % 3 == 1 ? "handlerError" : "success"
                XCTAssertEqual(waiterResult, expected, "\(subject.name), wave \(wave)")
                await assertSettled(subject, ledger: ledger)
            }
            let peak = await ledger.peak
            XCTAssertEqual(peak, 1, subject.name)
            print("R02 waves \(subject.name): \(await ledger.events)")
        }
        await ordinaryTimeoutWaves()
    }

    func testImmediateAdmissionCancellationReleasesCapacity() async {
        for subject in subjects(capacity: 1, queue: 1) {
            for beforeAdmission in [true, false] {
                let ledger = BulkheadHandlerLedger()
                await ledger.release("immediate")
                let cancelled = Task { @concurrent in
                    if beforeAdmission { withUnsafeCurrentTask { $0?.cancel() } }
                    do {
                        _ = try await subject.execute("immediate", CommandContext()) {
                            _ = try await ledger.run("immediate", fails: false)
                            withUnsafeCurrentTask { $0?.cancel() }
                            throw CancellationError()
                        }
                        return false
                    } catch is CancellationError {
                        return true
                    } catch {
                        return false
                    }
                }
                let sawCancellation = await cancelled.value
                XCTAssertTrue(sawCancellation, subject.name)
                let entries = await ledger.entries
                XCTAssertEqual(entries, beforeAdmission ? [] : ["immediate"], subject.name)
                await assertSettled(subject, ledger: ledger)

                // A fresh caller observes the returned capacity after the
                // cancelled invocation has completed, without a release task.
                await ledger.release("replacement")
                let replacement = launchBulkhead(subject, id: "replacement", ledger: ledger)
                let replacementResult = await replacement.value
                XCTAssertEqual(replacementResult, "success", subject.name)
                await assertSettled(subject, ledger: ledger)
            }
        }
    }

    func testQueuedCancellationAndActiveCancellationConserveOwnership() async {
        for subject in subjects(capacity: 1, queue: 1) {
            let ledger = BulkheadHandlerLedger()
            let holder = launchBulkhead(subject, id: "held", ledger: ledger)
            let holderEntered = await entered("held", ledger: ledger)
            XCTAssertTrue(holderEntered)
            let cancelled = launchBulkhead(subject, id: "cancelled", ledger: ledger)
            let didQueue = await queued(1, subject: subject, id: "cancelled", ledger: ledger)
            XCTAssertTrue(didQueue)
            cancelled.cancel()
            await ledger.record("cancel:cancelled")
            let cancelledResult = await cancelled.value
            XCTAssertEqual(cancelledResult, "cancelled", subject.name)
            var snapshot = await subject.snapshot()
            XCTAssertEqual(snapshot.active, 1)
            XCTAssertEqual(snapshot.queued, 0)

            // The handler deliberately ignores cancellation until its explicit
            // release. Its lease must remain owned throughout that interval.
            holder.cancel()
            await ledger.record("cancel:held")
            let replacement = launchBulkhead(subject, id: "replacement", ledger: ledger)
            let replacementQueued = await queued(1, subject: subject, id: "replacement", ledger: ledger)
            XCTAssertTrue(replacementQueued)
            await ledger.release("rejected")
            let rejected = launchBulkhead(subject, id: "rejected", ledger: ledger)
            let rejectedResult = await rejected.value
            XCTAssertEqual(rejectedResult, "rejected", subject.name)
            snapshot = await subject.snapshot()
            XCTAssertEqual(snapshot.active, 1)
            XCTAssertEqual(snapshot.queued, 1)
            let beforeRelease = await ledger.entries
            XCTAssertEqual(beforeRelease, ["held"])

            await ledger.release("held")
            let replacementEntered = await entered("replacement", ledger: ledger)
            XCTAssertTrue(replacementEntered)
            await ledger.release("replacement")
            let holderResult = await holder.value
            let replacementResult = await replacement.value
            XCTAssertEqual(holderResult, "success")
            XCTAssertEqual(replacementResult, "success")
            await assertSettled(subject, ledger: ledger)
            print("R02 cancellation \(subject.name): \(await ledger.events)")
        }
    }

    // Legacy Bulkhead exposes no queue deadline. Timeout waves therefore cover
    // the ordinary adapter here; partitioned deadline/sibling schedules live in
    // PartitionedBulkheadAdmissionTests. Success/error/cancel waves cover all three.
    private func ordinaryTimeoutWaves() async {
        let clock = ManualAdmissionClock()
        let gate = AdmissionGate(capacity: 1, maxQueueSize: 1, now: { clock.now() }, sleep: { try await clock.sleep(for: $0) })
        let middleware = BulkheadMiddleware(configuration: .init(
            maxConcurrency: 1, maxQueueSize: 1, queueTimeout: 2, rejectionPolicy: .queue
        ), admission: gate)
        let subject = BulkheadAdmissionSubject.ordinary(middleware)
        let ledger = BulkheadHandlerLedger()
        for wave in 0..<4 {
            let holderID = "timeout-holder-\(wave)"
            let expiringID = "expiring-\(wave)"
            let holder = launchBulkhead(subject, id: holderID, ledger: ledger)
            let holderEntered = await entered(holderID, ledger: ledger)
            XCTAssertTrue(holderEntered)
            let expiring = launchBulkhead(subject, id: expiringID, ledger: ledger)
            let didQueue = await queued(1, subject: subject, id: expiringID, ledger: ledger)
            XCTAssertTrue(didQueue)
            await clock.waitForSleepers(1)
            clock.advance(by: .seconds(2))
            await ledger.record("timeout:\(expiringID)")
            let result = await expiring.value
            XCTAssertEqual(result, "timedOut")
            let retained = await subject.snapshot()
            XCTAssertEqual(retained.active, 1)
            XCTAssertEqual(retained.queued, 0)
            let holderFinished = await ledger.finished(holderID)
            XCTAssertFalse(holderFinished)
            await clock.waitForSettlement()

            let replacementID = "replacement-\(wave)"
            let context = CommandContext()
            let replacement = launchBulkhead(subject, id: replacementID, ledger: ledger, fails: wave % 2 == 1, context: context)
            let replacementQueued = await queued(1, subject: subject, id: replacementID, ledger: ledger)
            XCTAssertTrue(replacementQueued)
            await clock.waitForSleepers(1)
            clock.advance(by: .seconds(1))
            await ledger.release(holderID)
            let replacementEntered = await entered(replacementID, ledger: ledger)
            XCTAssertTrue(replacementEntered)
            // Advancing past the old deadline after grant cannot time out the
            // admitted handler; only its explicit release settles it.
            clock.advance(by: .seconds(5))
            await clock.waitForSettlement()
            let admitted = await subject.snapshot()
            XCTAssertEqual(admitted.active, 1)
            XCTAssertEqual(admitted.queued, 0)
            await ledger.release(replacementID)
            let holderResult = await holder.value
            let replacementResult = await replacement.value
            XCTAssertEqual(holderResult, "success")
            XCTAssertEqual(replacementResult, wave % 2 == 1 ? "handlerError" : "success")
            XCTAssertEqual(context.getMetadata()["bulkhead.wasQueued"] as? Bool, true)
            XCTAssertEqual(context.getMetadata()["bulkhead.activeCount"] as? Int, 0)
            XCTAssertEqual(context.getMetadata()["bulkhead.queuedCount"] as? Int, 0)
            await assertSettled(subject, ledger: ledger)
        }
        print("R02 timeout ordinary: \(await ledger.events)")
    }

    func testLegacyHandoffNeverExposesCapacityToNewArrival() async {
        for capacity in [1, 2] {
            for subject in subjects(capacity: capacity, queue: 2) {
                let ledger = BulkheadHandlerLedger()
                var holders: [Task<String, Never>] = []
                for index in 0..<capacity {
                    let id = "A\(index)"
                    holders.append(launchBulkhead(subject, id: id, ledger: ledger))
                    let didEnter = await entered(id, ledger: ledger)
                    XCTAssertTrue(didEnter)
                }
                let b = launchBulkhead(subject, id: "B", ledger: ledger)
                let bQueued = await queued(1, subject: subject, id: "B", ledger: ledger)
                XCTAssertTrue(bQueued)
                // Both actions become eligible together; the ledger records the
                // schedule actually observed, without claiming a forced old race.
                async let release: Void = ledger.release("A0")
                let c = launchBulkhead(subject, id: "C", ledger: ledger)
                await release
                let bEntered = await entered("B", ledger: ledger)
                XCTAssertTrue(bEntered, subject.name)
                let cQueued = await queued(1, subject: subject, id: "C", ledger: ledger)
                XCTAssertTrue(cQueued, subject.name)
                let snapshot = await subject.snapshot()
                let active = await ledger.active.count
                XCTAssertEqual(snapshot.active, capacity, subject.name)
                XCTAssertEqual(active, capacity, subject.name)
                await ledger.release("B")
                let cEntered = await entered("C", ledger: ledger)
                XCTAssertTrue(cEntered, subject.name)
                await ledger.release("C")
                for index in 1..<capacity { await ledger.release("A\(index)") }
                for holder in holders { let result = await holder.value; XCTAssertEqual(result, "success") }
                let bResult = await b.value
                let cResult = await c.value
                XCTAssertEqual(bResult, "success")
                XCTAssertEqual(cResult, "success")
                let peak = await ledger.peak
                let events = await ledger.events
                XCTAssertEqual(peak, capacity, "\(subject.name): \(events)")
                await assertSettled(subject, ledger: ledger)
                print("R02 handoff \(subject.name) capacity=\(capacity): \(await ledger.events)")
            }
        }
    }
}
