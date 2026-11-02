import XCTest
import Synchronization
import PipelineKitCore
import PipelineKitResilience
import _ResilienceFoundation

final class PartitionedBulkheadAdmissionTests: XCTestCase {
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

    private func assertState(_ subject: BulkheadAdmissionSubject, active: Int, queued: Int) async {
        let state = await subject.snapshot()
        XCTAssertEqual(state.active, active)
        XCTAssertEqual(state.queued, queued)
    }

    func testQueuedHandoffTransfersOneLease() async {
        for capacity in [1, 2] {
            let subject = BulkheadAdmissionSubject.partitioned(capacity: capacity, queue: 3)
            let ledger = BulkheadHandlerLedger()
            var holders: [Task<String, Never>] = []
            for index in 0..<capacity {
                let id = "A\(index)"
                holders.append(launchBulkhead(subject, id: id, ledger: ledger))
                let didEnter = await entered(id, ledger: ledger)
                XCTAssertTrue(didEnter)
            }
            var waiters: [Task<String, Never>] = []
            for index in 0..<3 {
                let id = "B\(index)"
                waiters.append(launchBulkhead(subject, id: id, ledger: ledger, fails: index == 1))
                let didQueue = await queued(index + 1, subject: subject, id: id, ledger: ledger)
                XCTAssertTrue(didQueue)
            }
            await ledger.release("A0")
            for index in 0..<3 {
                let id = "B\(index)"
                let didEnter = await entered(id, ledger: ledger)
                XCTAssertTrue(didEnter)
                await assertState(subject, active: capacity, queued: 2 - index)
                let activeHandlers = await ledger.active.count
                XCTAssertEqual(activeHandlers, capacity)
                await ledger.release(id)
                let result = await waiters[index].value
                XCTAssertEqual(result, index == 1 ? "handlerError" : "success")
            }
            for index in 1..<capacity { await ledger.release("A\(index)") }
            for holder in holders {
                let result = await holder.value
                XCTAssertEqual(result, "success")
            }
            await assertState(subject, active: 0, queued: 0)
            let activeHandlers = await ledger.active.count
            XCTAssertEqual(activeHandlers, 0)
            print("R03 handoffs capacity=\(capacity): \(await ledger.events)")
        }
    }

    func testPublicQueueTimeoutReturnsWhileHolderIsActive() async {
        let middleware = PartitionedBulkheadMiddleware(configuration: .init(
            partitions: ["default": .init(capacity: 1, queueSize: 1, queueTimeout: 0.01)],
            partitionExtractor: { _, _ in "default" }, allowBorrowing: false
        ))
        let subject = BulkheadAdmissionSubject.partitioned(middleware)
        let ledger = BulkheadHandlerLedger()
        let holder = launchBulkhead(subject, id: "A", ledger: ledger)
        let holderEntered = await entered("A", ledger: ledger)
        XCTAssertTrue(holderEntered)
        let waiter = launchBulkhead(subject, id: "B", ledger: ledger)
        let result = await waiter.value
        XCTAssertEqual(result, "timedOut")
        await assertState(subject, active: 1, queued: 0)
        let holderFinished = await ledger.finished("A")
        XCTAssertFalse(holderFinished)
        await ledger.release("A")
        let holderResult = await holder.value
        XCTAssertEqual(holderResult, "success")
        await assertState(subject, active: 0, queued: 0)
    }

    private func timedSubject(_ clock: ManualAdmissionClock, timeout: TimeInterval?) -> BulkheadAdmissionSubject {
        let gate = AdmissionGate(capacity: 1, maxQueueSize: 2,
            now: { clock.now() }, sleep: { try await clock.sleep(for: $0) })
        return .partitioned(PartitionedBulkheadMiddleware(configuration: .init(
            partitions: ["default": .init(capacity: 1, queueSize: 2, queueTimeout: timeout)],
            partitionExtractor: { _, _ in "default" }, allowBorrowing: false
        ), admissions: ["default": gate]))
    }

    func testTimedOutWaiterDoesNotWaitForHolderOrOrphanSibling() async {
        let clock = ManualAdmissionClock()
        let subject = timedSubject(clock, timeout: 4)
        let ledger = BulkheadHandlerLedger()
        let holder = launchBulkhead(subject, id: "A", ledger: ledger)
        let aEntered = await entered("A", ledger: ledger)
        XCTAssertTrue(aEntered)
        let expiring = launchBulkhead(subject, id: "B", ledger: ledger)
        let bQueued = await queued(1, subject: subject, id: "B", ledger: ledger)
        XCTAssertTrue(bQueued)
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        let context = CommandContext()
        let sibling = launchBulkhead(subject, id: "C", ledger: ledger, context: context)
        let cQueued = await queued(2, subject: subject, id: "C", ledger: ledger)
        XCTAssertTrue(cQueued)
        await clock.waitForSleepers(2)
        // One partition policy, staggered arrival: B expires at 4, C at 5.
        clock.advance(by: .seconds(3))
        await ledger.record("expiry:B")
        let bResult = await expiring.value
        XCTAssertEqual(bResult, "timedOut")
        await assertState(subject, active: 1, queued: 1)
        let aFinished = await ledger.finished("A")
        let cFinished = await ledger.finished("C")
        let beforeRelease = await ledger.entries
        XCTAssertFalse(aFinished)
        XCTAssertFalse(cFinished)
        XCTAssertEqual(beforeRelease, ["A"])
        await ledger.release("A")
        let cEntered = await entered("C", ledger: ledger)
        XCTAssertTrue(cEntered)
        clock.advance(by: .seconds(8))
        await clock.waitForSettlement()
        await assertState(subject, active: 1, queued: 0)
        await ledger.release("C")
        let aResult = await holder.value
        let cResult = await sibling.value
        XCTAssertEqual(aResult, "success")
        XCTAssertEqual(cResult, "success")
        XCTAssertEqual(context.getMetadata()["bulkhead.wasQueued"] as? Bool, true)
        XCTAssertEqual(context.getMetadata()["bulkhead.queueTime"] as? Double ?? -1, 3, accuracy: 1e-9)
        await assertState(subject, active: 0, queued: 0)
        XCTAssertEqual(clock.callCount, 2)
        XCTAssertEqual(clock.completedCount, 2)
        print("R03 timeout siblings: \(await ledger.events)")
    }

    func testCancelledWaiterDoesNotOrphanSiblingBeforeOrDuringGrant() async {
        for duringGrant in [false, true] {
            let clock = ManualAdmissionClock()
            let subject = timedSubject(clock, timeout: nil)
            let ledger = BulkheadHandlerLedger()
            let holder = launchBulkhead(subject, id: "A", ledger: ledger)
            let aEntered = await entered("A", ledger: ledger)
            XCTAssertTrue(aEntered)
            let cancelled = launchBulkhead(subject, id: "B", ledger: ledger)
            let bQueued = await queued(1, subject: subject, id: "B", ledger: ledger)
            XCTAssertTrue(bQueued)
            let sibling = launchBulkhead(subject, id: "C", ledger: ledger)
            let cQueued = await queued(2, subject: subject, id: "C", ledger: ledger)
            XCTAssertTrue(cQueued)
            let didCancelDuringGrant = Mutex(false)
            if duringGrant {
                // With nil timeout there are no timer reads. The next read is
                // B's queue-duration measurement after its active ID is inserted.
                clock.onNextRead {
                    didCancelDuringGrant.withLock { $0 = true }
                    cancelled.cancel()
                }
                await ledger.release("A")
            } else {
                cancelled.cancel()
            }
            await ledger.record("cancel:B")
            let bResult = await cancelled.value
            XCTAssertEqual(bResult, "cancelled")
            XCTAssertEqual(didCancelDuringGrant.withLock { $0 }, duringGrant)
            if !duringGrant {
                await assertState(subject, active: 1, queued: 1)
                let aFinished = await ledger.finished("A")
                XCTAssertFalse(aFinished)
                await ledger.release("A")
            }
            let cEntered = await entered("C", ledger: ledger)
            XCTAssertTrue(cEntered)
            await assertState(subject, active: 1, queued: 0)
            let entries = await ledger.entries
            XCTAssertEqual(entries, ["A", "C"])
            // Cancellation after handler entry does not free its live lease.
            sibling.cancel()
            await ledger.record("cancel:C-after-entry")
            await assertState(subject, active: 1, queued: 0)
            await ledger.release("C")
            let aResult = await holder.value
            let cResult = await sibling.value
            XCTAssertEqual(aResult, "success")
            XCTAssertEqual(cResult, "success")
            await assertState(subject, active: 0, queued: 0)
            XCTAssertEqual(clock.callCount, 0)
            print("R03 cancellation duringGrant=\(duringGrant): \(await ledger.events)")
        }
    }

    @available(*, deprecated, message: "Exercises the supported reservation alias")
    func testDonorReserveAndQueuePriorityAreAtomic() async {
        for allowBorrowing in [false, true] {
            for alias in [false, true] {
                let partitions: [String: PartitionedBulkheadMiddleware.PartitionConfig] = [
                    "local": .init(capacity: 1), "donor": .init(capacity: 2, queueSize: 1)
                ]
                let extractor: @Sendable (any Command, CommandContext) async -> String = { command, _ in
                    (command as? AdmissionCommand)?.id.hasPrefix("donor") == true ? "donor" : "local"
                }
                let config = alias ? PartitionedBulkheadMiddleware.Configuration(
                    partitions: partitions, partitionExtractor: extractor, defaultPartition: "local",
                    allowBorrowing: allowBorrowing, maxBorrowPercentage: 0.5
                ) : PartitionedBulkheadMiddleware.Configuration(
                    partitions: partitions, partitionExtractor: extractor, defaultPartition: "local",
                    allowBorrowing: allowBorrowing, reservedCapacityPercentage: 0.5
                )
                let middleware = PartitionedBulkheadMiddleware(configuration: config)
                let local = BulkheadAdmissionSubject.partitioned(middleware, partition: "local")
                let donor = BulkheadAdmissionSubject.partitioned(middleware, partition: "donor")
                let ledger = BulkheadHandlerLedger()
                let holder = launchBulkhead(local, id: "local-A", ledger: ledger)
                let aEntered = await entered("local-A", ledger: ledger)
                XCTAssertTrue(aEntered)
                let contexts = [CommandContext(), CommandContext()]
                // Both independent tasks compete for the donor's last lendable
                // slot. The observed outcomes are recorded; no old interleaving
                // is claimed to have been forced.
                let borrowers = (0..<2).map { index in
                    launchBulkhead(local, id: "borrow-\(index)", ledger: ledger,
                                   fails: index == 1, context: contexts[index])
                }
                for index in 0..<2 {
                    while !(await ledger.entered("borrow-\(index)")) {
                        if await ledger.finished("borrow-\(index)") { break }
                        await Task.yield()
                    }
                }
                let entries = await ledger.entries
                let winners = (0..<2).filter { entries.contains("borrow-\($0)") }
                XCTAssertEqual(winners.count, allowBorrowing ? 1 : 0)
                await assertState(donor, active: allowBorrowing ? 1 : 0, queued: 0)
                await assertState(local, active: 1, queued: 0)
                for index in 0..<2 { await ledger.release("borrow-\(index)") }
                for index in 0..<2 {
                    let result = await borrowers[index].value
                    XCTAssertEqual(result, winners.contains(index) ? (index == 1 ? "handlerError" : "success") : "rejected")
                    if winners.contains(index) {
                        XCTAssertEqual(contexts[index].getMetadata()["bulkhead.wasBorrowed"] as? Bool, true)
                        XCTAssertEqual(contexts[index].getMetadata()["bulkhead.wasQueued"] as? Bool, false)
                    }
                }
                await assertState(donor, active: 0, queued: 0)

                var donorHolders: [Task<String, Never>] = []
                for index in 0..<2 {
                    let id = "donor-A\(index)"
                    donorHolders.append(launchBulkhead(donor, id: id, ledger: ledger))
                    let didEnter = await entered(id, ledger: ledger)
                    XCTAssertTrue(didEnter)
                }
                let queuedDonor = launchBulkhead(donor, id: "donor-queued", ledger: ledger)
                let didQueue = await queued(1, subject: donor, id: "donor-queued", ledger: ledger)
                XCTAssertTrue(didQueue)
                let blockedBorrower = launchBulkhead(local, id: "borrow-blocked", ledger: ledger)
                let blockedResult = await blockedBorrower.value
                XCTAssertEqual(blockedResult, "rejected")
                async let releaseOwner: Void = ledger.release("donor-A0")
                let racingBorrower = launchBulkhead(local, id: "borrow-at-handoff", ledger: ledger)
                await releaseOwner
                let racingResult = await racingBorrower.value
                XCTAssertEqual(racingResult, "rejected")
                let ownedEntered = await entered("donor-queued", ledger: ledger)
                XCTAssertTrue(ownedEntered)
                await assertState(donor, active: 2, queued: 0)
                await ledger.release("donor-queued")
                await ledger.release("donor-A1")
                for task in donorHolders {
                    let result = await task.value
                    XCTAssertEqual(result, "success")
                }
                let queuedResult = await queuedDonor.value
                XCTAssertEqual(queuedResult, "success")
                await ledger.release("local-A")
                let holderResult = await holder.value
                XCTAssertEqual(holderResult, "success")
                await assertState(donor, active: 0, queued: 0)
                await assertState(local, active: 0, queued: 0)
                print("R03 donor borrowing=\(allowBorrowing) alias=\(alias): \(await ledger.events)")
            }
        }
    }
}
