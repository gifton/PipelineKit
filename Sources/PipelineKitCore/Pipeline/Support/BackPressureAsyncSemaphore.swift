import Foundation
import Atomics

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
///
/// // Important: Call shutdown before deallocation to ensure clean cleanup
/// await semaphore.shutdown()
/// ```
public actor BackPressureAsyncSemaphore {
    // MARK: - Configuration
    
    /// The maximum number of resources that can be active simultaneously.
    private let maxConcurrency: Int
    
    /// The maximum number of total outstanding operations (active + queued).
    private let maxOutstanding: Int
    
    /// Maximum memory (in bytes) that can be used by the queue.
    private let maxQueueMemory: Int?
    
    /// How to handle back-pressure when limits are exceeded.
    private let strategy: BackPressureStrategy
    
    // MARK: - Fast Path State (Non-isolated)
    
    /// Available permits counter using negative value trick:
    /// - Positive: Number of available permits
    /// - Zero: No permits, no waiters
    /// - Negative: Absolute value = number of waiters in queue
    private let availablePermits = ManagedAtomic<Int>(0)
    
    /// Flag to prevent multiple drain tasks from being scheduled
    private let drainScheduled = ManagedAtomic<Bool>(false)
    
    /// Global token ID counter for cheap unique IDs
    private static let nextTokenID = ManagedAtomic<UInt64>(0)
    
    // MARK: - Actor-isolated State
    
    /// Currently active tokens.
    private var activeTokens: Set<UInt64> = []
    
    /// Priority queue of waiters for resources.
    private var waiters: PriorityHeap<CancellableWaiter>
    
    /// Lookup table for O(1) cancellation handling.
    private var waiterLookup: [UUID: UUID] = [:] // Maps waiterID to entry.id
    
    /// Reverse lookup for efficient cleanup.
    private var reverseWaiterLookup: [UUID: Set<UUID>] = [:] // Maps entry.id to waiterIDs
    
    /// Cleanup interval for expired waiters.
    private let cleanupInterval: TimeInterval
    
    /// Background cleanup task handle.
    private var cleanupTask: Task<Void, Never>?
    
    /// Track if cleanup task has been started
    private var cleanupTaskStarted = false
    
    /// Waiter timeout for cleanup
    private let waiterTimeout: TimeInterval
    
    /// Cancellable waiter entry with atomic cancellation support.
    private final class CancellableWaiter {
        let continuation: CheckedContinuation<SemaphoreToken, Error>
        let cancelledFlag: ManagedAtomic<Bool> = .init(false)
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
        
        /// Resume with a token if not already cancelled.
        func resumeIfNotCancelled(with token: SemaphoreToken) {
            if cancelledFlag.exchange(true, ordering: .acquiring) == false {
                continuation.resume(returning: token)
            }
        }
        
        /// Cancel if not already resumed.
        func cancelIfNotResumed() {
            if cancelledFlag.exchange(true, ordering: .acquiring) == false {
                continuation.resume(throwing: CancellationError())
            }
        }
    }
    
    /// Queue priority levels for fair scheduling.
    public enum QueuePriority: Int, Comparable, Sendable {
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
    ///   - cleanupInterval: Interval for cleaning up expired waiters (default: 1 second).
    public init(
        maxConcurrency: Int,
        maxOutstanding: Int? = nil,
        maxQueueMemory: Int? = nil,
        strategy: BackPressureStrategy = .suspend,
        waiterTimeout: TimeInterval = 300, // 5 minutes
        cleanupInterval: TimeInterval = 1.0 // 1 second
    ) {
        self.maxConcurrency = maxConcurrency
        self.maxOutstanding = maxOutstanding ?? (maxConcurrency * 10)
        self.maxQueueMemory = maxQueueMemory
        self.strategy = strategy
        self.cleanupInterval = cleanupInterval
        self.waiterTimeout = waiterTimeout
        
        // Initialize atomic counter with max permits
        self.availablePermits.store(maxConcurrency, ordering: .relaxed)
        
        // Initialize the priority heap
        self.waiters = PriorityHeap(
            comparator: { w1, w2 in
                // Higher priority (lower number) comes first
                if w1.priority != w2.priority {
                    return w1.priority > w2.priority
                }
                // For same priority, older waiter comes first (FIFO)
                return w1.enqueuedAt < w2.enqueuedAt
            },
            idExtractor: { $0.id }
        )
        
        // Note: Cleanup task is started lazily on first waiter to avoid actor deadlock
    }
    
    /// Starts the background cleanup task.
    private func startCleanupTask(timeout: TimeInterval) {
        self.cleanupTask = Task {
            await runCleanupLoop(timeout: timeout)
        }
    }
    
    deinit {
        cleanupTask?.cancel()
        
        // Since we're in deinit, we need to handle cleanup carefully
        // The waiters array and cleanup must happen synchronously
        
        // Note: We can't access actor-isolated state from deinit directly
        // The best approach is to ensure shutdown() is called before deallocation
        // For now, we'll just reset the atomic counter
        
        // Reset counter to reflect shutdown state
        availablePermits.store(0, ordering: .releasing)
    }
    
    // MARK: - Token-Based Acquisition
    
    /// Attempts to acquire a resource, returning a token that auto-releases.
    ///
    /// This method uses a fast-path optimization for uncontended cases,
    /// falling back to actor-isolated queueing when necessary.
    ///
    /// ## Fairness Note
    /// The current implementation uses a "greedy" CAS loop which may starve
    /// waiters under extreme contention. If fairness issues are observed in
    /// production, consider implementing a soft-fairness window after ~64
    /// consecutive fast-path acquisitions.
    ///
    /// - Parameters:
    ///   - priority: Queue priority if waiting is required.
    ///   - estimatedSize: Estimated memory size for queue limits.
    /// - Returns: A token that must be retained while using the resource.
    /// - Throws: `PipelineError` based on the configured strategy.
    public nonisolated func acquire(
        priority: QueuePriority = .normal,
        estimatedSize: Int = 1024
    ) async throws -> SemaphoreToken {
        // Fast path: try to acquire without actor hop
        while true {
            let current = availablePermits.load(ordering: .relaxed)
            if current > 0 {
                if availablePermits.compareExchange(
                    expected: current,
                    desired: current - 1,
                    ordering: .acquiringAndReleasing
                ).exchanged {
                    // Successfully acquired - create token with cheap ID
                    let tokenID = Self.nextTokenID.loadThenWrappingIncrement(ordering: .relaxed)
                    return SemaphoreToken(semaphore: self, id: tokenID)
                }
                // CAS failed, retry
                continue
            }
            // No permits available, fall back to slow path
            break
        }
        
        // Slow path: queue the request
        return try await _slowPathAcquire(priority: priority, estimatedSize: estimatedSize)
    }
    
    /// Actor-isolated slow path for acquire when fast path fails.
    private func _slowPathAcquire(
        priority: QueuePriority,
        estimatedSize: Int
    ) async throws -> SemaphoreToken {
        // Check queue limits before queuing
        try enforceQueueLimits(newSize: estimatedSize)
        
        // Decrement counter to reflect new waiter
        let prev = availablePermits.loadThenWrappingDecrement(ordering: .acquiringAndReleasing)
        
        // If a permit became available after we entered slow path, use it
        if prev > 0 {
            let tokenID = Self.nextTokenID.loadThenWrappingIncrement(ordering: .relaxed)
            let token = SemaphoreToken(semaphore: self, id: tokenID)
            activeTokens.insert(tokenID)
            return token
        }
        
        // Create a unique ID for cancellation handling
        let waiterID = UUID()
        
        // Start cleanup task on first waiter if not already started
        if !cleanupTaskStarted {
            cleanupTaskStarted = true
            startCleanupTask(timeout: waiterTimeout)
        }
        
        // Check if we need to schedule a drain (heap was empty)
        let wasEmpty = waiters.isEmpty
        
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = CancellableWaiter(
                    continuation: continuation,
                    estimatedSize: estimatedSize,
                    priority: priority
                )
                
                // Store mappings
                waiterLookup[waiterID] = waiter.id
                reverseWaiterLookup[waiter.id, default: []].insert(waiterID)
                
                // Insert into priority heap
                waiters.insert(waiter)
                
                // Schedule drain if heap transitioned from empty to non-empty
                if wasEmpty && drainScheduled.compareExchange(
                    expected: false,
                    desired: true,
                    ordering: .acquiringAndReleasing
                ).exchanged {
                    Task { await self.drainWaiters() }
                }
            }
        } onCancel: {
            Task { 
                await self.handleCancellation(waiterID: waiterID)
            }
        }
    }
    
    /// Attempts to acquire with a timeout.
    ///
    /// - Parameters:
    ///   - timeout: Maximum time to wait.
    ///   - priority: Queue priority if waiting is required.
    ///   - estimatedSize: Estimated memory size for queue limits.
    /// - Returns: A token if acquired within timeout, nil otherwise.
    /// - Throws: `PipelineError` for non-timeout failures.
    public func acquire(
        timeout: TimeInterval,
        priority: QueuePriority = .normal,
        estimatedSize: Int = 1024
    ) async throws -> SemaphoreToken? {
        do {
            return try await withThrowingTaskGroup(of: SemaphoreToken.self) { group in
                group.addTask { @Sendable in
                    try await self.acquire(priority: priority, estimatedSize: estimatedSize)
                }
                
                group.addTask { @Sendable in
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw PipelineError.backPressure(reason: .timeout(duration: timeout))
                }
                
                if let result = try await group.next() {
                    group.cancelAll()
                    return result
                }
                
                return nil
            }
        } catch let error as PipelineError {
            throw error
        } catch {
            return nil // Timeout
        }
    }
    
    /// Attempts to acquire a resource without waiting.
    ///
    /// This method returns immediately with either a token (if a resource is available)
    /// or nil (if no resources are available). It never blocks or queues.
    ///
    /// - Returns: A token if a resource is immediately available, nil otherwise.
    public nonisolated func tryAcquire() -> SemaphoreToken? {
        // Fast path only - no queuing
        while true {
            let current = availablePermits.load(ordering: .relaxed)
            if current > 0 {
                if availablePermits.compareExchange(
                    expected: current,
                    desired: current - 1,
                    ordering: .acquiringAndReleasing
                ).exchanged {
                    let tokenID = Self.nextTokenID.loadThenWrappingIncrement(ordering: .relaxed)
                    return SemaphoreToken(semaphore: self, id: tokenID)
                }
                // CAS failed, retry
                continue
            }
            // No permits available
            return nil
        }
    }
    
    // MARK: - Token Management
    
    /// Fast-path release called directly from token deinit.
    /// This is non-isolated and only touches atomic state.
    nonisolated func _fastPathRelease() {
        // Increment available permits
        let previous = availablePermits.loadThenWrappingIncrement(ordering: .releasing)
        
        // If there were no waiters (>= 0), we're done
        guard previous < 0 else { return }
        
        // There are waiters - schedule drain if not already scheduled
        if drainScheduled.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged {
            Task { await self.drainWaiters() }
        }
    }
    
    /// Drains waiters from the queue when permits become available.
    private func drainWaiters() async {
        defer {
            // Reset drain flag when done
            drainScheduled.store(false, ordering: .releasing)
        }
        
        // Process waiters while permits are available
        while let waiter = waiters.peek(),
              availablePermits.load(ordering: .acquiring) > 0 {
            
            // Check if waiter is cancelled before consuming permit
            guard waiter.cancelledFlag.load(ordering: .acquiring) == false else {
                // Remove cancelled waiter and continue
                _ = waiters.extractMin()
                cleanupWaiterMappings(waiter)
                continue
            }
            
            // Consume a permit
            guard availablePermits.loadThenWrappingDecrement(ordering: .acquiringAndReleasing) > 0 else {
                // Race condition: permit was taken, stop draining
                break
            }
            
            // Remove waiter from heap
            _ = waiters.extractMin()
            cleanupWaiterMappings(waiter)
            
            // Create token and resume
            let tokenID = Self.nextTokenID.loadThenWrappingIncrement(ordering: .relaxed)
            let token = SemaphoreToken(semaphore: self, id: tokenID)
            activeTokens.insert(tokenID)
            
            waiter.resumeIfNotCancelled(with: token)
        }
    }
    
    /// Cleans up waiter ID mappings.
    private func cleanupWaiterMappings(_ waiter: CancellableWaiter) {
        if let waiterIDs = reverseWaiterLookup[waiter.id] {
            for waiterID in waiterIDs {
                waiterLookup.removeValue(forKey: waiterID)
            }
            reverseWaiterLookup.removeValue(forKey: waiter.id)
        }
    }
    
    /// Legacy token release method - now just calls fast path.
    internal func releaseToken(_ token: SemaphoreToken) {
        // Remove from active tracking if present
        activeTokens.remove(token.id)
        _fastPathRelease()
    }
    
    /// Emergency release for tokens cleaned up in deinit.
    internal func emergencyRelease(tokenId: UInt64) {
        // Remove from active tracking if present
        activeTokens.remove(tokenId)
        _fastPathRelease()
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
                    throw PipelineError.backPressure(reason: .queueFull(
                        current: currentOutstanding,
                        limit: maxOutstanding * 2
                    ))
                }
            case .dropOldest:
                dropOldestWaiter()
            case .dropNewest:
                throw PipelineError.backPressure(reason: .commandDropped(reason: "Queue at capacity"))
            case let .error(timeout):
                if timeout == nil {
                    // No timeout specified, throw immediately
                    throw PipelineError.backPressure(reason: .queueFull(
                        current: currentOutstanding,
                        limit: maxOutstanding
                    ))
                }
                // If timeout specified, let it queue and timeout naturally
            }
        }
        
        // Check memory limit
        if let maxMemory = maxQueueMemory {
            let currentMemory = waiters.allElements().reduce(0) { $0 + $1.estimatedSize }
            if currentMemory + newSize > maxMemory {
                throw PipelineError.backPressure(reason: .memoryPressure)
            }
        }
    }
    
    /// Drops the oldest waiter to make room.
    private func dropOldestWaiter() {
        guard let droppedWaiter = waiters.extractMin() else { return }
        
        // Clean up any waiterID mappings for this entry efficiently
        if let waiterIDs = reverseWaiterLookup[droppedWaiter.id] {
            for waiterID in waiterIDs {
                waiterLookup.removeValue(forKey: waiterID)
            }
            reverseWaiterLookup.removeValue(forKey: droppedWaiter.id)
        }
        
        // Resume with error (no need to check cancellation flag since we're dropping it)
        droppedWaiter.continuation.resume(
            throwing: PipelineError.backPressure(reason: .commandDropped(reason: "Dropped to make room for newer request"))
        )
    }
    
    /// Handles task cancellation by cleaning up waiters.
    private func handleCancellation(waiterID: UUID) {
        // Find the entry ID from our waiterID
        guard let entryID = waiterLookup[waiterID] else { return }
        
        // Remove the waiter from the heap
        guard let waiter = waiters.remove(id: entryID) else { return }
        
        // Clean up mappings
        waiterLookup.removeValue(forKey: waiterID)
        if var waiterIDs = reverseWaiterLookup[entryID] {
            waiterIDs.remove(waiterID)
            if waiterIDs.isEmpty {
                reverseWaiterLookup.removeValue(forKey: entryID)
            } else {
                reverseWaiterLookup[entryID] = waiterIDs
            }
        }
        
        // Cancel the waiter
        waiter.cancelIfNotResumed()
        
        // CRITICAL: Increment counter to maintain invariant
        // This undoes the loadThenWrappingDecrement from when waiter was enqueued
        _ = availablePermits.loadThenWrappingIncrement(ordering: .releasing)
        
        // If counter is now positive and heap non-empty, schedule drain
        if availablePermits.load(ordering: .acquiring) > 0 && !waiters.isEmpty {
            if drainScheduled.compareExchange(
                expected: false,
                desired: true,
                ordering: .acquiringAndReleasing
            ).exchanged {
                Task { await self.drainWaiters() }
            }
        }
    }
    
    // MARK: - Background Cleanup
    
    /// Runs periodic cleanup of expired waiters.
    private func runCleanupLoop(timeout: TimeInterval) async {
        while !Task.isCancelled {
            await cleanupExpiredWaiters(timeout: timeout)
            
            // Sleep for cleanup interval between cleanups
            do {
                try await Task.sleep(nanoseconds: UInt64(cleanupInterval * 1_000_000_000))
            } catch {
                break // Task cancelled
            }
        }
    }
    
    /// Removes waiters that have exceeded the timeout.
    private func cleanupExpiredWaiters(timeout: TimeInterval) async {
        var idsToRemove: [UUID] = []
        
        // Find expired waiters
        for waiter in waiters.allElements() {
            if waiter.age > timeout {
                idsToRemove.append(waiter.id)
                // Try to cancel if not already resumed
                if waiter.cancelledFlag.exchange(true, ordering: .acquiring) == false {
                    waiter.continuation.resume(
                        throwing: PipelineError.backPressure(reason: .timeout(duration: timeout))
                    )
                }
            }
        }
        
        // Remove expired waiters from heap
        for id in idsToRemove {
            _ = waiters.remove(id: id)
            // Clean up any waiterID mappings for this entry efficiently
            if let waiterIDs = reverseWaiterLookup[id] {
                for waiterID in waiterIDs {
                    waiterLookup.removeValue(forKey: waiterID)
                }
                reverseWaiterLookup.removeValue(forKey: id)
            }
        }
    }
    
    // MARK: - Lifecycle Management
    
    /// Gracefully shuts down the semaphore, cancelling all waiters.
    ///
    /// This method ensures all tokens are properly cleaned up before the semaphore
    /// is deallocated, preventing issues with unowned(unsafe) references.
    ///
    /// - Parameter error: The error to throw for waiting operations (default: semaphoreShutdown)
    public func shutdown(error: Error? = nil) async {
        // Cancel cleanup task
        cleanupTask?.cancel()
        
        // Get all waiters to cancel
        let waitersToCancel = waiters.allElements()
        
        // Clear the heap
        waiters = PriorityHeap(
            comparator: { _, _ in false },
            idExtractor: { $0.id }
        )
        
        // Clear lookup tables
        waiterLookup.removeAll()
        reverseWaiterLookup.removeAll()
        
        // Cancel all waiters
        let shutdownError = error ?? PipelineError.semaphoreShutdown
        for waiter in waitersToCancel {
            if waiter.cancelledFlag.exchange(true, ordering: .acquiring) == false {
                waiter.continuation.resume(throwing: shutdownError)
            }
        }
        
        // Update counter to reflect cleared queue
        let currentPermits = availablePermits.load(ordering: .relaxed)
        if currentPermits < 0 {
            // We had waiters, add them back to get to zero or positive
            _ = availablePermits.loadThenWrappingIncrement(by: -currentPermits, ordering: .releasing)
        }
        
        // Debug assertion: verify all permits returned after shutdown
        #if DEBUG
        let finalPermits = availablePermits.load(ordering: .relaxed)
        let expectedPermits = maxConcurrency // After shutdown, should have all permits back
        assert(
            finalPermits == expectedPermits || finalPermits == 0,
            "Semaphore shutdown with incorrect permit count. Expected: \(expectedPermits) or 0, Actual: \(finalPermits)"
        )
        #endif
        
        // Note: We don't clear activeTokens to allow existing tokens to release properly
    }
    
    // MARK: - Statistics & Monitoring
    
    /// Gets current semaphore statistics.
    public func getStats() -> SemaphoreStats {
        let allWaiters = waiters.allElements()
        let queueMemory = allWaiters.reduce(0) { $0 + $1.estimatedSize }
        let oldestAge = allWaiters.min(by: { $0.enqueuedAt < $1.enqueuedAt })?.age
        
        // Calculate available from atomic counter
        let currentPermits = availablePermits.load(ordering: .relaxed)
        let availableResources = max(0, currentPermits)
        
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
extension PipelineError {
    /// The semaphore was shut down while operations were pending.
    static let semaphoreShutdown = PipelineError.backPressure(reason: .commandDropped(
        reason: "Semaphore shut down with pending operations"
    ))
    
    /// Memory limit exceeded for queued operations.
    static func memoryLimitExceeded(current: Int, limit: Int) -> PipelineError {
        .backPressure(reason: .commandDropped(reason: "Memory limit exceeded (\(current)/\(limit) bytes)"))
    }
}

// MARK: - Token Lifetime Documentation

/// Important: Token Lifetime Contract
///
/// SemaphoreToken uses unowned(unsafe) reference to the semaphore for performance.
/// This requires that the semaphore MUST outlive all tokens it creates.
///
/// Best Practices:
/// 1. Store semaphore at application/service level
/// 2. Call shutdown() before deallocating semaphore
/// 3. Use debug builds to catch lifetime violations
/// 4. Consider weak references if lifetime cannot be guaranteed
///
/// Example:
/// ```swift
/// class Service {
///     let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 10)
///     
///     func shutdown() async {
///         await semaphore.shutdown()
///     }
/// }
/// ```