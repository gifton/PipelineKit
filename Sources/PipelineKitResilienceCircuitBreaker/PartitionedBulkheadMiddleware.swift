import Foundation
import PipelineKit
import PipelineKitCore

/// Advanced bulkhead middleware with partition-based isolation.
///
/// This middleware provides more granular resource isolation by partitioning
/// resources based on command characteristics, priorities, or tenant IDs.
///
/// ## Features
/// - Partition-based resource allocation
/// - Dynamic partition sizing
/// - Priority-aware scheduling
/// - Tenant isolation
/// - Adaptive capacity management
///
/// ## Example Usage
/// ```swift
/// // Partition by command type
/// let middleware = PartitionedBulkheadMiddleware(
///     partitions: [
///         "critical": PartitionConfig(capacity: 20, queueSize: 100),
///         "standard": PartitionConfig(capacity: 10, queueSize: 50),
///         "background": PartitionConfig(capacity: 5, queueSize: 20)
///     ],
///     partitionExtractor: { command, context in
///         if let priority = command as? PriorityCommand {
///             return priority.priority == .critical ? "critical" : "standard"
///         }
///         return "standard"
///     }
/// )
/// ```
public struct PartitionedBulkheadMiddleware: Middleware {
    /// Runs in the `.resilience` priority band, alongside circuit breakers, retries,
    /// and timeouts.
    public let priority: ExecutionPriority = .resilience

    // MARK: - Configuration

    /// Capacity and queueing limits for a single named partition.
    public struct PartitionConfig: Sendable {
        /// Maximum number of commands this partition executes concurrently before
        /// new arrivals must borrow, queue, or be rejected.
        public let capacity: Int

        /// Maximum number of commands this partition will hold in its wait queue
        /// once `capacity` is exhausted and borrowing is unavailable. `0` (the
        /// default) disables queueing for this partition: `execute(_:context:next:)`
        /// borrows or rejects instead.
        public let queueSize: Int

        /// Maximum time, in seconds, a queued command waits for capacity before
        /// `execute(_:context:next:)` throws `PipelineError.bulkheadTimeout`.
        /// `nil` (the default) means a queued command waits indefinitely.
        public let queueTimeout: TimeInterval?

        /// Stored on the config but not read anywhere else in this file — reserved
        /// for future adaptive capacity management and currently has no effect on
        /// borrowing, queueing, or rejection behavior.
        public let adaptiveScaling: Bool

        /// Creates a partition configuration.
        ///
        /// - Parameters:
        ///   - capacity: Maximum concurrent commands for this partition.
        ///   - queueSize: Maximum queued commands once `capacity` is exhausted.
        ///     `0` disables queueing. Defaults to `0`.
        ///   - queueTimeout: Maximum wait time, in seconds, for a queued command.
        ///     `nil` means no timeout. Defaults to `nil`.
        ///   - adaptiveScaling: Currently unused; reserved for future use. Defaults
        ///     to `false`.
        public init(
            capacity: Int,
            queueSize: Int = 0,
            queueTimeout: TimeInterval? = nil,
            adaptiveScaling: Bool = false
        ) {
            self.capacity = capacity
            self.queueSize = queueSize
            self.queueTimeout = queueTimeout
            self.adaptiveScaling = adaptiveScaling
        }
    }

    /// Overall configuration: the named partitions, how commands are routed to
    /// them, and the cross-partition borrowing and metrics policy.
    public struct Configuration: Sendable {
        /// The named partitions, keyed by the string `partitionExtractor` (or
        /// `defaultPartition`) resolves to.
        public let partitions: [String: PartitionConfig]

        /// Computes the partition key for a command. Non-throwing: it cannot fail,
        /// so `execute(_:context:next:)` never rejects a command because of
        /// extraction — it only falls back to `defaultPartition` when the returned
        /// key has no entry in `partitions`.
        public let partitionExtractor: @Sendable (any Command, CommandContext) async -> String

        /// The partition used when `partitionExtractor` returns a key that has no
        /// entry in `partitions`. If `defaultPartition` itself is not a key in
        /// `partitions`, `execute(_:context:next:)` throws
        /// `PipelineError.bulkheadRejected(reason:)` reporting an unknown partition.
        public let defaultPartition: String

        /// Whether `execute(_:context:next:)` may borrow spare capacity from other
        /// partitions when a command's own partition is full (see
        /// `maxBorrowPercentage`).
        public let allowBorrowing: Bool

        /// The fraction (`0.0`–`1.0`) of a lending partition's capacity that is
        /// reserved for that partition's own commands and never lent out.
        ///
        /// Despite the property name, this is a *reservation*, not a borrowing cap:
        /// a candidate partition may lend from `capacity - activeCount -
        /// (capacity * maxBorrowPercentage)` of its capacity, so with the default
        /// `0.2`, up to ~80% of an otherwise-idle partition's capacity can be lent
        /// to other partitions, not 20%.
        public let maxBorrowPercentage: Double

        /// Whether `execute(_:context:next:)` records per-partition context
        /// metadata and emits `middleware.partitioned_bulkhead_execution` /
        /// `middleware.partitioned_bulkhead_rejected` events.
        public let emitMetrics: Bool

        /// Creates a partitioned-bulkhead configuration.
        ///
        /// - Parameters:
        ///   - partitions: The named partitions.
        ///   - partitionExtractor: Computes the partition key for a command.
        ///   - defaultPartition: The fallback partition when the extracted key is
        ///     not in `partitions`. Defaults to `"default"`. Must itself be a key
        ///     in `partitions` for commands to succeed when they fall back to it.
        ///   - allowBorrowing: Whether to allow borrowing capacity from other
        ///     partitions. Defaults to `true`.
        ///   - maxBorrowPercentage: The fraction of a lending partition's capacity
        ///     reserved for its own use (see the property documentation for the
        ///     resulting lendable share). Defaults to `0.2`.
        ///   - emitMetrics: Whether to record context metadata and emit middleware
        ///     events. Defaults to `true`.
        public init(
            partitions: [String: PartitionConfig],
            partitionExtractor: @escaping @Sendable (any Command, CommandContext) async -> String,
            defaultPartition: String = "default",
            allowBorrowing: Bool = true,
            maxBorrowPercentage: Double = 0.2,
            emitMetrics: Bool = true
        ) {
            self.partitions = partitions
            self.partitionExtractor = partitionExtractor
            self.defaultPartition = defaultPartition
            self.allowBorrowing = allowBorrowing
            self.maxBorrowPercentage = maxBorrowPercentage
            self.emitMetrics = emitMetrics
        }
    }

    // MARK: - Helper Types
    
    private struct ExecutionMetrics {
        let startTime: Date
        let partitionKey: String
        let wasBorrowed: Bool
        let borrowedFrom: String?
        let wasQueued: Bool
        let queueTime: TimeInterval?
    }
    
    private let configuration: Configuration
    private let partitionManager: PartitionManager

    /// Creates the middleware from a full `Configuration`.
    ///
    /// - Parameter configuration: The partitions, routing, and borrowing/metrics
    ///   policy to use.
    public init(configuration: Configuration) {
        self.configuration = configuration
        self.partitionManager = PartitionManager(configuration: configuration)
    }

    /// Convenience initializer that builds a `Configuration` from just the
    /// partitions and extractor, using default values (borrowing enabled,
    /// `maxBorrowPercentage` `0.2`, `defaultPartition` `"default"`, metrics
    /// enabled) for everything else.
    ///
    /// - Parameters:
    ///   - partitions: The named partitions. Must include a `"default"` entry (or
    ///     whatever `partitionExtractor` may fall back to) for commands whose
    ///     extracted key is unrecognized to succeed.
    ///   - partitionExtractor: Computes the partition key for a command.
    public init(
        partitions: [String: PartitionConfig],
        partitionExtractor: @escaping @Sendable (any Command, CommandContext) async -> String
    ) {
        self.init(
            configuration: Configuration(
                partitions: partitions,
                partitionExtractor: partitionExtractor
            )
        )
    }

    // MARK: - Middleware Implementation

    /// Routes the command to a partition, acquires (immediately, by borrowing, or
    /// by queueing) that partition's capacity, then executes the command.
    ///
    /// The partition key comes from `Configuration.partitionExtractor`; if the
    /// returned key has no entry in `Configuration.partitions`,
    /// `Configuration.defaultPartition` is used instead. The resolved key is
    /// always recorded as `"bulkheadPartition"` context metadata, regardless of
    /// `Configuration.emitMetrics`.
    ///
    /// Acquisition then proceeds through, in order:
    /// 1. **Immediate**: the partition has spare capacity (`activeCount <
    ///    capacity`) — the command runs right away.
    /// 2. **Borrowed** (only if `Configuration.allowBorrowing` is `true`): another
    ///    partition has capacity available to lend (see
    ///    `Configuration.maxBorrowPercentage`) — the command runs using that
    ///    partition's slot, and the slot is released back to the lending
    ///    partition afterward.
    /// 3. **Queued** (only if the partition's `PartitionConfig.queueSize` is
    ///    greater than `0` and its queue is not full): the command waits for a
    ///    slot in its own partition to free up, up to
    ///    `PartitionConfig.queueTimeout` if one is set.
    /// 4. **Rejected**: none of the above apply — the partition is at capacity,
    ///    borrowing is disabled or unavailable, and the partition cannot queue
    ///    (no queue configured, or the queue is full).
    ///
    /// A rejection increments the partition's `PartitionStats.totalRejections`
    /// and, when `Configuration.emitMetrics` is `true`, emits a
    /// `middleware.partitioned_bulkhead_rejected` event before throwing.
    ///
    /// Once a slot is acquired (immediately, borrowed, or after a successful
    /// wait), the command runs via `next`; its result or thrown error propagates
    /// unchanged. The acquired slot is released, and (when
    /// `Configuration.emitMetrics` is `true`) a
    /// `middleware.partitioned_bulkhead_execution` event is emitted, from an
    /// un-awaited `Task` scheduled in a `defer` block — both happen after this
    /// method has already returned or thrown, not before.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - context: The command context. Always receives a `"bulkheadPartition"`
    ///     metadata entry; when `Configuration.emitMetrics` is `true`, also
    ///     receives `"bulkhead.partition"`, `"bulkhead.duration"`,
    ///     `"bulkhead.wasBorrowed"`, `"bulkhead.wasQueued"`, and (when queued)
    ///     `"bulkhead.queueTime"` entries after the command completes.
    ///   - next: The next step in the middleware chain.
    /// - Returns: The result produced by `next`.
    /// - Throws: `PipelineError.bulkheadRejected(reason:)` if the resolved
    ///   partition (or `Configuration.defaultPartition`, if resolution fell back
    ///   to it) has no matching entry in `Configuration.partitions`, if the queue
    ///   is full when a queued wait actually begins, or if the partition is at
    ///   capacity with no available borrowing or queueing; `PipelineError
    ///   .bulkheadTimeout(timeout:queueTime:)` if a queued command's wait exceeds
    ///   `PartitionConfig.queueTimeout`; otherwise, whatever error `next` throws.
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let startTime = Date()

        // Determine partition
        let partitionKey = await configuration.partitionExtractor(command, context)
        let effectiveKey = configuration.partitions[partitionKey] != nil
            ? partitionKey
            : configuration.defaultPartition

        // Store partition info in context
        context.setMetadata("bulkheadPartition", value: effectiveKey)

        // Try to acquire resources from partition
        let acquisition = try await partitionManager.acquire(
            partitionKey: effectiveKey,
            command: command
        )

        switch acquisition {
        case let .immediate(release):
            // Execute immediately
            return try await executeWithRelease(
                command,
                context: context,
                next: next,
                release: release,
                startTime: startTime,
                partitionKey: effectiveKey,
                wasBorrowed: false
            )

        case let .borrowed(release, fromPartition):
            // Execute with borrowed capacity
            return try await executeWithRelease(
                command,
                context: context,
                next: next,
                release: release,
                startTime: startTime,
                partitionKey: effectiveKey,
                wasBorrowed: true,
                borrowedFrom: fromPartition
            )

        case let .queued(future):
            // Wait for resource to become available
            let queueStartTime = Date()

            do {
                let release = try await future()

                let queueTime = Date().timeIntervalSince(queueStartTime)
                await partitionManager.recordQueueTime(
                    partition: effectiveKey,
                    time: queueTime
                )

                return try await executeWithRelease(
                    command,
                    context: context,
                    next: next,
                    release: release,
                    startTime: startTime,
                    partitionKey: effectiveKey,
                    wasQueued: true,
                    queueTime: queueTime
                )
            } catch {
                await partitionManager.recordTimeout(partition: effectiveKey)
                throw error
            }

        case .rejected:
            // Handle rejection
            await partitionManager.recordRejection(partition: effectiveKey)

            if configuration.emitMetrics {
                await context.emitMiddlewareEvent(
                    "middleware.partitioned_bulkhead_rejected",
                    middleware: "PartitionedBulkheadMiddleware",
                    properties: [
                        "commandType": String(describing: type(of: command)),
                        "partition": effectiveKey
                    ]
                )
            }

            throw PipelineError.bulkheadRejected(
                reason: "Partition '\(effectiveKey)' is at capacity and queue is full"
            )
        }
    }

    // MARK: - Private Methods

    private func executeWithRelease<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>,
        release: @escaping @Sendable () async -> Void,
        startTime: Date,
        partitionKey: String,
        wasBorrowed: Bool = false,
        borrowedFrom: String? = nil,
        wasQueued: Bool = false,
        queueTime: TimeInterval? = nil
    ) async throws -> T.Result {
        defer {
            Task {
                await release()
                await emitExecutionMetrics(
                    context: context,
                    metrics: ExecutionMetrics(
                        startTime: startTime,
                        partitionKey: partitionKey,
                        wasBorrowed: wasBorrowed,
                        borrowedFrom: borrowedFrom,
                        wasQueued: wasQueued,
                        queueTime: queueTime
                    )
                )
            }
        }

        return try await next(command, context)
    }

    private func emitExecutionMetrics(
        context: CommandContext,
        metrics: ExecutionMetrics
    ) async {
        guard configuration.emitMetrics else { return }

        let duration = Date().timeIntervalSince(metrics.startTime)
        _ = await partitionManager.getStats(for: metrics.partitionKey)

        context.setMetadata("bulkhead.partition", value: metrics.partitionKey)
        context.setMetadata("bulkhead.duration", value: duration)
        context.setMetadata("bulkhead.wasBorrowed", value: metrics.wasBorrowed)
        context.setMetadata("bulkhead.wasQueued", value: metrics.wasQueued)

        if let queueTime = metrics.queueTime {
            context.setMetadata("bulkhead.queueTime", value: queueTime)
        }

        await context.emitMiddlewareEvent(
            "middleware.partitioned_bulkhead_execution",
            middleware: "PartitionedBulkheadMiddleware",
            properties: [
                "partition": metrics.partitionKey as any Sendable,
                "wasBorrowed": metrics.wasBorrowed as any Sendable,
                "borrowedFrom": (metrics.borrowedFrom ?? "") as any Sendable,
                "wasQueued": metrics.wasQueued as any Sendable,
                "queueTime": (metrics.queueTime ?? 0) as any Sendable,
                "duration": duration as any Sendable
            ]
        )
    }
}

// MARK: - Partition Manager

private actor PartitionManager {
    private let configuration: PartitionedBulkheadMiddleware.Configuration
    private var partitions: [String: Partition] = [:]

    init(configuration: PartitionedBulkheadMiddleware.Configuration) {
        self.configuration = configuration

        // Initialize partitions
        for (key, config) in configuration.partitions {
            partitions[key] = Partition(
                name: key,
                config: config
            )
        }
    }

    enum ResourceAcquisition {
        case immediate(release: @Sendable () async -> Void)
        case borrowed(release: @Sendable () async -> Void, fromPartition: String)
        case queued(future: @Sendable () async throws -> @Sendable () async -> Void)
        case rejected
    }

    func acquire(
        partitionKey: String,
        command: any Command
    ) async throws -> ResourceAcquisition {
        guard let partition = partitions[partitionKey] else {
            throw PipelineError.bulkheadRejected(
                reason: "Unknown partition: \(partitionKey)"
            )
        }

        // Try immediate acquisition
        if await partition.tryAcquire() {
            return .immediate(release: { [weak self] in
                await self?.partitions[partitionKey]?.release()
            })
        }

        // Try borrowing from other partitions if allowed
        if configuration.allowBorrowing {
            if let borrowed = await tryBorrow(
                requestingPartition: partitionKey,
                command: command
            ) {
                return borrowed
            }
        }

        // Try queueing if space available
        if await partition.canQueue() {
            let future: @Sendable () async throws -> @Sendable () async -> Void = {
                try await partition.waitForResource()
                return { [weak partition] in
                    await partition?.release()
                }
            }
            return .queued(future: future)
        }

        return .rejected
    }

    private func tryBorrow(
        requestingPartition: String,
        command: any Command
    ) async -> ResourceAcquisition? {
        // Find partitions with available capacity
        for (key, partition) in partitions where key != requestingPartition {
            let stats = await partition.getStats()
            let borrowableCapacity = Int(Double(stats.capacity) * configuration.maxBorrowPercentage)
            let availableForBorrowing = stats.capacity - stats.activeCount - borrowableCapacity

            if availableForBorrowing > 0 {
                let acquired = await partition.tryAcquire()
                if acquired {
                    return .borrowed(
                        release: { [weak self] in
                            await self?.partitions[key]?.release()
                        },
                        fromPartition: key
                    )
                }
            }
        }

        return nil
    }

    func recordQueueTime(partition: String, time: TimeInterval) async {
        await partitions[partition]?.recordQueueTime(time)
    }

    func recordTimeout(partition: String) async {
        await partitions[partition]?.recordTimeout()
    }

    func recordRejection(partition: String) async {
        await partitions[partition]?.recordRejection()
    }

    func getStats(for partition: String) async -> PartitionStats {
        await partitions[partition]?.getStats() ?? PartitionStats(
            name: partition,
            capacity: 0,
            activeCount: 0,
            queuedCount: 0,
            totalExecutions: 0,
            totalRejections: 0,
            averageQueueTime: 0
        )
    }
}

// MARK: - Partition

private actor Partition {
    let name: String
    let config: PartitionedBulkheadMiddleware.PartitionConfig

    private var activeCount = 0
    private var queuedCount = 0
    private var totalExecutions = 0
    private var totalRejections = 0
    private var totalTimeouts = 0
    private var queueTimes: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, (any Error)>] = []

    init(name: String, config: PartitionedBulkheadMiddleware.PartitionConfig) {
        self.name = name
        self.config = config
    }

    func tryAcquire() -> Bool {
        if activeCount < config.capacity {
            activeCount += 1
            totalExecutions += 1
            return true
        }
        return false
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            queuedCount -= 1
            waiter.resume()
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }

    func canQueue() -> Bool {
        config.queueSize > 0 && queuedCount < config.queueSize
    }

    func waitForResource() async throws {
        guard canQueue() else {
            throw PipelineError.bulkheadRejected(
                reason: "Queue is full for partition '\(name)'"
            )
        }

        queuedCount += 1

        do {
            if let timeout = config.queueTimeout {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw PipelineError.bulkheadTimeout(
                            timeout: timeout,
                            queueTime: timeout
                        )
                    }

                    group.addTask { [weak self] in
                        try await withCheckedThrowingContinuation { continuation in
                            Task { [weak self] in
                                await self?.addWaiter(continuation)
                            }
                        }
                    }

                    try await group.next()
                    group.cancelAll()
                }
            } else {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(continuation)
                }
            }

            activeCount += 1
            totalExecutions += 1
        } catch {
            // Remove from waiters if still there
            waiters.removeAll { _ in true }
            queuedCount = max(0, queuedCount - 1)
            totalTimeouts += 1
            throw error
        }
    }

    func recordQueueTime(_ time: TimeInterval) {
        queueTimes.append(time)
        if queueTimes.count > 100 {
            queueTimes.removeFirst(50)
        }
    }

    func recordTimeout() {
        totalTimeouts += 1
    }

    func recordRejection() {
        totalRejections += 1
    }

    func getStats() -> PartitionStats {
        let avgQueueTime = queueTimes.isEmpty ? 0 : queueTimes.reduce(0, +) / Double(queueTimes.count)

        return PartitionStats(
            name: name,
            capacity: config.capacity,
            activeCount: activeCount,
            queuedCount: queuedCount,
            totalExecutions: totalExecutions,
            totalRejections: totalRejections,
            averageQueueTime: avgQueueTime
        )
    }

    func addWaiter(_ continuation: CheckedContinuation<Void, any Error>) {
        waiters.append(continuation)
    }
}

// MARK: - Supporting Types

/// A point-in-time snapshot of one partition's capacity usage and counters.
///
/// Constructed internally by the private `PartitionManager`/`Partition` actors;
/// `PartitionedBulkheadMiddleware` does not currently expose a public method that
/// returns one, so this type has no public producer despite being `public`
/// itself.
public struct PartitionStats: Sendable {
    /// The partition's name, as used as a key in `Configuration.partitions`.
    public let name: String

    /// The partition's configured `PartitionConfig.capacity`.
    public let capacity: Int

    /// Commands currently executing against this partition's capacity,
    /// including ones borrowing it on behalf of another partition.
    public let activeCount: Int

    /// Commands currently waiting in this partition's own queue.
    public let queuedCount: Int

    /// Total commands that have acquired a slot in this partition so far —
    /// immediately, after queueing, or by borrowing it on behalf of another
    /// partition. Never decremented.
    public let totalExecutions: Int

    /// Total commands rejected because this specific partition was at capacity
    /// with no available borrowing or queueing. Never decremented.
    public let totalRejections: Int

    /// Average time, in seconds, commands spent in this partition's queue
    /// before acquiring a slot, computed over up to the last 100 recorded queue
    /// times. `0` if no command has been queued yet.
    public let averageQueueTime: TimeInterval
}
