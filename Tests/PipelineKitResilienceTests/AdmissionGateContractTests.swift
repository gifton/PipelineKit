import XCTest
import Synchronization
import _ResilienceFoundation

private enum AdmissionResult: Sendable {
    case granted(AdmissionLease)
    case cancelled
    case full
    case timedOut
    case unexpected(String)

    var name: String {
        switch self {
        case .granted: "granted"
        case .cancelled: "cancelled"
        case .full: "full"
        case .timedOut: "timedOut"
        case .unexpected(let message): "unexpected: \(message)"
        }
    }

    var lease: AdmissionLease? {
        if case .granted(let lease) = self { return lease }
        return nil
    }
}

private actor AdmissionTerminals {
    private var results: [String: [String]] = [:]

    func record(_ id: String, _ result: AdmissionResult) {
        results[id, default: []].append(result.name)
    }

    func snapshot() -> [String: [String]] { results }
}

private actor AdmissionStart {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private func acquireAdmission(_ gate: AdmissionGate, timeout: Duration? = nil) async -> AdmissionResult {
    do {
        return .granted(try await gate.acquire(timeout: timeout))
    } catch is CancellationError {
        return .cancelled
    } catch AdmissionError.full {
        return .full
    } catch AdmissionError.timedOut {
        return .timedOut
    } catch {
        return .unexpected(String(describing: error))
    }
}


final class AdmissionGateContractTests: XCTestCase {
    private func makeGate(capacity: Int, queue: Int, clock: ManualAdmissionClock) -> AdmissionGate {
        AdmissionGate(
            capacity: capacity,
            maxQueueSize: queue,
            now: { clock.now() },
            sleep: { try await clock.sleep(for: $0) }
        )
    }

    private func enqueue(
        _ id: String,
        gate: AdmissionGate,
        terminals: AdmissionTerminals,
        timeout: Duration? = nil
    ) -> Task<AdmissionResult, Never> {
        Task { @concurrent in
            let result = await acquireAdmission(gate, timeout: timeout)
            await terminals.record(id, result)
            return result
        }
    }

    private func assertState(
        _ gate: AdmissionGate,
        capacity: Int,
        active: Int,
        queued: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let snapshot = await gate.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.active, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(snapshot.active, capacity, file: file, line: line)
        XCTAssertEqual(snapshot.active, active, file: file, line: line)
        XCTAssertEqual(snapshot.queued, queued, file: file, line: line)
    }

    private func registered(_ count: Int, on gate: AdmissionGate) async {
        while await gate.snapshot().queued < count { await Task.yield() }
    }

    // Catches count-only permits, queue occupancy that never decreases, duplicate
    // releases and handoffs that expose a slot before reserving it for the waiter.
    func testLeaseConservationMatrix() async throws {
        for capacity in [1, 2] {
            for queueSize in [0, 1, 3] {
                let clock = ManualAdmissionClock()
                let gate = makeGate(capacity: capacity, queue: queueSize, clock: clock)
                let terminals = AdmissionTerminals()
                var granted = 0
                var released = 0
                for wave in 0..<4 {
                    var active: [AdmissionLease] = []
                    for _ in 0..<capacity {
                        let result = await acquireAdmission(gate)
                        let lease = try XCTUnwrap(result.lease, result.name)
                        active.append(lease)
                        granted += 1
                        XCTAssertFalse(lease.wasQueued)
                        XCTAssertEqual(lease.queueDuration, .zero)
                    }
                    var pending: [Task<AdmissionResult, Never>] = []
                    for index in 0..<queueSize {
                        pending.append(enqueue("\(wave)-\(index)", gate: gate, terminals: terminals))
                        await registered(index + 1, on: gate)
                        await assertState(gate, capacity: capacity, active: capacity, queued: index + 1)
                    }
                    let full = await acquireAdmission(gate)
                    XCTAssertEqual(full.name, "full")
                    await assertState(gate, capacity: capacity, active: capacity, queued: queueSize)
                    clock.advance(by: .seconds(2))

                    for (index, task) in pending.enumerated() {
                        let retiring = active.removeFirst()
                        await retiring.release()
                        await retiring.release()
                        released += 1
                        await assertState(gate, capacity: capacity, active: capacity, queued: queueSize - index - 1)
                        let newcomer = await gate.tryAcquire()
                        XCTAssertNil(newcomer)
                        await newcomer?.release()
                        let result = await task.value
                        XCTAssertEqual(result.name, "granted")
                        if let lease = result.lease {
                            granted += 1
                            active.append(lease)
                            XCTAssertTrue(lease.wasQueued)
                            XCTAssertEqual(lease.queueDuration, .seconds(2))
                        }
                    }
                    for lease in active {
                        await lease.release()
                        await lease.release()
                        released += 1
                    }
                    await assertState(gate, capacity: capacity, active: 0, queued: 0)
                    XCTAssertEqual(granted, released)
                }
                let results = await terminals.snapshot()
                XCTAssertEqual(results.count, 4 * queueSize)
                XCTAssertTrue(results.values.allSatisfy { $0 == ["granted"] })
                XCTAssertEqual(clock.callCount, 0)
            }
        }
    }

    func testCancellationRegistrationAndGrantRaces() async throws {
        // Acknowledged entry before acquire: cancellation must win even with room.
        let start = AdmissionStart()
        let preGate = AdmissionGate(capacity: 1, maxQueueSize: 1)
        let beforeRegistration = Task { @concurrent in
            await start.wait()
            return await acquireAdmission(preGate, timeout: .zero)
        }
        while !(await start.entered) { await Task.yield() }
        beforeRegistration.cancel()
        await start.open()
        let preResult = await beforeRegistration.value
        XCTAssertEqual(preResult.name, "cancelled")
        await preResult.lease?.release()
        await assertState(preGate, capacity: 1, active: 0, queued: 0)

        for cancelDuringGrant in [false, true] {
            let clock = ManualAdmissionClock()
            let gate = makeGate(capacity: 1, queue: 2, clock: clock)
            let initialResult = await acquireAdmission(gate)
            let initial = try XCTUnwrap(initialResult.lease)
            let terminals = AdmissionTerminals()
            let cancelled = enqueue("cancelled", gate: gate, terminals: terminals, timeout: .seconds(30))
            await registered(1, on: gate)
            let sibling = enqueue("sibling", gate: gate, terminals: terminals, timeout: .seconds(30))
            await registered(2, on: gate)
            await clock.waitForSleepers(2)

            let grantCancellation = Mutex(false)
            if cancelDuringGrant {
                // Registration and timer startup are complete. The next now read
                // is the release handoff's queue-duration measurement. Cancelling
                // here forces a granted recipient to relinquish its lease.
                clock.onNextRead {
                    grantCancellation.withLock { $0 = true }
                    cancelled.cancel()
                }
                await initial.release()
            } else {
                cancelled.cancel()
            }
            let cancelledResult = await cancelled.value
            XCTAssertEqual(cancelledResult.name, "cancelled")
            await cancelledResult.lease?.release()
            if cancelDuringGrant {
                XCTAssertTrue(grantCancellation.withLock { $0 })
                await assertState(gate, capacity: 1, active: 1, queued: 0)
            } else {
                await assertState(gate, capacity: 1, active: 1, queued: 1)
                await clock.waitForSleepers(1)
                await initial.release()
            }
            let siblingResult = await sibling.value
            XCTAssertEqual(siblingResult.name, "granted")
            XCTAssertEqual(siblingResult.lease?.wasQueued, true)
            await siblingResult.lease?.release()
            await siblingResult.lease?.release()
            await initial.release()
            await clock.waitForSettlement()
            await assertState(gate, capacity: 1, active: 0, queued: 0)
            let results = await terminals.snapshot()
            XCTAssertEqual(results, ["cancelled": ["cancelled"], "sibling": ["granted"]])
            XCTAssertEqual(clock.callCount, 2)
            XCTAssertEqual(clock.completedCount, 2)
            XCTAssertEqual(clock.sleepingCount, 0)
        }
    }

    func testTimeoutRemovesOnlyItsWaiter() async throws {
        let clock = ManualAdmissionClock()
        let gate = makeGate(capacity: 1, queue: 3, clock: clock)
        let initialResult = await acquireAdmission(gate)
        let initial = try XCTUnwrap(initialResult.lease)
        let terminals = AdmissionTerminals()
        let first = enqueue("first", gate: gate, terminals: terminals, timeout: .seconds(30))
        await registered(1, on: gate)
        let expiring = enqueue("expiring", gate: gate, terminals: terminals, timeout: .seconds(5))
        await registered(2, on: gate)
        let last = enqueue("last", gate: gate, terminals: terminals, timeout: .seconds(40))
        await registered(3, on: gate)
        await clock.waitForSleepers(3)
        let full = await acquireAdmission(gate, timeout: .seconds(100))
        XCTAssertEqual(full.name, "full")

        clock.advance(by: .seconds(4))
        await assertState(gate, capacity: 1, active: 1, queued: 3)
        let beforeDeadline = await terminals.snapshot()
        XCTAssertTrue(beforeDeadline.isEmpty)
        clock.advance(by: .seconds(1))
        let expiredResult = await expiring.value
        XCTAssertEqual(expiredResult.name, "timedOut")
        await expiredResult.lease?.release()
        await assertState(gate, capacity: 1, active: 1, queued: 2)
        await clock.waitForSleepers(2)

        let replacement = enqueue("replacement", gate: gate, terminals: terminals, timeout: .seconds(10))
        await registered(3, on: gate)
        await clock.waitForSleepers(3)
        let fullAgain = await acquireAdmission(gate)
        XCTAssertEqual(fullAgain.name, "full")
        await initial.release()
        let firstResult = await first.value
        XCTAssertEqual(firstResult.name, "granted")
        XCTAssertEqual(firstResult.lease?.queueDuration, .seconds(5))
        await assertState(gate, capacity: 1, active: 1, queued: 2)
        clock.advance(by: .seconds(2))
        await firstResult.lease?.release()
        let lastResult = await last.value
        XCTAssertEqual(lastResult.name, "granted")
        XCTAssertEqual(lastResult.lease?.queueDuration, .seconds(7))
        await lastResult.lease?.release()
        let replacementResult = await replacement.value
        XCTAssertEqual(replacementResult.name, "granted")
        XCTAssertEqual(replacementResult.lease?.queueDuration, .seconds(2))
        await replacementResult.lease?.release()
        await clock.waitForSettlement()
        await assertState(gate, capacity: 1, active: 0, queued: 0)
        let results = await terminals.snapshot()
        XCTAssertEqual(results, ["first": ["granted"], "expiring": ["timedOut"],
                                 "last": ["granted"], "replacement": ["granted"]])
        XCTAssertEqual(clock.callCount, 4)
        XCTAssertEqual(clock.completedCount, 4)
        XCTAssertEqual(clock.sleepingCount, 0)
    }

    func testReservedAcquisitionIsAtomic() async {
        for capacity in [1, 2, 5] {
            for reserve in 0...capacity {
                let gate = AdmissionGate(capacity: capacity, maxQueueSize: 1)
                let leases = await withTaskGroup(of: AdmissionLease?.self, returning: [AdmissionLease].self) { group in
                    for _ in 0..<20 {
                        group.addTask { await gate.tryAcquire(reserving: reserve) }
                    }
                    var leases: [AdmissionLease] = []
                    for await lease in group {
                        if let lease { leases.append(lease) }
                    }
                    return leases
                }
                XCTAssertEqual(leases.count, capacity - reserve)
                await assertState(gate, capacity: capacity, active: capacity - reserve, queued: 0)
                var reservedLeases: [AdmissionLease] = []
                for _ in 0..<reserve {
                    if let lease = await gate.tryAcquire() { reservedLeases.append(lease) }
                }
                XCTAssertEqual(reservedLeases.count, reserve)
                let full = await gate.tryAcquire(reserving: reserve)
                XCTAssertNil(full)
                await full?.release()
                await assertState(gate, capacity: capacity, active: capacity, queued: 0)
                for lease in leases + reservedLeases {
                    XCTAssertFalse(lease.wasQueued)
                    XCTAssertEqual(lease.queueDuration, .zero)
                    await lease.release()
                    await lease.release()
                }
                await assertState(gate, capacity: capacity, active: 0, queued: 0)
            }
        }

        let large = AdmissionGate(capacity: Int.max, maxQueueSize: Int.max)
        let entirelyReserved = await large.tryAcquire(reserving: Int.max)
        XCTAssertNil(entirelyReserved)
        await entirelyReserved?.release()
        let singleAvailable = await large.tryAcquire(reserving: Int.max - 1)
        XCTAssertNotNil(singleAvailable)
        let unavailable = await large.tryAcquire(reserving: Int.max - 1)
        XCTAssertNil(unavailable)
        await unavailable?.release()
        await assertState(large, capacity: Int.max, active: 1, queued: 0)
        await singleAvailable?.release()
        await assertState(large, capacity: Int.max, active: 0, queued: 0)
    }

    func testNonpositiveTimeoutOnlyRejectsWaitingAndProductionTimerSettles() async throws {
        for timeout: Duration in [.zero, .seconds(-1)] {
            for queueSize in [0, 1] {
                let clock = ManualAdmissionClock()
                let gate = makeGate(capacity: 1, queue: queueSize, clock: clock)
                let immediate = await acquireAdmission(gate, timeout: timeout)
                let lease = try XCTUnwrap(immediate.lease, immediate.name)
                let waiting = await acquireAdmission(gate, timeout: timeout)
                XCTAssertEqual(waiting.name, "timedOut")
                await assertState(gate, capacity: 1, active: 1, queued: 0)
                await lease.release()
                await assertState(gate, capacity: 1, active: 0, queued: 0)
                XCTAssertEqual(clock.callCount, 0)
            }
        }

        let production = AdmissionGate(capacity: 1, maxQueueSize: 1)
        let immediate = await acquireAdmission(production)
        let lease = try XCTUnwrap(immediate.lease)
        // Real sleeper smoke: timeout completes while the active lease is held.
        // The deadline itself is the behavior under test, not an ordering sleep.
        let expired = await acquireAdmission(production, timeout: .milliseconds(1))
        XCTAssertEqual(expired.name, "timedOut")
        await assertState(production, capacity: 1, active: 1, queued: 0)
        await lease.release()
        await assertState(production, capacity: 1, active: 0, queued: 0)
    }
}
