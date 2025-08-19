import Foundation

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
public actor SimpleSemaphore: Sendable {
    /// Available permits for resource acquisition.
    private var permits: Int
    
    /// Queue of waiters for permits with their IDs for cancellation.
    /// Tracks both the waiter ID and whether they've been cancelled.
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancelledWaiters: Set<UUID> = []
    
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
    public func acquire() async -> SemaphoreToken {
        if permits > 0 {
            permits -= 1
            return SemaphoreToken { [weak self] in
                Task { await self?._release() }
            }
        }
        
        // Wait for a permit to become available with cancellation support
        let waiterID = UUID()
        
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id: waiterID, continuation: continuation))
            }
            
            // Permit was granted by a release
            return SemaphoreToken { [weak self] in
                Task { await self?._release() }
            }
        } onCancel: {
            Task { await self.removeWaiter(waiterID) }
        }
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
        // Skip cancelled waiters
        while let waiter = waiters.first {
            waiters.removeFirst()
            if !cancelledWaiters.contains(waiter.id) {
                // Grant permit to non-cancelled waiting task
                cancelledWaiters.remove(waiter.id)
                waiter.continuation.resume()
                return
            }
            // Remove cancelled waiter and continue
            cancelledWaiters.remove(waiter.id)
        }
        // No waiters, return permit to pool
        permits += 1
    }
    
    /// Marks a waiter as cancelled when their task is cancelled.
    private func removeWaiter(_ waiterID: UUID) {
        cancelledWaiters.insert(waiterID)
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