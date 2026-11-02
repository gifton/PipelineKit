import Foundation

package enum AdmissionError: Error, Sendable {
    case full
    case timedOut
}

package struct AdmissionSnapshot: Sendable {
    package let active: Int
    package let queued: Int
}

/// An occupied admission slot. Callers must await release after their work settles.
package struct AdmissionLease: Sendable {
    private let id: UUID
    private let owner: AdmissionGate
    package let wasQueued: Bool
    package let queueDuration: Duration

    fileprivate init(id: UUID, owner: AdmissionGate, wasQueued: Bool, queueDuration: Duration) {
        self.id = id
        self.owner = owner
        self.wasQueued = wasQueued
        self.queueDuration = queueDuration
    }

    /// Duplicate releases are ignored by the owner (`testLeaseConservationMatrix`).
    package func release() async {
        await owner.release(id: id)
    }
}

/// Owns active leases and a FIFO of pending acquisitions.
///
/// `testLeaseConservationMatrix` covers capacity bounds, FIFO handoff and queue
/// reuse. Waiters use linked dictionary entries: insertion, removal and handoff
/// each require a constant number of dictionary operations, with O(n) storage.
package actor AdmissionGate {
    private struct Waiter {
        let continuation: CheckedContinuation<AdmissionLease, any Error>
        let queuedAt: Duration
        var previous: UUID?
        var next: UUID?
        var timer: Task<Void, Never>?
    }

    private let capacity: Int
    private let maxQueueSize: Int
    private let now: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var active: Set<UUID> = []
    private var waiters: [UUID: Waiter] = [:]
    private var firstWaiter: UUID?
    private var lastWaiter: UUID?

    /// Requires positive capacity and a nonnegative queue limit.
    package init(capacity: Int, maxQueueSize: Int) {
        let clock = ContinuousClock()
        let origin = clock.now
        self.init(
            capacity: capacity,
            maxQueueSize: maxQueueSize,
            now: { origin.duration(to: clock.now) },
            sleep: { try await clock.sleep(for: $0) }
        )
    }

    /// Clock seam for package tests. `now` must be monotonic; `sleep` waits for
    /// its positive duration or throws on cancellation.
    package init(
        capacity: Int,
        maxQueueSize: Int,
        now: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        precondition(capacity > 0, "Admission capacity must be positive")
        precondition(maxQueueSize >= 0, "Admission queue size must be nonnegative")
        self.capacity = capacity
        self.maxQueueSize = maxQueueSize
        self.now = now
        self.sleep = sleep
    }

    /// Acquires while preserving `reserving` free slots, without joining a queue.
    /// Requires `reserving` in `0...capacity`; subtraction follows validation.
    package func tryAcquire(reserving: Int = 0) -> AdmissionLease? {
        precondition((0...capacity).contains(reserving), "Admission reserve must be in 0...capacity")
        guard waiters.isEmpty, active.count < capacity - reserving else { return nil }
        return grant(id: UUID(), queuedAt: nil)
    }

    /// Waits only for admission. A nonpositive timeout still permits an immediate
    /// grant; otherwise it throws `timedOut` without installing a waiter.
    /// Cancellation already observed at registration takes precedence.
    package func acquire(timeout: Duration? = nil) async throws -> AdmissionLease {
        // The cancellation handler and registration closure share an immutable ID.
        let id = UUID()
        let lease: AdmissionLease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AdmissionLease, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if waiters.isEmpty, active.count < capacity {
                    continuation.resume(returning: grant(id: id, queuedAt: nil))
                } else if let timeout, timeout <= .zero {
                    continuation.resume(throwing: AdmissionError.timedOut)
                } else if waiters.count >= maxQueueSize {
                    continuation.resume(throwing: AdmissionError.full)
                } else {
                    install(id: id, continuation: continuation, timeout: timeout)
                }
            }
        } onCancel: {
            Task { await self.failWaiter(id: id, error: CancellationError()) }
        }

        // A release may win the actor turn before the cancellation handler. The
        // recipient returns that slot before throwing; covered by the synchronous
        // cancel-during-grant schedule in testCancellationRegistrationAndGrantRaces.
        if Task.isCancelled {
            release(id: id)
            throw CancellationError()
        }
        return lease
    }

    package func snapshot() -> AdmissionSnapshot {
        AdmissionSnapshot(active: active.count, queued: waiters.count)
    }

    fileprivate func release(id: UUID) {
        guard active.remove(id) != nil else { return }
        guard let nextID = firstWaiter, let waiter = removeWaiter(id: nextID) else { return }
        // Removal, slot transfer and resumption share one actor turn.
        let lease = grant(id: nextID, queuedAt: waiter.queuedAt)
        waiter.continuation.resume(returning: lease)
    }

    private func grant(id: UUID, queuedAt: Duration?) -> AdmissionLease {
        active.insert(id)
        let queueDuration = queuedAt.map { max(.zero, now() - $0) } ?? .zero
        return AdmissionLease(id: id, owner: self, wasQueued: queuedAt != nil, queueDuration: queueDuration)
    }

    private func install(
        id: UUID,
        continuation: CheckedContinuation<AdmissionLease, any Error>,
        timeout: Duration?
    ) {
        let queuedAt = now()
        waiters[id] = Waiter(continuation: continuation, queuedAt: queuedAt, previous: lastWaiter)
        if let lastWaiter {
            waiters[lastWaiter]?.next = id
        } else {
            firstWaiter = id
        }
        lastWaiter = id

        if let timeout {
            waiters[id]?.timer = Task { [weak self, now, sleep] in
                do {
                    // Timer startup can be delayed after registration. Only sleep
                    // for the remaining interval; do not add Duration deadlines.
                    let elapsed = max(.zero, now() - queuedAt)
                    if elapsed < timeout {
                        try await sleep(timeout - elapsed)
                    }
                    try Task.checkCancellation()
                    await self?.failWaiter(id: id, error: AdmissionError.timedOut)
                } catch {
                    await self?.failWaiter(id: id, error: error)
                }
            }
        }
    }

    /// All waiter outcomes remove ownership here before resuming a continuation.
    private func removeWaiter(id: UUID) -> Waiter? {
        guard let waiter = waiters.removeValue(forKey: id) else { return nil }
        if let previous = waiter.previous {
            waiters[previous]?.next = waiter.next
        } else {
            firstWaiter = waiter.next
        }
        if let next = waiter.next {
            waiters[next]?.previous = waiter.previous
        } else {
            lastWaiter = waiter.previous
        }
        waiter.timer?.cancel()
        return waiter
    }

    private func failWaiter(id: UUID, error: any Error) {
        guard let waiter = removeWaiter(id: id) else { return }
        waiter.continuation.resume(throwing: error)
    }
}
