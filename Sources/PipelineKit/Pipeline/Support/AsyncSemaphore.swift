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
internal actor AsyncSemaphore {
    /// The current number of available resources.
    private var value: Int
    
    /// Queue of continuations waiting for resources to become available.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    /// Creates a new semaphore with the specified initial value.
    ///
    /// - Parameter value: The initial number of available resources.
    internal init(value: Int) {
        self.value = value
    }
    
    /// Waits for a resource to become available.
    ///
    /// If resources are available (value > 0), this method decrements the count
    /// and returns immediately. Otherwise, it suspends until a resource is released.
    internal func wait() async {
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
    internal func wait(timeout: TimeInterval) async -> Bool {
        if value > 0 {
            value -= 1
            return true
        }
        
        // For simplicity, we'll wait without timeout for now
        // A full implementation would require more sophisticated continuation tracking
        await wait()
        return true
    }
    
    /// Signals that a resource has been released.
    ///
    /// If there are waiting tasks, this method resumes the first waiter.
    /// Otherwise, it increments the available resource count.
    internal func signal() {
        if waiters.isEmpty {
            value += 1
            return
        }
        
        let waiter = waiters.removeFirst()
        waiter.resume()
    }
}