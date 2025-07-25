import Foundation

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
public actor AsyncSemaphore {
    /// The current number of available resources.
    private var value: Int
    
    /// Queue of continuations waiting for resources to become available.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    /// Tracks waiting tasks by ID for timeout cancellation
    private var waitingTasks: [UUID: CheckedContinuation<Bool, Never>] = [:]
    
    /// Creates a new semaphore with the specified initial value.
    ///
    /// - Parameter value: The initial number of available resources.
    public init(value: Int) {
        self.value = value
    }
    
    /// Waits for a resource to become available.
    ///
    /// If resources are available (value > 0), this method decrements the count
    /// and returns immediately. Otherwise, it suspends until a resource is released.
    public func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    /// Waits for a resource to become available with a timeout.
    ///
    /// If resources are available (value > 0), this method decrements the count
    /// and returns immediately. Otherwise, it suspends until a resource is released
    /// or the timeout expires.
    ///
    /// - Parameter timeout: The maximum time to wait, in seconds
    /// - Returns: True if a resource was acquired, false if timeout occurred
    public func wait(timeout: TimeInterval) async -> Bool {
        if value > 0 {
            value -= 1
            return true
        }
        
        let taskId = UUID()
        
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Store the continuation with its ID
                waitingTasks[taskId] = continuation
                
                // Schedule timeout
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    
                    // If still waiting after timeout, cancel it
                    if let waiter = waitingTasks.removeValue(forKey: taskId) {
                        waiter.resume(returning: false)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaitingTask(taskId)
            }
        }
    }
    
    /// Cancels a waiting task
    private func cancelWaitingTask(_ taskId: UUID) {
        if let waiter = waitingTasks.removeValue(forKey: taskId) {
            waiter.resume(returning: false)
        }
    }
    
    /// Signals that a resource has been released.
    ///
    /// If there are waiting tasks, this method resumes the first waiter.
    /// Otherwise, it increments the available resource count.
    public func signal() {
        // First check if there are any timeout waiters
        if !waitingTasks.isEmpty {
            // Find and resume the first timeout waiter
            if let (taskId, continuation) = waitingTasks.first {
                waitingTasks.removeValue(forKey: taskId)
                continuation.resume(returning: true)
                return
            }
        }
        
        // Then check regular waiters
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
            return
        }
        
        // No waiters, increment the value
        value += 1
    }
}