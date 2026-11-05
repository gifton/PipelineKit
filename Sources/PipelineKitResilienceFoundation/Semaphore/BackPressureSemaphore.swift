import Foundation
import PipelineKit
import PipelineKitCore

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
    private let waiterTimeout: TimeInterval?
    private let admissionTimeout: Duration?
    private let now: @Sendable () -> Date
    
    // MARK: - State (All Actor-Isolated)
    
    private var availablePermits: Int
    private var activeTokens: Int = 0

    /// Service uses priority then insertion order; eviction uses insertion order alone.
    private var waiters = WaiterQueue()
    private var totalProcessed: Int = 0
    private var cleanupTask: Task<Void, Never>?
    
    // MARK: - Types
    
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<SemaphoreToken, any Error>
        let enqueuedAt: Date
        let priority: QueuePriority
        let estimatedSize: Int
        var timeoutTask: Task<Void, Never>?
    }

    // UUID links maintain FIFO independently of clock changes or ordinal wrap.
    // testCancellationAtEveryQueuePositionPreservesBothOrders exercises removal
    // from each position; timeout, shutdown and grant tests cover the other exits.
    private struct WaiterQueue {
        private struct Entry {
            let waiter: Waiter
            var previous: UUID?
            var next: UUID?
            var priorityPrevious: UUID?
            var priorityNext: UUID?
        }

        private var entries: [UUID: Entry] = [:]
        private var oldestID: UUID?
        private var newestID: UUID?
        private var priorityHeads: [QueuePriority: UUID] = [:]
        private var priorityTails: [QueuePriority: UUID] = [:]

        var count: Int { entries.count }
        var isEmpty: Bool { entries.isEmpty }

        mutating func insert(_ waiter: Waiter) {
            let priorityTail = priorityTails[waiter.priority]
            entries[waiter.id] = Entry(
                waiter: waiter,
                previous: newestID,
                next: nil,
                priorityPrevious: priorityTail,
                priorityNext: nil
            )
            if let newestID { entries[newestID]?.next = waiter.id } else { oldestID = waiter.id }
            if let priorityTail { entries[priorityTail]?.priorityNext = waiter.id } else { priorityHeads[waiter.priority] = waiter.id }
            newestID = waiter.id
            priorityTails[waiter.priority] = waiter.id
        }

        mutating func remove(id: UUID) -> Waiter? {
            guard let entry = entries.removeValue(forKey: id) else { return nil }
            if let previous = entry.previous { entries[previous]?.next = entry.next } else { oldestID = entry.next }
            if let next = entry.next { entries[next]?.previous = entry.previous } else { newestID = entry.previous }
            if let previous = entry.priorityPrevious { entries[previous]?.priorityNext = entry.priorityNext } else { priorityHeads[entry.waiter.priority] = entry.priorityNext }
            if let next = entry.priorityNext { entries[next]?.priorityPrevious = entry.priorityPrevious } else { priorityTails[entry.waiter.priority] = entry.priorityPrevious }
            return entry.waiter
        }

        mutating func extractNext() -> Waiter? {
            // At most four priority heads are inspected; links preserve FIFO ties.
            guard let priority = priorityHeads.keys.max(), let id = priorityHeads[priority] else { return nil }
            return remove(id: id)
        }

        func oldest() -> Waiter? {
            guard let oldestID else { return nil }
            return entries[oldestID]?.waiter
        }

        func allElements() -> [Waiter] { entries.values.map(\.waiter) }
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

    /// A nil outstanding limit retains the legacy ten-times-concurrency default.
    /// Configured admission timeouts must be finite and at most 86400 seconds;
    /// finite nonpositive values permit immediate admission only. Invalid values
    /// fail a precondition. `waiterTimeout` separately bounds legacy queue age.
    public init(
        maxConcurrency: Int,
        maxOutstanding: Int? = nil,
        maxQueueMemory: Int? = nil,
        strategy: BackPressureStrategy = .suspend,
        waiterTimeout: TimeInterval = 300
    ) {
        self.init(
            resolvedConcurrency: maxConcurrency,
            resolvedOutstanding: maxOutstanding ?? Self.saturatingMultiply(maxConcurrency, by: 10),
            maxQueueMemory: maxQueueMemory, strategy: strategy, waiterTimeout: waiterTimeout, now: Date.init
        )
    }

    /// PipelineOptions uses nil for unlimited; the public semaphore initializer
    /// retains its existing ten-times-concurrency default for nil outstanding.
    package init(options: PipelineOptions, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(
            resolvedConcurrency: options.maxConcurrency ?? Int.max,
            resolvedOutstanding: options.maxOutstanding ?? Int.max,
            maxQueueMemory: options.maxQueueMemory,
            strategy: options.backPressureStrategy, waiterTimeout: nil, now: now
        )
    }

    private init(
        resolvedConcurrency: Int, resolvedOutstanding: Int,
        maxQueueMemory: Int?, strategy: BackPressureStrategy, waiterTimeout: TimeInterval?,
        now: @escaping @Sendable () -> Date
    ) {
        self.maxConcurrency = resolvedConcurrency
        self.maxOutstanding = resolvedOutstanding
        self.maxQueueMemory = maxQueueMemory
        self.strategy = strategy
        self.waiterTimeout = waiterTimeout
        self.now = now
        if case .error(let timeout) = strategy {
            self.admissionTimeout = Self.normalizeTimeout(timeout)
        } else {
            self.admissionTimeout = nil
        }
        self.availablePermits = resolvedConcurrency
    }

    /// Matches the bulkhead queue timeout contract. Nonpositive finite values
    /// allow immediate admission only; unsupported values fail at the boundary.
    private static func normalizeTimeout(_ timeout: TimeInterval?) -> Duration? {
        guard let timeout else { return nil }
        precondition(
            timeout.isFinite && timeout <= 86_400,
            "Back-pressure admission timeout must be finite and no greater than 86400 seconds"
        )
        return timeout <= 0 ? .zero : .seconds(timeout)
    }

    // Saturation preserves a representable upper bound for the legacy Int stats.
    // testCapacityArithmeticBoundaries covers both multipliers and summed sizes.
    static func saturatingMultiply(_ value: Int, by multiplier: Int) -> Int {
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow ? Int.max : result
    }

    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : result
    }

    deinit {
        cleanupTask?.cancel()
    }
    
    /// Start the cleanup task after initialization
    private func startCleanupTask() {
        guard waiterTimeout != nil else { return }
        if cleanupTask == nil {
            cleanupTask = Task { [weak self] in
                // Lifecycle: the strong reference to the actor must be scoped
                // to each sweep and NEVER held across the sleep. The previous
                // shape — `await self?.runCleanupLoop()` with the loop inside
                // an actor method — upgraded the weak capture to a strong one
                // for the duration of that never-returning call, so the task
                // retained the actor forever, `deinit` (which cancels this
                // task) could never run, and every semaphore that ran acquire()
                // leaked itself plus a once-per-second timer task. With the
                // loop out here, the actor can deinit while we sleep; deinit
                // cancels this task, the sleep throws, and the loop exits.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    guard let self else { return }
                    await self.cleanupExpiredWaiters()
                }
            }
        }
    }
    
    // MARK: - Core Operations
    
    /// Acquires a permit, applying the configured `.error(timeout:)` admission
    /// deadline. The deadline ends at acquisition and never covers handler work.
    public func acquire(
        priority: QueuePriority = .normal,
        estimatedSize: Int = 1024
    ) async throws -> SemaphoreToken {
        let timeoutValue: TimeInterval?
        if case .error(let timeout) = strategy { timeoutValue = timeout }
        else { timeoutValue = nil }
        return try await acquire(
            waitTimeout: admissionTimeout, timeoutValue: timeoutValue,
            priority: priority, estimatedSize: estimatedSize
        )
    }

    /// Acquires with an explicit admission deadline, overriding the strategy's
    /// timeout. Finite nonpositive values permit immediate admission only.
    /// Nonfinite values or values above 86400 seconds fail a precondition.
    public func acquire(
        timeout: TimeInterval,
        priority: QueuePriority = .normal,
        estimatedSize: Int = 1024
    ) async throws -> SemaphoreToken? {
        try await acquire(
            waitTimeout: Self.normalizeTimeout(timeout), timeoutValue: timeout,
            priority: priority, estimatedSize: estimatedSize
        )
    }

    private func acquire(
        waitTimeout: Duration?, timeoutValue: TimeInterval?,
        priority: QueuePriority, estimatedSize: Int
    ) async throws -> SemaphoreToken {
        try PipelineCancellation.check(message: "Semaphore acquisition cancelled")
        startCleanupTask()

        if availablePermits > 0 && waiters.isEmpty && activeTokens < maxOutstanding {
            availablePermits -= 1
            activeTokens += 1
            totalProcessed = Self.saturatingAdd(totalProcessed, 1)
            return SemaphoreToken(asyncReleaseHandler: { [weak self] in await self?.release() })
        }

        let estimatedSize = max(0, estimatedSize)
        if let waitTimeout, let timeoutValue, waitTimeout <= .zero {
            throw PipelineError.backPressure(reason: .timeout(duration: timeoutValue))
        }

        let waiterID = UUID()
        let token: SemaphoreToken = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Handles cancellation before this continuation registers, including
                // cancellation whose handler already attempted removal.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: PipelineError.cancelled(context: "Semaphore acquisition cancelled"))
                    return
                }
                do {
                    let evictedID = try planQueueAdmission(estimatedSize: estimatedSize)
                    var waiter = Waiter(
                        id: waiterID, continuation: continuation, enqueuedAt: now(),
                        priority: priority, estimatedSize: estimatedSize
                    )
                    if let waitTimeout, let timeoutValue {
                        let deadline = ContinuousClock.now.advanced(by: waitTimeout)
                        waiter.timeoutTask = Task { [weak self] in
                            do { try await Task.sleep(until: deadline, clock: .continuous) }
                            catch { return }
                            await self?.timeoutWaiter(waiterID, duration: timeoutValue)
                        }
                    }
                    // Eligibility checks precede the replacement's first mutation;
                    // plan, eviction and registration share this actor turn.
                    if let evictedID, let evicted = waiters.remove(id: evictedID) {
                        evicted.timeoutTask?.cancel()
                        evicted.continuation.resume(throwing:
                            PipelineError.backPressure(reason: .commandDropped(reason: "Dropped to make room"))
                        )
                    }
                    insertWaiter(waiter)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelWaiter(waiterID) }
        }

        // A grant can win the actor turn before cancellation removal. Returning
        // that token here conserves its permit; the token release is idempotent.
        if Task.isCancelled {
            await token.releaseAndWait()
            throw PipelineError.cancelled(context: "Semaphore acquisition cancelled")
        }
        return token
    }

    private func timeoutWaiter(_ waiterID: UUID, duration: TimeInterval) {
        guard let waiter = waiters.remove(id: waiterID) else { return }
        waiter.continuation.resume(throwing: PipelineError.backPressure(reason: .timeout(duration: duration)))
    }

    /// Attempts to acquire without waiting.
    public func tryAcquire() -> SemaphoreToken? {
        guard availablePermits > 0 && waiters.isEmpty && activeTokens < maxOutstanding else {
            return nil
        }
        
        availablePermits -= 1
        activeTokens += 1
        totalProcessed = Self.saturatingAdd(totalProcessed, 1)
        
        return SemaphoreToken(asyncReleaseHandler: { [weak self] in await self?.release() })
    }
    
    /// Releases a permit, potentially resuming a waiter.
    private func release() {
        activeTokens -= 1
        
        // Process next waiter if any
        if let waiter = extractNextWaiter() {
            waiter.timeoutTask?.cancel()
            activeTokens += 1
            let token = SemaphoreToken(asyncReleaseHandler: { [weak self] in await self?.release() })
            waiter.continuation.resume(returning: token)
        } else {
            // No waiters, restore permit
            availablePermits += 1
        }
    }
    
    // MARK: - Queue Management
    
    private func insertWaiter(_ waiter: Waiter) {
        waiters.insert(waiter)
    }

    private func extractNextWaiter() -> Waiter? {
        waiters.extractNext()
    }

    /// Cancels a specific waiter by ID, removing it before resuming to prevent double-resume.
    private func cancelWaiter(_ waiterID: UUID) {
        // Remove FIRST to prevent double-resume if release() is called concurrently.
        // `remove(id:)` returns the waiter only if it was still queued; if it was
        // already handed off by release(), it returns nil and no action is needed.
        if let waiter = waiters.remove(id: waiterID) {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(throwing: PipelineError.cancelled(context: "Semaphore acquisition cancelled"))
        }
    }
    
    // testNoWaitAcquisitionDoesNotEvictRegisteredWaiter and
    // testDropOldestChecksReplacementMemoryBeforeEvicting cover rejected replacements.
    private func planQueueAdmission(estimatedSize: Int) throws -> UUID? {
        var evictedID: UUID?
        // Check if adding this new waiter would exceed the limit
        let totalOutstanding = Self.saturatingAdd(activeTokens, waiters.count)
        let proposedOutstanding = Self.saturatingAdd(totalOutstanding, 1)
        
        if totalOutstanding >= maxOutstanding {
            switch strategy {
            case .suspend, .error:
                throw PipelineError.backPressure(reason: .queueFull(
                    current: proposedOutstanding, limit: maxOutstanding
                ))

            case .dropOldest:
                guard totalOutstanding == maxOutstanding, let oldest = waiters.oldest() else {
                    throw PipelineError.backPressure(reason: .queueFull(
                        current: proposedOutstanding, limit: maxOutstanding
                    ))
                }
                evictedID = oldest.id
                
            case .dropNewest:
                throw PipelineError.backPressure(reason: .commandDropped(
                    reason: "Queue at capacity"
                ))
            }
        }
        
        // Check memory limit
        if let maxMemory = maxQueueMemory {
            // Sum retained waiters directly: subtracting from saturated totals
            // could hide overflow and understate prospective memory.
            let currentMemory = waiters.allElements().reduce(0) { total, waiter in
                waiter.id == evictedID ? total : Self.saturatingAdd(total, waiter.estimatedSize)
            }
            if currentMemory > maxMemory || estimatedSize > maxMemory - currentMemory {
                throw PipelineError.backPressure(reason: .memoryPressure)
            }
        }
        return evictedID
    }
    
    // MARK: - Cleanup

    func cleanupExpiredWaiters() {
        // PipelineOptions has no legacy age limit. Its deadline is owned solely
        // by each waiter (testPipelineOptionsDoNotInheritLegacyFiveMinuteCleanup).
        guard let waiterTimeout else { return }
        let now = now()
        // Snapshot the queue so removals do not mutate the collection being read.
        // `now.timeIntervalSince(enqueuedAt)` is positive for
        // waiters that enqueued in the past, so this fires once the wait exceeds
        // `waiterTimeout`.
        let expired = waiters.allElements().filter {
            now.timeIntervalSince($0.enqueuedAt) > waiterTimeout
        }
        for waiter in expired {
            // Remove ownership before resuming the continuation.
            if let removed = waiters.remove(id: waiter.id) {
                removed.timeoutTask?.cancel()
                removed.continuation.resume(throwing:
                    PipelineError.backPressure(reason: .timeout(duration: waiterTimeout))
                )
            }
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
            totalOutstanding: Self.saturatingAdd(activeTokens, waiters.count),
            queueMemoryUsage: waiters.allElements().reduce(0) { Self.saturatingAdd($0, $1.estimatedSize) },
            oldestWaiterAge: waiters.oldest().map { max(0, now().timeIntervalSince($0.enqueuedAt)) }
        )
    }

    /// Alias property for `getStats()`.
    public var stats: SemaphoreStats { getStats() }
    
    public func healthCheck() -> SemaphoreHealth {
        let stats = getStats()
        let queueUtilization = maxOutstanding > 0
            ? Double(stats.queuedOperations) / Double(maxOutstanding) : 0
        let memoryUtilization = maxQueueMemory.map {
            $0 > 0 ? Double(stats.queueMemoryUsage) / Double($0) : 0
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
        // Resuming a snapshot keeps both ordering indexes intact until reset.
        for waiter in waiters.allElements() {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(throwing: shutdownError)
        }
        waiters = WaiterQueue()

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
    /// Int.max represents an unlimited PipelineOptions concurrency limit.
    public let maxConcurrency: Int
    /// Int.max represents an unlimited or saturated outstanding bound.
    public let maxOutstanding: Int
    public let availableResources: Int
    public let activeOperations: Int
    public let queuedOperations: Int
    public let totalOutstanding: Int
    /// Sum of nonnegative estimates, saturated at Int.max.
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
