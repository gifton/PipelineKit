import Foundation

/// An enhanced async semaphore with back-pressure control and queue management.
///
/// `BackPressureAsyncSemaphore` extends the basic AsyncSemaphore functionality
/// with support for queue limits and configurable back-pressure strategies.
/// It can suspend producers, drop commands, or throw errors when capacity is exceeded.
///
/// ## Example
/// ```swift
/// let semaphore = BackPressureAsyncSemaphore(
///     maxConcurrency: 5,
///     maxOutstanding: 20,
///     strategy: .suspend
/// )
///
/// // This will suspend if queue is full
/// try await semaphore.acquire()
/// defer { await semaphore.release() }
/// // Perform work...
/// ```
internal actor BackPressureAsyncSemaphore {
    /// The maximum number of resources that can be active simultaneously.
    private let maxConcurrency: Int
    
    /// The maximum number of total outstanding operations (active + queued).
    private let maxOutstanding: Int?
    
    /// How to handle back-pressure when limits are exceeded.
    private let strategy: BackPressureStrategy
    
    /// The current number of available resources.
    private var availableResources: Int
    
    /// Queue of continuations waiting for resources to become available.
    private var waiters: [WaiterEntry] = []
    
    /// Entry in the waiter queue with metadata for back-pressure management.
    private struct WaiterEntry {
        let continuation: CheckedContinuation<Void, Error>
        let enqueuedAt: Date
        let id: UUID
        
        init(continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
            self.enqueuedAt = Date()
            self.id = UUID()
        }
    }
    
    /// Current outstanding operations count (active + queued).
    internal var outstandingCount: Int {
        (maxConcurrency - availableResources) + waiters.count
    }
    
    /// Current number of queued waiters.
    internal var queueDepth: Int {
        waiters.count
    }
    
    /// Creates a new back-pressure aware semaphore.
    ///
    /// - Parameters:
    ///   - maxConcurrency: Maximum number of concurrent operations.
    ///   - maxOutstanding: Maximum total operations (active + queued). If nil, unlimited queue.
    ///   - strategy: Back-pressure strategy when limits are exceeded.
    internal init(
        maxConcurrency: Int,
        maxOutstanding: Int? = nil,
        strategy: BackPressureStrategy = .suspend
    ) {
        self.maxConcurrency = maxConcurrency
        self.maxOutstanding = maxOutstanding
        self.strategy = strategy
        self.availableResources = maxConcurrency
    }
    
    /// Attempts to acquire a resource with back-pressure control.
    ///
    /// Behavior depends on the configured back-pressure strategy:
    /// - `.suspend`: Waits indefinitely until a resource becomes available
    /// - `.dropOldest`: Removes oldest waiter to make room if queue is full
    /// - `.dropNewest`: Throws error if queue is full
    /// - `.error(timeout)`: Throws error immediately or after timeout
    ///
    /// - Throws: `BackPressureError` based on the configured strategy
    internal func acquire() async throws {
        // Fast path: resource available immediately
        if availableResources > 0 {
            availableResources -= 1
            return
        }
        
        // Check if we've exceeded the outstanding limit
        if let maxOutstanding = maxOutstanding, outstandingCount >= maxOutstanding {
            try await handleBackPressure()
        }
        
        // Queue the request
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let entry = WaiterEntry(continuation: continuation)
            waiters.append(entry)
        }
    }
    
    /// Attempts to acquire a resource with a timeout.
    ///
    /// - Parameter timeout: Maximum time to wait for a resource
    /// - Returns: True if acquired successfully, false if timed out
    /// - Throws: `BackPressureError` for back-pressure violations
    internal func acquire(timeout: TimeInterval) async throws -> Bool {
        // Fast path: resource available immediately
        if availableResources > 0 {
            availableResources -= 1
            return true
        }
        
        // Check back-pressure limits
        if let maxOutstanding = maxOutstanding, outstandingCount >= maxOutstanding {
            switch strategy {
            case .error:
                throw BackPressureError.queueFull(current: outstandingCount, limit: maxOutstanding)
            case .dropNewest:
                throw BackPressureError.commandDropped(reason: "Queue full, dropping newest")
            case .dropOldest:
                try await dropOldestWaiter()
            case .suspend:
                // Continue to queuing with timeout
                break
            }
        }
        
        // Queue with timeout
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let entry = WaiterEntry(continuation: continuation)
                    self.waiters.append(entry)
                }
                return true
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BackPressureError.timeout(duration: timeout)
            }
            
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
    
    /// Releases a resource, potentially resuming waiting operations.
    internal func release() {
        if waiters.isEmpty {
            availableResources += 1
            return
        }
        
        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }
    
    /// Handles back-pressure when limits are exceeded.
    private func handleBackPressure() async throws {
        guard let maxOutstanding = maxOutstanding else { return }
        
        switch strategy {
        case .suspend:
            // Allow unlimited queuing - will suspend naturally
            break
            
        case .dropOldest:
            try await dropOldestWaiter()
            
        case .dropNewest:
            throw BackPressureError.commandDropped(reason: "Queue full, dropping newest")
            
        case let .error(timeout):
            if let timeout = timeout {
                // Will timeout in acquire(timeout:) method
                break
            } else {
                throw BackPressureError.queueFull(current: outstandingCount, limit: maxOutstanding)
            }
        }
    }
    
    /// Drops the oldest waiter to make room for a new request.
    private func dropOldestWaiter() async throws {
        guard !waiters.isEmpty else { return }
        
        let oldestWaiter = waiters.removeFirst()
        let error = BackPressureError.commandDropped(reason: "Dropped oldest waiter to make room")
        oldestWaiter.continuation.resume(throwing: error)
    }
    
    /// Gets current semaphore statistics for monitoring.
    internal func getStats() -> SemaphoreStats {
        SemaphoreStats(
            maxConcurrency: maxConcurrency,
            maxOutstanding: maxOutstanding,
            availableResources: availableResources,
            activeOperations: maxConcurrency - availableResources,
            queuedOperations: waiters.count,
            totalOutstanding: outstandingCount
        )
    }
}

/// Statistics about semaphore state for monitoring and debugging.
internal struct SemaphoreStats: Sendable {
    /// Maximum allowed concurrent operations.
    let maxConcurrency: Int
    
    /// Maximum allowed outstanding operations (nil = unlimited).
    let maxOutstanding: Int?
    
    /// Currently available resources.
    let availableResources: Int
    
    /// Number of operations currently executing.
    let activeOperations: Int
    
    /// Number of operations waiting in queue.
    let queuedOperations: Int
    
    /// Total outstanding operations (active + queued).
    let totalOutstanding: Int
}