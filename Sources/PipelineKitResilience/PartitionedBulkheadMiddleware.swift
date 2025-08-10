import Foundation
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
    public let priority: ExecutionPriority = .resilience

    // MARK: - Configuration

    /// Configuration for a single partition
    public struct PartitionConfig: Sendable {
        public let capacity: Int
        public let queueSize: Int
        public let queueTimeout: TimeInterval?
        public let adaptiveScaling: Bool

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

    /// Overall configuration
    public struct Configuration: Sendable {
        /// Partition configurations
        public let partitions: [String: PartitionConfig]

        /// Function to extract partition key from command
        public let partitionExtractor: @Sendable (any Command, CommandContext) async -> String

        /// Default partition name if extraction fails
        public let defaultPartition: String

        /// Whether to allow borrowing capacity from other partitions
        public let allowBorrowing: Bool

        /// Maximum percentage of capacity that can be borrowed
        public let maxBorrowPercentage: Double

        /// Whether to emit detailed metrics
        public let emitMetrics: Bool

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

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.partitionManager = PartitionManager(configuration: configuration)
    }

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

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()

        // Determine partition
        let partitionKey = await configuration.partitionExtractor(command, context)
        let effectiveKey = configuration.partitions[partitionKey] != nil
            ? partitionKey
            : configuration.defaultPartition

        // Store partition info in context
        context.metadata["bulkheadPartition"] = effectiveKey

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
                context.emitMiddlewareEvent(
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
        next: @Sendable (T, CommandContext) async throws -> T.Result,
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

        context.metrics["bulkhead.partition"] = metrics.partitionKey
        context.metrics["bulkhead.duration"] = duration
        context.metrics["bulkhead.wasBorrowed"] = metrics.wasBorrowed
        context.metrics["bulkhead.wasQueued"] = metrics.wasQueued

        if let queueTime = metrics.queueTime {
            context.metrics["bulkhead.queueTime"] = queueTime
        }

        context.emitMiddlewareEvent(
            "middleware.partitioned_bulkhead_execution",
            middleware: "PartitionedBulkheadMiddleware",
            properties: [
                "partition": metrics.partitionKey,
                "wasBorrowed": metrics.wasBorrowed,
                "borrowedFrom": metrics.borrowedFrom ?? "",
                "wasQueued": metrics.wasQueued,
                "queueTime": metrics.queueTime ?? 0,
                "duration": duration
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
    private var waiters: [CheckedContinuation<Void, Error>] = []

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

    func addWaiter(_ continuation: CheckedContinuation<Void, Error>) {
        waiters.append(continuation)
    }
}

// MARK: - Supporting Types

/// Statistics for a single partition
public struct PartitionStats: Sendable {
    public let name: String
    public let capacity: Int
    public let activeCount: Int
    public let queuedCount: Int
    public let totalExecutions: Int
    public let totalRejections: Int
    public let averageQueueTime: TimeInterval
}
