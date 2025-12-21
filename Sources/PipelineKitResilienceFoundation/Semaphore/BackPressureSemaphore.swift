import Foundation
import PipelineKit

/// A high-performance async semaphore with back-pressure control and automatic resource management.
/// 
/// This semaphore provides token-based resource management with configurable back-pressure
/// strategies, queue limits, and memory bounds for controlling concurrent access to resources.
public actor BackPressureSemaphore {
    // MARK: - Configuration
    
    private let maxConcurrency: Int
    private let maxOutstanding: Int
    private let maxQueueMemory: Int?
    private let strategy: BackPressureStrategy
    private let waiterTimeout: TimeInterval
    
    // MARK: - State (All Actor-Isolated)
    
    private var availablePermits: Int
    private var activeTokens: Int = 0
    private var waiters: [Waiter] = []
    private var totalProcessed: Int = 0
    private var cleanupTask: Task<Void, Never>?
    
    // MARK: - Types
    
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<SemaphoreToken, any Error>
        let enqueuedAt: Date
        let priority: QueuePriority
        let estimatedSize: Int
    }
    
    public enum QueuePriority: Int, Comparable, Sendable {
        case low = 0
        case normal = 1
        case high = 2
        case critical = 3
        
        public static func < (lhs: QueuePriority, rhs: QueuePriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    // MARK: - Initialization
    
    public init(
        maxConcurrency: Int,
        maxOutstanding: Int? = nil,
        maxQueueMemory: Int? = nil,
        strategy: BackPressureStrategy = .suspend,
        waiterTimeout: TimeInterval = 300
    ) {
        self.maxConcurrency = maxConcurrency
        self.maxOutstanding = maxOutstanding ?? (maxConcurrency * 10)
        self.maxQueueMemory = maxQueueMemory
        self.strategy = strategy
        self.waiterTimeout = waiterTimeout
        self.availablePermits = maxConcurrency
    }
    
    deinit {
        cleanupTask?.cancel()
    }
    
    /// Start the cleanup task after initialization
    private func startCleanupTask() {
        if cleanupTask == nil {
            cleanupTask = Task { [weak self] in
                await self?.runCleanupLoop()
            }
        }
    }
    
    // MARK: - Core Operations
    
    /// Acquires a permit, waiting if necessary.
    public func acquire(
        priority: QueuePriority = .normal,
        estimatedSize: Int = 1024
    ) async throws -> SemaphoreToken {
        // Ensure cleanup task is running
        startCleanupTask()
        
        // Fast path: immediate acquisition
        if availablePermits > 0 && waiters.isEmpty {
            availablePermits -= 1
            activeTokens += 1
            totalProcessed += 1
            
            return SemaphoreToken { [weak self] in
                Task { await self?.release() }
            }
        }
        
        // Check queue limits
        try checkQueueLimits(estimatedSize: estimatedSize)
        
        // Slow path: queue and wait
        // Capture waiter ID before withTaskCancellationHandler for proper cancellation targeting
        let waiterID = UUID()
        let enqueuedAt = Date()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(
                    id: waiterID,
                    continuation: continuation,
                    enqueuedAt: enqueuedAt,
                    priority: priority,
                    estimatedSize: estimatedSize
                )
                insertWaiter(waiter)
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(waiterID)
            }
        }
    }
    
    /// Attempts to acquire with a timeout.
    public func acquire(
        timeout: TimeInterval,
        priority: QueuePriority = .normal,
        estimatedSize: Int = 1024
    ) async throws -> SemaphoreToken? {
        return try await withThrowingTaskGroup(of: SemaphoreToken?.self) { group in
            group.addTask { @Sendable in
                try await self.acquire(priority: priority, estimatedSize: estimatedSize)
            }
            
            group.addTask { @Sendable in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil // Timeout occurred
            }
            
            // Wait for first task to complete
            if let result = try await group.next() {
                group.cancelAll()
                if let token = result {
                    return token
                } else {
                    // Timeout occurred
                    throw PipelineError.backPressure(reason: .timeout(duration: timeout))
                }
            }
            
            return nil
        }
    }
    
    /// Attempts to acquire without waiting.
    public func tryAcquire() -> SemaphoreToken? {
        guard availablePermits > 0 && waiters.isEmpty else {
            return nil
        }
        
        availablePermits -= 1
        activeTokens += 1
        totalProcessed += 1
        
        return SemaphoreToken { [weak self] in
            Task { await self?.release() }
        }
    }
    
    /// Releases a permit, potentially resuming a waiter.
    private func release() {
        activeTokens -= 1
        
        // Process next waiter if any
        if let waiter = extractNextWaiter() {
            activeTokens += 1
            let token = SemaphoreToken { [weak self] in
                Task { await self?.release() }
            }
            waiter.continuation.resume(returning: token)
        } else {
            // No waiters, restore permit
            availablePermits += 1
        }
    }
    
    // MARK: - Queue Management
    
    private func insertWaiter(_ waiter: Waiter) {
        // Insert sorted by priority and time
        let index = waiters.firstIndex { existing in
            if waiter.priority > existing.priority {
                return true
            } else if waiter.priority == existing.priority {
                return waiter.enqueuedAt < existing.enqueuedAt
            }
            return false
        } ?? waiters.endIndex
        
        waiters.insert(waiter, at: index)
    }
    
    private func extractNextWaiter() -> Waiter? {
        guard !waiters.isEmpty else { return nil }
        return waiters.removeFirst()
    }

    /// Cancels a specific waiter by ID, removing it before resuming to prevent double-resume.
    private func cancelWaiter(_ waiterID: UUID) {
        // Find and remove the waiter, then resume with cancellation error
        // Remove FIRST to prevent double-resume if release() is called concurrently
        if let index = waiters.firstIndex(where: { $0.id == waiterID }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
        // If waiter not found, it was already processed by release() - no action needed
    }
    
    private func checkQueueLimits(estimatedSize: Int) throws {
        // Check if adding this new waiter would exceed the limit
        let totalOutstanding = activeTokens + waiters.count
        
        if totalOutstanding + 1 > maxOutstanding {
            switch strategy {
            case .suspend:
                // Allow 2x for suspend strategy
                if totalOutstanding + 1 > maxOutstanding * 2 {
                    throw PipelineError.backPressure(reason: .queueFull(
                        current: totalOutstanding + 1,
                        limit: maxOutstanding * 2
                    ))
                }
                
            case .dropOldest:
                if let oldest = waiters.first {
                    waiters.removeFirst()
                    oldest.continuation.resume(throwing:
                        PipelineError.backPressure(reason: .commandDropped(
                            reason: "Dropped to make room"
                        ))
                    )
                }
                
            case .dropNewest:
                throw PipelineError.backPressure(reason: .commandDropped(
                    reason: "Queue at capacity"
                ))
                
            case .error(let timeout):
                if timeout == nil {
                    // No timeout specified, throw immediately
                    throw PipelineError.backPressure(reason: .queueFull(
                        current: totalOutstanding + 1,
                        limit: maxOutstanding
                    ))
                }
                // If timeout specified, let it queue and let the timeout handle the error
            }
        }
        
        // Check memory limit
        if let maxMemory = maxQueueMemory {
            let currentMemory = waiters.reduce(0) { $0 + $1.estimatedSize }
            if currentMemory + estimatedSize > maxMemory {
                throw PipelineError.backPressure(reason: .memoryPressure)
            }
        }
    }
    
    // MARK: - Cleanup
    
    private func runCleanupLoop() async {
        while !Task.isCancelled {
            cleanupExpiredWaiters()
            
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
    }
    
    private func cleanupExpiredWaiters() {
        let now = Date()
        waiters.removeAll { waiter in
            // Fix: now.timeIntervalSince(waiter.enqueuedAt) produces positive values for old waiters
            if now.timeIntervalSince(waiter.enqueuedAt) > waiterTimeout {
                waiter.continuation.resume(throwing:
                    PipelineError.backPressure(reason: .timeout(duration: waiterTimeout))
                )
                return true
            }
            return false
        }
    }
    
    // MARK: - Statistics
    
    public func getStats() -> SemaphoreStats {
        SemaphoreStats(
            maxConcurrency: maxConcurrency,
            maxOutstanding: maxOutstanding,
            availableResources: availablePermits,
            activeOperations: activeTokens,
            queuedOperations: waiters.count,
            totalOutstanding: activeTokens + waiters.count,
            queueMemoryUsage: waiters.reduce(0) { $0 + $1.estimatedSize },
            oldestWaiterAge: waiters.first?.enqueuedAt.timeIntervalSinceNow.magnitude
        )
    }

    /// Alias property for `getStats()`.
    public var stats: SemaphoreStats { getStats() }
    
    public func healthCheck() -> SemaphoreHealth {
        let stats = getStats()
        let queueUtilization = Double(stats.queuedOperations) / Double(maxOutstanding)
        let memoryUtilization = maxQueueMemory.map {
            Double(stats.queueMemoryUsage) / Double($0)
        } ?? 0
        
        let isHealthy = (stats.oldestWaiterAge ?? 0) < 60 &&
                       queueUtilization < 0.8 &&
                       memoryUtilization < 0.8
        
        return SemaphoreHealth(
            isHealthy: isHealthy,
            queueUtilization: queueUtilization,
            memoryUtilization: memoryUtilization,
            oldestWaiterAge: stats.oldestWaiterAge ?? 0
        )
    }
    
    // MARK: - Shutdown
    
    public func shutdown(error: (any Error)? = nil) {
        cleanupTask?.cancel()
        
        let shutdownError = error ?? PipelineError.semaphoreShutdown
        for waiter in waiters {
            waiter.continuation.resume(throwing: shutdownError)
        }
        waiters.removeAll()
        
        // Note: Active tokens will release naturally
    }
}

// MARK: - Supporting Types

/// Extended back-pressure errors.
extension PipelineError {
    /// The semaphore was shut down while operations were pending.
    static let semaphoreShutdown = PipelineError.backPressure(reason: .commandDropped(
        reason: "Semaphore shut down with pending operations"
    ))
}

/// Statistics about the semaphore's current state.
@frozen
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

/// Health status for monitoring the semaphore.
@frozen
public struct SemaphoreHealth: Sendable {
    public let isHealthy: Bool
    public let queueUtilization: Double
    public let memoryUtilization: Double
    public let oldestWaiterAge: TimeInterval
}
