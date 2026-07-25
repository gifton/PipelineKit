import Foundation
import PipelineKitCore

/// A minimal async semaphore implementation for basic concurrency control.
///
/// SimpleSemaphore provides the essential semaphore functionality without
/// the complexity of memory tracking, priorities, or advanced back-pressure
/// strategies. For advanced features, use BackPressureAsyncSemaphore from
/// the PipelineKitResilience module.
///
/// ## Example
/// ```swift
/// let semaphore = SimpleSemaphore(permits: 3)
/// let token = await semaphore.acquire()
/// // Use resource...
/// token.release() // Or let it auto-release
/// ```
public actor SimpleSemaphore {
    /// Available permits for resource acquisition.
    private var permits: Int
    
    /// Queue of waiters for permits with their IDs for cancellation.
    private var waiters: [(id: UUID, continuation: CheckedContinuation<SemaphoreToken, any Error>)] = []
    
    /// Creates a simple semaphore with the specified number of permits.
    ///
    /// - Parameter permits: The maximum number of concurrent resource acquisitions.
    public init(permits: Int) {
        precondition(permits > 0, "Permits must be positive")
        self.permits = permits
    }
    
    /// Acquires a permit, waiting if necessary.
    ///
    /// This method suspends until a permit is available. The returned token
    /// automatically releases the permit when deallocated.
    ///
    /// - Note: FIFO ordering is not guaranteed. Tasks may be resumed in any order
    ///         when permits become available. For strict FIFO ordering, use
    ///         BackPressureAsyncSemaphore from PipelineKitResilience.
    ///
    /// - Returns: A token representing the acquired permit.
    /// - Throws: `CancellationError` if the task is cancelled while waiting.
    public func acquire() async throws -> SemaphoreToken {
        // Fast path: permit immediately available
        if permits > 0 {
            permits -= 1
            return SemaphoreToken { [weak self] in
                Task { await self?._release() }
            }
        }
        
        // Slow path: wait for a permit with proper cancellation support
        let waiterID = UUID()

        let token = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }

        // Cancellation race fix (lost wakeup): `onCancel` merely *spawns* an
        // unstructured task to run `cancelWaiter`, while a concurrent
        // `SemaphoreToken.release()` spawns an unstructured task to run
        // `_release`. Those two tasks race for the actor. If `_release` wins,
        // it pops this (already-cancelled) waiter and resumes it with a fresh
        // token, and the later `cancelWaiter` finds nothing to do — so a
        // cancelled `acquire()` would return a token, violating the documented
        // contract ("Throws CancellationError if the task is cancelled while
        // waiting"). Callers that rely on that contract may then strand the
        // token (e.g. inside a completed `Task`'s result that is never
        // consumed), trapping the permit forever and deadlocking every future
        // waiter.
        //
        // Detect that outcome here, in the waiter's own task, where the
        // cancellation flag is unambiguous: if `_release` won the race, the
        // task's cancel flag was necessarily set *before* `onCancel` fired,
        // so it is visible by the time we resume. Forward the permit (waking
        // the next waiter, or restoring a permit) and honor the contract by
        // throwing. `release()` is idempotent, and the pending `cancelWaiter`
        // task remains a harmless no-op because `_release` already removed
        // this waiter. If instead `cancelWaiter` won the race, the
        // continuation above threw and this code is never reached.
        if Task.isCancelled {
            token.release()
            throw CancellationError()
        }
        return token
    }
    
    /// Attempts to acquire a permit without waiting.
    ///
    /// - Returns: A token if a permit is immediately available, nil otherwise.
    public func tryAcquire() -> SemaphoreToken? {
        guard permits > 0 else { return nil }
        
        permits -= 1
        return SemaphoreToken { [weak self] in
            Task { await self?._release() }
        }
    }
    
    /// Releases a permit back to the semaphore.
    private func _release() {
        // Try to find a waiter to grant the permit to
        if let waiter = waiters.first {
            waiters.removeFirst()
            // Grant permit to waiting task
            let token = SemaphoreToken { [weak self] in
                Task { await self?._release() }
            }
            waiter.continuation.resume(returning: token)
        } else {
            // No waiters, return permit to pool
            permits += 1
        }
    }
    
    /// Cancels a waiting task and properly resumes its continuation.
    private func cancelWaiter(_ waiterID: UUID) {
        // Find and remove the waiter, then resume with cancellation error
        if let index = waiters.firstIndex(where: { $0.id == waiterID }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
    
    /// Gets the current number of available permits.
    public var availablePermits: Int {
        permits
    }
    
    /// Gets the current number of waiting tasks.
    public var waitingCount: Int {
        waiters.count
    }
}
