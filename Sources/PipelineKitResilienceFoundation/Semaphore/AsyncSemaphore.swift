import Foundation
import PipelineKit  // For PipelineError

/// An async-safe counting semaphore for controlling concurrent access to resources.
///
/// `AsyncSemaphore` provides a way to limit the number of concurrent operations
/// in an async/await context. It maintains a count of available resources and
/// queues waiters when resources are exhausted.
///
/// ## Example
/// ```swift
/// let semaphore = AsyncSemaphore(value: 3) // Allow 3 concurrent operations
///
/// // In multiple concurrent tasks:
/// await semaphore.wait()
/// defer { await semaphore.signal() }
/// // Perform work...
/// ```
///
/// ## Implementation Note
/// This implementation uses an actor to ensure thread-safe access to the internal state
/// while avoiding deadlocks through careful continuation management and atomic state transitions.
public actor AsyncSemaphore {
    /// The current number of available resources
    private var availableResources: Int

    /// Queue of waiting tasks (FIFO ordering).
    ///
    /// Backed by a `PriorityHeap` keyed on a monotonically increasing sequence
    /// number so that FIFO order is preserved while providing O(log n) insertion,
    /// extraction, and arbitrary removal by id. The min-heap comparator
    /// (`seq < seq`) makes `extractMin()` return the oldest (lowest sequence)
    /// waiter first.
    private var waiters: PriorityHeap<Waiter>

    /// Monotonic sequence counter assigned to each waiter to impose FIFO order.
    ///
    /// Allocated and incremented only while running on the actor (inside the
    /// continuation body), so no synchronization beyond actor isolation is needed.
    private var nextSeq: UInt64 = 0
    
    /// State of a waiter
    private enum WaiterState {
        case waiting
        case resumed
    }
    
    /// Type of continuation
    private enum ContinuationType {
        case regular(CheckedContinuation<Void, any Error>)
        case timeout(CheckedContinuation<Bool, Never>)
    }
    
    /// Result of wait operation
    private enum WaitResult {
        case signaled
        case timedOut
        case cancelled
    }
    
    /// Represents a waiting task
    ///
    /// Kept as a reference type so `tryResume` can mutate `state` in place while
    /// the instance is held by value-typed storage (the `PriorityHeap`).
    private class Waiter {
        let id = UUID()
        /// Monotonic FIFO ordering key. Lower values are served first.
        let seq: UInt64
        var state = WaiterState.waiting
        let continuation: ContinuationType
        var timeoutTask: Task<Void, Never>?

        init(seq: UInt64, continuation: ContinuationType) {
            self.seq = seq
            self.continuation = continuation
        }
        
        /// Attempts to resume the continuation with the given result
        /// Returns true if the continuation was resumed, false if already resumed
        func tryResume(with result: WaitResult) -> Bool {
            guard state == .waiting else { return false }
            state = .resumed
            
            switch (continuation, result) {
            case (.regular(let cont), .signaled):
                cont.resume(returning: ())
                return true
            case (.regular(let cont), .cancelled):
                cont.resume(throwing: PipelineError.cancelled(context: "Semaphore wait cancelled"))
                return true
            case (.timeout(let cont), .signaled):
                cont.resume(returning: true)
                return true
            case (.timeout(let cont), .timedOut):
                cont.resume(returning: false)
                return true
            case (.regular, .timedOut):
                // Regular wait doesn't timeout
                return false
            case (.timeout(let cont), .cancelled):
                // Timeout wait returns false on cancellation
                cont.resume(returning: false)
                return true
            }
        }
        
        /// Cancels the timeout task if it exists
        func cancelTimeout() {
            timeoutTask?.cancel()
            timeoutTask = nil
        }
    }
    
    /// Creates a new semaphore with the specified initial value.
    ///
    /// - Parameter value: The initial number of available resources.
    public init(value: Int) {
        self.availableResources = value
        // FIFO ordering: the waiter with the smallest sequence number is served
        // first. The comparator returns `true` when `a` should be extracted
        // before `b`, which the min-heap uses to keep the oldest waiter at the root.
        self.waiters = PriorityHeap<Waiter>(
            comparator: { $0.seq < $1.seq },
            idExtractor: { $0.id }
        )
    }
    
    /// Waits for a resource to become available.
    ///
    /// If resources are available (value > 0), this method decrements the count
    /// and returns immediately. Otherwise, it suspends until a resource is released.
    ///
    /// - Throws: `PipelineError.cancelled` if the task is cancelled while
    ///   waiting. This holds in every interleaving: if a concurrent `signal()`
    ///   resumes a waiter whose task was already cancelled, the consumed signal
    ///   is forwarded to the next waiter (or restored to the count) and the
    ///   cancelled `wait()` still throws.
    public func wait() async throws {
        // Check for cancellation before proceeding
        try Task.checkCancellation()
        
        // Fast path: resource available
        if availableResources > 0 {
            availableResources -= 1
            return
        }
        
        // Slow path: need to wait
        // Use a final class to capture the waiter ID for the cancellation handler
        final class WaiterIdBox: @unchecked Sendable {
            var id: UUID?
        }
        let waiterIdBox = WaiterIdBox()
        
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let waiter = Waiter(seq: nextSeq, continuation: .regular(continuation))
                nextSeq &+= 1
                waiterIdBox.id = waiter.id
                waiters.insert(waiter)

                // Cancellation race fix (TOCTOU): `Task.checkCancellation()` above
                // closes the common case, but the task may be cancelled between that
                // check and this body running. In that window `onCancel` may have
                // already fired while `waiterIdBox.id` was still nil (so it did
                // nothing), which would otherwise leave this continuation orphaned
                // and never resumed. Claim and resume it here.
                //
                // Remove from the heap first to uphold the invariant "a waiter is in
                // the heap iff it is unresumed" at every resume site. This runs
                // synchronously on the actor, so a concurrent `signal()` cannot
                // interleave. Idempotent: a late `onCancel` finds the waiter already
                // gone (`remove` returns nil) and becomes a no-op.
                if Task.isCancelled, waiters.remove(id: waiter.id) != nil {
                    waiter.cancelTimeout()
                    _ = waiter.tryResume(with: .cancelled)
                }
            }
        } onCancel: { [weak self, waiterIdBox] in
            guard let waiterId = waiterIdBox.id else { return }
            Task { @Sendable [weak self] in
                await self?.handleCancellationForWaiter(waiterId: waiterId)
            }
        }

        // Cancellation race fix (mirror of SimpleSemaphore PR #73 /
        // BackPressureSemaphore PR #74): `onCancel` above only *spawns* a task
        // to run `handleCancellationForWaiter`, so a concurrent `signal()` can
        // reach the actor first, extract this (already-cancelled) waiter from
        // the heap, and resume it with `.signaled`; the later cancellation
        // task finds the heap without it and no-ops. Without this re-check, a
        // cancelled `wait()` would return normally — and since callers pair
        // every *successful* wait() with a later signal() (and rightly skip
        // the signal when wait() throws), the wakeup this waiter consumed
        // would be swallowed: one resource permanently vanishes.
        //
        // The re-check runs in the waiter's own task, where the cancellation
        // flag is unambiguous: if `signal()` won the race, the cancel flag was
        // set before `onCancel` fired, so it is visible here. Forward the
        // consumed signal — `signal()` is a synchronous same-actor call that
        // wakes the next waiter or restores the count, so conservation is
        // re-established before this method returns — and honor the contract
        // by throwing the same error as every other cancellation path. All
        // interleavings:
        //   - Cancellation task wins: the continuation threw above; this code
        //     is never reached, and the (awaited) signal restores a resource.
        //   - signal() wins: resumed .signaled, re-signaled + thrown here; the
        //     pending cancellation task no-ops (waiter no longer in the heap).
        //   - Cancelled after resume, before this check: same as signal()
        //     winning — the resource is forwarded, not double-consumed, and
        //     the caller sees the throw and does not signal.
        //   - No cancellation: the flag is false; return normally.
        // We cannot resume ourselves: this waiter was already extracted, so
        // the forwarded signal reaches only other waiters or the counter.
        if Task.isCancelled {
            signal()
            throw PipelineError.cancelled(context: "Semaphore wait cancelled")
        }
    }

    /// Waits for a resource to become available with a timeout.
    ///
    /// If resources are available (value > 0), this method decrements the count
    /// and returns immediately. Otherwise, it suspends until a resource is released
    /// or the timeout expires.
    ///
    /// - Parameter timeout: The maximum time to wait, in seconds
    /// - Returns: True if a resource was acquired, false if timeout occurred or task was cancelled
    public func acquire(timeout: TimeInterval) async -> Bool {
        // Check for cancellation before proceeding
        if Task.isCancelled {
            return false
        }
        
        // Fast path: resource available
        if availableResources > 0 {
            availableResources -= 1
            return true
        }
        
        // Slow path: need to wait with timeout
        // Use a final class to capture the waiter ID for the cancellation handler
        final class WaiterIdBox: @unchecked Sendable {
            var id: UUID?
        }
        let waiterIdBox = WaiterIdBox()
        
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let waiter = Waiter(seq: nextSeq, continuation: .timeout(continuation))
                nextSeq &+= 1
                waiterIdBox.id = waiter.id

                // Create timeout task
                let timeoutTask = Task { [weak self, waiterId = waiter.id] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))

                    // If we reach here, timeout occurred
                    await self?.handleTimeout(waiterId: waiterId)
                }

                waiter.timeoutTask = timeoutTask
                waiters.insert(waiter)

                // Cancellation race fix (TOCTOU): mirrors `wait()`. If the task was
                // cancelled between the `Task.isCancelled` check above and this body
                // running, `onCancel` may have already fired with a nil id and done
                // nothing; claim and resume here so the continuation is not orphaned.
                // Remove from the heap first (invariant: in-heap iff unresumed). A
                // timeout waiter resumed with `.cancelled` returns `false`. We also
                // cancel the timeout task we just created. Idempotent: a late
                // `onCancel` finds the waiter already gone and becomes a no-op.
                if Task.isCancelled, waiters.remove(id: waiter.id) != nil {
                    waiter.cancelTimeout()
                    _ = waiter.tryResume(with: .cancelled)
                }
            }
        } onCancel: { [weak self, waiterIdBox] in
            // Handle task cancellation for specific waiter
            guard let waiterId = waiterIdBox.id else { return }
            Task { @Sendable [weak self] in
                await self?.handleCancellationForWaiter(waiterId: waiterId)
            }
        }

        // Cancellation race fix: mirrors `wait()` above. If a concurrent
        // `signal()` beat the spawned cancellation task, this cancelled waiter
        // was resumed with `.signaled` and `acquired` is true — but the
        // documented contract is "false if the task was cancelled", and a
        // caller seeing false will never signal back. Forward the consumed
        // signal (synchronous same-actor call) and report false. The timeout
        // task was already cancelled by `signal()` via `cancelTimeout()`.
        if acquired && Task.isCancelled {
            signal()
            return false
        }
        return acquired
    }
    
    /// Signals that a resource has been released.
    ///
    /// If there are waiting tasks, this method resumes the first waiter.
    /// Otherwise, it increments the available resource count.
    public func signal() {
        // Resume the oldest waiter (FIFO). `extractMin()` both removes the waiter
        // from the heap and returns it; under the `seq < seq` comparator this is
        // the lowest-sequence (earliest-enqueued) waiter. If there are no waiters,
        // restore an available resource instead.
        guard let waiter = waiters.extractMin() else {
            availableResources += 1
            return
        }

        // Cancel timeout if exists
        waiter.cancelTimeout()

        // Try to resume with signaled result. The "in heap iff unresumed"
        // invariant guarantees an extracted waiter is still unresumed, so this
        // resume always succeeds; `tryResume` returning false would be harmless.
        _ = waiter.tryResume(with: .signaled)
    }
    
    /// Handles timeout expiration
    private func handleTimeout(waiterId: UUID) {
        // Remove the waiter from the heap first; `remove(id:)` returns the element
        // only if it was still present. Because every resume path removes the
        // waiter from the heap in the same actor-synchronous step, a successful
        // removal proves the waiter had not yet been resumed, so the subsequent
        // `tryResume` always succeeds.
        guard let waiter = waiters.remove(id: waiterId) else { return }
        _ = waiter.tryResume(with: .timedOut)
    }

    /// Handles cancellation for a specific waiter
    private func handleCancellationForWaiter(waiterId: UUID) {
        // Same ownership transfer as `handleTimeout`: removing from the heap is the
        // single point that claims the waiter. If it was already resumed (e.g. by
        // `signal()`, a timeout, or the in-body cancellation race fix), it is no
        // longer in the heap and `remove(id:)` returns nil.
        //
        // NOTE: We do NOT restore resources here because the waiter never actually
        // acquired a resource - it was just waiting in line. Resources are only
        // consumed when wait() returns successfully.
        guard let waiter = waiters.remove(id: waiterId) else { return }
        waiter.cancelTimeout()
        _ = waiter.tryResume(with: .cancelled)
    }

    /// Gets the current number of available resources (for testing)
    public func availableResourcesCount() -> Int {
        availableResources
    }

    /// Gets the current number of waiters (for testing)
    internal func waiterCount() -> Int {
        waiters.count
    }
}
