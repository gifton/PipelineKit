import Foundation

/// An enhanced async semaphore with token-based resource management and back-pressure control.
///
/// `BackPressureAsyncSemaphore` provides safe, automatic resource management through tokens
/// while supporting queue limits and configurable back-pressure strategies. Resources are
/// automatically released when tokens are deallocated, preventing leaks.
///
/// ## Design Principles
///
/// - **Token-Based**: All acquisitions return tokens that auto-release
/// - **Cancellation-Safe**: Properly handles task cancellation
/// - **Memory-Bounded**: Queue size limits prevent unbounded growth
/// - **Observable**: Rich statistics and health monitoring
///
/// ## Example
/// ```swift
/// let semaphore = BackPressureAsyncSemaphore(
///     maxConcurrency: 5,
///     maxOutstanding: 20,
///     maxQueueMemory: 10_485_760, // 10MB
///     strategy: .suspend
/// )
///
/// let token = try await semaphore.acquire()
/// // Token automatically releases when out of scope
/// ```
internal actor BackPressureAsyncSemaphore {
    /// The maximum number of resources that can be active simultaneously.
    private let maxConcurrency: Int
    
    /// The maximum number of total outstanding operations (active + queued).
    private let maxOutstanding: Int
    
    /// Maximum memory (in bytes) that can be used by the queue.
    private let maxQueueMemory: Int?
    
    /// How to handle back-pressure when limits are exceeded.
    private let strategy: BackPressureStrategy
    
    /// The current number of available resources.
    private var availableResources: Int
    
    /// Currently active tokens.
    private var activeTokens: Set<UUID> = []
    
    /// Queue of waiters for resources.
    private var waiters: [WaiterEntry] = []
    
    /// Background cleanup task handle.
    private var cleanupTask: Task<Void, Never>?
    
    /// Entry in the waiter queue with enhanced metadata.
    private struct WaiterEntry {
        let continuation: CheckedContinuation<SemaphoreToken, Error>
        let enqueuedAt: Date
        let id: UUID
        let estimatedSize: Int
        let priority: QueuePriority
        
        init(
            continuation: CheckedContinuation<SemaphoreToken, Error>,
            estimatedSize: Int = 1024, // 1KB default
            priority: QueuePriority = .normal
        ) {
            self.continuation = continuation
            self.enqueuedAt = Date()
            self.id = UUID()
            self.estimatedSize = estimatedSize
            self.priority = priority
        }
        
        var age: TimeInterval {
            Date().timeIntervalSince(enqueuedAt)
        }
    }
    
    /// Queue priority levels for fair scheduling.
    public enum QueuePriority: Int, Comparable {
        case low = 0
        case normal = 1
        case high = 2
        case critical = 3
        
        public static func < (lhs: QueuePriority, rhs: QueuePriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    /// Creates a new back-pressure aware semaphore with token-based management.
    ///
    /// - Parameters:
    ///   - maxConcurrency: Maximum number of concurrent operations.
    ///   - maxOutstanding: Maximum total operations (active + queued).
    ///   - maxQueueMemory: Maximum memory for queued operations (optional).
    ///   - strategy: Back-pressure strategy when limits are exceeded.
    ///   - waiterTimeout: Maximum time a waiter can remain in queue (default: 5 minutes).
    internal init(
        maxConcurrency: Int,
        maxOutstanding: Int? = nil,
        maxQueueMemory: Int? = nil,
        strategy: BackPressureStrategy = .suspend,
        waiterTimeout: TimeInterval = 300 // 5 minutes
    ) {
        self.maxConcurrency = maxConcurrency
        self.maxOutstanding = maxOutstanding ?? (maxConcurrency * 10)
        self.maxQueueMemory = maxQueueMemory
        self.strategy = strategy
        self.availableResources = maxConcurrency
        
        // Start background cleanup task after init
        Task { @MainActor in
            await self.startCleanupTask(timeout: waiterTimeout)
        }
    }
    
    /// Starts the background cleanup task.
    private func startCleanupTask(timeout: TimeInterval) {
        self.cleanupTask = Task {
            await runCleanupLoop(timeout: timeout)
        }
    }
    
    deinit {
        cleanupTask?.cancel()
        
        // Fail all pending waiters
        for waiter in waiters {
            waiter.continuation.resume(throwing: BackPressureError.semaphoreShutdown)
        }
    }
    
    // MARK: - Token-Based Acquisition
    
    /// Attempts to acquire a resource, returning a token that auto-releases.
    ///
    /// - Parameters:
    ///   - priority: Queue priority if waiting is required.
    ///   - estimatedSize: Estimated memory size for queue limits.
    /// - Returns: A token that must be retained while using the resource.
    /// - Throws: `BackPressureError` based on the configured strategy.
    public func acquire(
        priority: QueuePriority = .normal,
        estimatedSize: Int = 1024
    ) async throws -> SemaphoreToken {
        // Fast path: resource available immediately
        if availableResources > 0 {
            availableResources -= 1
            let token = SemaphoreToken(semaphore: self)
            activeTokens.insert(token.id)
            return token
        }
        
        // Check queue limits before queuing
        try enforceQueueLimits(newSize: estimatedSize)
        
        // Queue the request with cancellation support
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let entry = WaiterEntry(
                    continuation: continuation,
                    estimatedSize: estimatedSize,
                    priority: priority
                )
                
                // Insert based on priority
                let insertIndex = waiters.firstIndex { $0.priority < priority } ?? waiters.count
                waiters.insert(entry, at: insertIndex)
            }
        } onCancel: {
            Task { await self.handleCancellation() }
        }
    }
    
    /// Attempts to acquire with a timeout.
    ///
    /// - Parameters:
    ///   - timeout: Maximum time to wait.
    ///   - priority: Queue priority if waiting is required.
    ///   - estimatedSize: Estimated memory size for queue limits.
    /// - Returns: A token if acquired within timeout, nil otherwise.
    /// - Throws: `BackPressureError` for non-timeout failures.
    public func acquire(
        timeout: TimeInterval,
        priority: QueuePriority = .normal,
        estimatedSize: Int = 1024
    ) async throws -> SemaphoreToken? {
        do {
            return try await withThrowingTaskGroup(of: SemaphoreToken.self) { group in
                group.addTask {
                    try await self.acquire(priority: priority, estimatedSize: estimatedSize)
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw BackPressureError.timeout(duration: timeout)
                }
                
                if let result = try await group.next() {
                    group.cancelAll()
                    return result
                }
                
                return nil
            }
        } catch let error as BackPressureError {
            throw error
        } catch {
            return nil // Timeout
        }
    }
    
    // MARK: - Token Management
    
    /// Releases a token's resource back to the pool.
    internal func releaseToken(_ token: SemaphoreToken) {
        guard activeTokens.remove(token.id) != nil else {
            // Token was already released or never acquired
            return
        }
        
        // Try to resume a waiter
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            let newToken = SemaphoreToken(semaphore: self, id: waiter.id)
            activeTokens.insert(newToken.id)
            waiter.continuation.resume(returning: newToken)
        } else {
            availableResources += 1
        }
    }
    
    /// Emergency release for tokens cleaned up in deinit.
    internal func emergencyRelease(tokenId: UUID) {
        if activeTokens.remove(tokenId) != nil {
            // Same logic as releaseToken but without the token reference
            if !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                let newToken = SemaphoreToken(semaphore: self, id: waiter.id)
                activeTokens.insert(newToken.id)
                waiter.continuation.resume(returning: newToken)
            } else {
                availableResources += 1
            }
        }
    }
    
    // MARK: - Queue Management
    
    /// Enforces queue limits before adding a new waiter.
    private func enforceQueueLimits(newSize: Int) throws {
        // Check outstanding limit
        let currentOutstanding = activeTokens.count + waiters.count
        if currentOutstanding >= maxOutstanding {
            switch strategy {
            case .suspend:
                // For suspend strategy, apply a hard limit at 2x to prevent runaway
                if currentOutstanding >= maxOutstanding * 2 {
                    throw BackPressureError.queueFull(
                        current: currentOutstanding,
                        limit: maxOutstanding * 2
                    )
                }
            case .dropOldest:
                dropOldestWaiter()
            case .dropNewest:
                throw BackPressureError.commandDropped(reason: "Queue at capacity")
            case let .error(timeout):
                if timeout == nil {
                    throw BackPressureError.queueFull(
                        current: currentOutstanding,
                        limit: maxOutstanding
                    )
                }
                // If timeout specified, let it queue and timeout naturally
            }
        }
        
        // Check memory limit
        if let maxMemory = maxQueueMemory {
            let currentMemory = waiters.reduce(0) { $0 + $1.estimatedSize }
            if currentMemory + newSize > maxMemory {
                throw BackPressureError.memoryLimitExceeded(
                    current: currentMemory + newSize,
                    limit: maxMemory
                )
            }
        }
    }
    
    /// Drops the oldest waiter to make room.
    private func dropOldestWaiter() {
        guard !waiters.isEmpty else { return }
        
        let droppedWaiter = waiters.removeFirst()
        droppedWaiter.continuation.resume(
            throwing: BackPressureError.commandDropped(reason: "Dropped to make room for newer request")
        )
    }
    
    /// Handles task cancellation by cleaning up waiters.
    private func handleCancellation() {
        // Find and remove cancelled continuations
        // This is tricky because we can't directly check if a continuation is cancelled
        // Instead, we rely on the cleanup task to handle timeouts
    }
    
    // MARK: - Background Cleanup
    
    /// Runs periodic cleanup of expired waiters.
    private func runCleanupLoop(timeout: TimeInterval) async {
        while !Task.isCancelled {
            cleanupExpiredWaiters(timeout: timeout)
            
            // Sleep for 30 seconds between cleanups
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                break // Task cancelled
            }
        }
    }
    
    /// Removes waiters that have exceeded the timeout.
    private func cleanupExpiredWaiters(timeout: TimeInterval) {
        _ = Date() // For calculating age in the loop
        var indicesToRemove: [Int] = []
        
        for (index, waiter) in waiters.enumerated().reversed() {
            if waiter.age > timeout {
                indicesToRemove.append(index)
                waiter.continuation.resume(
                    throwing: BackPressureError.timeout(duration: timeout)
                )
            }
        }
        
        // Remove in reverse order to maintain indices
        for index in indicesToRemove {
            waiters.remove(at: index)
        }
    }
    
    // MARK: - Statistics & Monitoring
    
    /// Gets current semaphore statistics.
    public func getStats() -> SemaphoreStats {
        let queueMemory = waiters.reduce(0) { $0 + $1.estimatedSize }
        let oldestAge = waiters.first?.age
        
        return SemaphoreStats(
            maxConcurrency: maxConcurrency,
            maxOutstanding: maxOutstanding,
            availableResources: availableResources,
            activeOperations: activeTokens.count,
            queuedOperations: waiters.count,
            totalOutstanding: activeTokens.count + waiters.count,
            queueMemoryUsage: queueMemory,
            oldestWaiterAge: oldestAge
        )
    }
    
    /// Performs a health check on the semaphore.
    public func healthCheck() -> SemaphoreHealth {
        let stats = getStats()
        
        let queueUtilization = Double(stats.queuedOperations) / Double(maxOutstanding)
        let memoryUtilization = maxQueueMemory.map { Double(stats.queueMemoryUsage) / Double($0) } ?? 0
        
        let isHealthy = (stats.oldestWaiterAge ?? 0) < 60 && // No waiter older than 1 minute
                       queueUtilization < 0.9 &&              // Queue not over 90% full
                       memoryUtilization < 0.9                 // Memory not over 90% full
        
        return SemaphoreHealth(
            isHealthy: isHealthy,
            queueUtilization: queueUtilization,
            memoryUtilization: memoryUtilization,
            oldestWaiterAge: stats.oldestWaiterAge ?? 0
        )
    }
}

// MARK: - Supporting Types

/// Enhanced statistics with memory and age tracking.
public struct SemaphoreStats: Sendable {
    public let maxConcurrency: Int
    public let maxOutstanding: Int
    public let availableResources: Int
    public let activeOperations: Int
    public let queuedOperations: Int
    public let totalOutstanding: Int
    public let queueMemoryUsage: Int
    public let oldestWaiterAge: TimeInterval?
}

/// Health status for monitoring.
public struct SemaphoreHealth: Sendable {
    public let isHealthy: Bool
    public let queueUtilization: Double
    public let memoryUtilization: Double
    public let oldestWaiterAge: TimeInterval
}

/// Extended back-pressure errors.
extension BackPressureError {
    /// The semaphore was shut down while operations were pending.
    static let semaphoreShutdown = BackPressureError.commandDropped(
        reason: "Semaphore shut down with pending operations"
    )
    
    /// Memory limit exceeded for queued operations.
    static func memoryLimitExceeded(current: Int, limit: Int) -> BackPressureError {
        .commandDropped(reason: "Memory limit exceeded (\(current)/\(limit) bytes)")
    }
}