import Foundation
import PipelineKitCore  // For PipelineError

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
    
    /// Queue of waiting tasks (FIFO ordering)
    private var waiters: [Waiter] = []
    
    /// Lookup table for O(1) timeout handling
    private var waiterLookup: [UUID: Waiter] = [:]
    
    /// State of a waiter
    private enum WaiterState {
        case waiting
        case resumed
    }
    
    /// Type of continuation
    private enum ContinuationType {
        case regular(CheckedContinuation<Void, Error>)
        case timeout(CheckedContinuation<Bool, Never>)
    }
    
    /// Result of wait operation
    private enum WaitResult {
        case signaled
        case timedOut
        case cancelled
    }
    
    /// Represents a waiting task
    private class Waiter {
        let id = UUID()
        var state = WaiterState.waiting
        let continuation: ContinuationType
        var timeoutTask: Task<Void, Never>?
        
        init(continuation: ContinuationType) {
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
    }
    
    /// Waits for a resource to become available.
    ///
    /// If resources are available (value > 0), this method decrements the count
    /// and returns immediately. Otherwise, it suspends until a resource is released.
    ///
    /// - Throws: CancellationError if the task is cancelled while waiting
    public func wait() async throws {
        // Check for cancellation before proceeding
        try Task.checkCancellation()
        
        // Fast path: resource available
        if availableResources > 0 {
            availableResources -= 1
            return
        }
        
        // Slow path: need to wait
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let waiter = Waiter(continuation: .regular(continuation))
                waiters.append(waiter)
                waiterLookup[waiter.id] = waiter
            }
        } onCancel: {
            Task { @Sendable [weak self] in
                await self?.handleCancellation()
            }
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
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let waiter = Waiter(continuation: .timeout(continuation))
                
                // Create timeout task
                let timeoutTask = Task { [weak self, waiterId = waiter.id] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    
                    // If we reach here, timeout occurred
                    await self?.handleTimeout(waiterId: waiterId)
                }
                
                waiter.timeoutTask = timeoutTask
                waiters.append(waiter)
                waiterLookup[waiter.id] = waiter
            }
        } onCancel: { [weak self] in
            // Handle task cancellation
            Task { [weak self] in
                await self?.handleCancellation()
            }
        }
    }
    
    /// Signals that a resource has been released.
    ///
    /// If there are waiting tasks, this method resumes the first waiter.
    /// Otherwise, it increments the available resource count.
    public func signal() {
        // Check if there are any waiters
        guard !waiters.isEmpty else {
            availableResources += 1
            return
        }
        
        // Resume the first waiter (FIFO)
        let waiter = waiters.removeFirst()
        waiterLookup.removeValue(forKey: waiter.id)
        
        // Cancel timeout if exists
        waiter.cancelTimeout()
        
        // Try to resume with signaled result
        _ = waiter.tryResume(with: .signaled)
    }
    
    /// Handles timeout expiration
    private func handleTimeout(waiterId: UUID) {
        // Find the waiter
        guard let waiter = waiterLookup[waiterId] else { return }
        
        // Try to resume with timeout result
        if waiter.tryResume(with: .timedOut) {
            // Remove from storage
            waiterLookup.removeValue(forKey: waiterId)
            if let index = waiters.firstIndex(where: { $0.id == waiterId }) {
                waiters.remove(at: index)
            }
        }
    }
    
    /// Handles task cancellation
    private func handleCancellation() {
        // Resume all waiting tasks with cancellation error
        let currentWaiters = waiters
        waiters.removeAll()
        waiterLookup.removeAll()
        
        // Resume each waiter with cancelled result
        for waiter in currentWaiters {
            waiter.cancelTimeout()
            _ = waiter.tryResume(with: .cancelled)
        }
    }
    
    /// Handles cancellation for a specific waiter
    private func handleCancellationForWaiter(waiterId: UUID) {
        guard let waiter = waiterLookup[waiterId] else { return }
        
        // Try to resume with cancelled result
        if waiter.tryResume(with: .cancelled) {
            // Remove from storage
            waiterLookup.removeValue(forKey: waiterId)
            if let index = waiters.firstIndex(where: { $0.id == waiterId }) {
                waiters.remove(at: index)
            }
            waiter.cancelTimeout()
        }
    }
    
    /// Gets the current number of available resources (for testing)
    internal func availableResourcesCount() -> Int {
        availableResources
    }
    
    /// Gets the current number of waiters (for testing)
    internal func waiterCount() -> Int {
        waiters.count
    }
}
