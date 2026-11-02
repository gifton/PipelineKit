import Foundation
import PipelineKit
import PipelineKitCore
import _ResilienceFoundation

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
        /// borrows or rejects instead, except a nonpositive `queueTimeout`
        /// reports an admission timeout when no immediate slot is available.
        public let queueSize: Int

        /// Maximum time, in seconds, a queued command waits for capacity before
        /// `execute(_:context:next:)` throws `PipelineError.bulkheadTimeout`.
        /// `nil` (the default) means an unbounded admission wait. Finite
        /// nonpositive values allow immediate admission but do not wait. Positive
        /// values must be finite and at most 86,400 seconds (24 hours), a library
        /// policy rather than Swift Duration's intrinsic limit. Other values
        /// fail a configuration precondition during middleware initialization.
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
        /// `reservedCapacityPercentage`).
        public let allowBorrowing: Bool

        /// The fraction (`0.0`–`1.0`) of a lending partition's capacity that is
        /// reserved for that partition's own commands and never lent out.
        ///
        /// With the default `0.2`, up to ~80% of an otherwise-idle partition's
        /// capacity can be lent to other partitions.
        public let reservedCapacityPercentage: Double

        /// Deprecated alias for ``reservedCapacityPercentage``.
        ///
        /// Despite the historical name, this value has always been the lender's
        /// *reserved* (non-lendable) share, not a borrowing cap — renamed to say
        /// what it does. The semantics are unchanged.
        @available(*, deprecated, renamed: "reservedCapacityPercentage")
        public var maxBorrowPercentage: Double { reservedCapacityPercentage }

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
        ///   - reservedCapacityPercentage: The fraction of a lending partition's
        ///     capacity reserved for its own use (see the property documentation
        ///     for the resulting lendable share). Defaults to `0.2`.
        ///   - emitMetrics: Whether to record context metadata and emit middleware
        ///     events. Defaults to `true`.
        public init(
            partitions: [String: PartitionConfig],
            partitionExtractor: @escaping @Sendable (any Command, CommandContext) async -> String,
            defaultPartition: String = "default",
            allowBorrowing: Bool = true,
            reservedCapacityPercentage: Double = 0.2,
            emitMetrics: Bool = true
        ) {
            self.partitions = partitions
            self.partitionExtractor = partitionExtractor
            self.defaultPartition = defaultPartition
            self.allowBorrowing = allowBorrowing
            self.reservedCapacityPercentage = reservedCapacityPercentage
            self.emitMetrics = emitMetrics
        }

        /// Deprecated: use `init(partitions:partitionExtractor:defaultPartition:allowBorrowing:reservedCapacityPercentage:emitMetrics:)`.
        @available(*, deprecated, message: "maxBorrowPercentage has always been the reserved (non-lendable) share — use reservedCapacityPercentage, which has identical semantics.")
        public init(
            partitions: [String: PartitionConfig],
            partitionExtractor: @escaping @Sendable (any Command, CommandContext) async -> String,
            defaultPartition: String = "default",
            allowBorrowing: Bool = true,
            maxBorrowPercentage: Double,
            emitMetrics: Bool = true
        ) {
            self.init(
                partitions: partitions,
                partitionExtractor: partitionExtractor,
                defaultPartition: defaultPartition,
                allowBorrowing: allowBorrowing,
                reservedCapacityPercentage: maxBorrowPercentage,
                emitMetrics: emitMetrics
            )
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
        self.init(configuration: configuration, admissions: nil)
    }

    /// Package test seam; supplied gates must match every partition's limits.
    package init(configuration: Configuration, admissions: [String: AdmissionGate]?) {
        precondition(
            configuration.reservedCapacityPercentage.isFinite &&
                (0...1).contains(configuration.reservedCapacityPercentage),
            "Partition reserved capacity percentage must be finite and in 0...1"
        )
        if let admissions {
            precondition(Set(admissions.keys) == Set(configuration.partitions.keys), "Admission gates must match partition keys")
        }
        self.configuration = configuration
        self.partitionManager = PartitionManager(configuration: configuration, admissions: admissions)
    }

    /// Convenience initializer that builds a `Configuration` from just the
    /// partitions and extractor, using default values (borrowing enabled,
    /// `reservedCapacityPercentage` `0.2`, `defaultPartition` `"default"`, metrics
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

    /// Package observation seam for admission contract tests.
    package func admissionSnapshot(partition: String = "default") async -> (active: Int, queued: Int) {
        let stats = await partitionManager.getStats(for: partition)
        return (stats.activeCount, stats.queuedCount)
    }

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
    ///    `Configuration.reservedCapacityPercentage`) — the command runs using that
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
    /// unchanged. Release of the actual local or donor lease and (when enabled)
    /// the `middleware.partitioned_bulkhead_execution` event are awaited before
    /// returning or throwing (`testQueuedHandoffTransfersOneLease` and
    /// `testDonorReserveAndQueuePriorityAreAtomic`).
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
    ///   `PartitionConfig.queueTimeout` (also when no wait is allowed and
    ///   capacity is unavailable); otherwise, whatever error `next` throws.
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

        let acquisition = try await partitionManager.acquire(partitionKey: effectiveKey)

        switch acquisition {
        case let .admitted(lease, borrowedFrom):
            let queueTime = lease.wasQueued ? Self.seconds(lease.queueDuration) : nil
            return try await executeWithLease(
                command, context: context, next: next, lease: lease,
                metrics: ExecutionMetrics(
                    startTime: startTime, partitionKey: effectiveKey,
                    wasBorrowed: borrowedFrom != nil, borrowedFrom: borrowedFrom,
                    wasQueued: lease.wasQueued, queueTime: queueTime
                )
            )

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

    private func executeWithLease<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>,
        lease: AdmissionLease,
        metrics: ExecutionMetrics
    ) async throws -> T.Result {
        do {
            try Task.checkCancellation()
            let result = try await next(command, context)
            await lease.release()
            await emitExecutionMetrics(context: context, metrics: metrics)
            return result
        } catch {
            await lease.release()
            await emitExecutionMetrics(context: context, metrics: metrics)
            throw error
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
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

    init(configuration: PartitionedBulkheadMiddleware.Configuration, admissions: [String: AdmissionGate]?) {
        self.configuration = configuration
        for (key, config) in configuration.partitions {
            partitions[key] = Partition(
                name: key, config: config,
                reservedPercentage: configuration.reservedCapacityPercentage,
                admission: admissions?[key]
            )
        }
    }

    enum ResourceAcquisition {
        case admitted(lease: AdmissionLease, borrowedFrom: String?)
        case rejected
    }

    func acquire(partitionKey: String) async throws -> ResourceAcquisition {
        try Task.checkCancellation()
        guard let partition = partitions[partitionKey] else {
            throw PipelineError.bulkheadRejected(reason: "Unknown partition: \(partitionKey)")
        }
        if let lease = await partition.tryAcquire() {
            return .admitted(lease: lease, borrowedFrom: nil)
        }
        if configuration.allowBorrowing {
            for (key, donor) in partitions where key != partitionKey {
                if let lease = await donor.tryAcquire(reservingCapacity: true) {
                    return .admitted(lease: lease, borrowedFrom: key)
                }
            }
        }
        do {
            // The gate rechecks capacity and installs a waiter in one actor turn.
            let lease = try await partition.acquire()
            return .admitted(lease: lease, borrowedFrom: nil)
        } catch AdmissionError.full {
            return .rejected
        }
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

    private let admission: AdmissionGate
    private let admissionTimeout: Duration?
    private let reservedCapacity: Int
    private var totalExecutions = 0
    private var totalRejections = 0
    private var totalTimeouts = 0
    private var queueTimes: [TimeInterval] = []

    init(
        name: String,
        config: PartitionedBulkheadMiddleware.PartitionConfig,
        reservedPercentage: Double,
        admission: AdmissionGate?
    ) {
        precondition(config.capacity > 0, "Partition capacity must be positive")
        precondition(config.queueSize >= 0, "Partition queue size must be nonnegative")
        self.name = name
        self.config = config
        self.admissionTimeout = BulkheadQueueTimeout.normalize(config.queueTimeout)
        self.admission = admission ?? AdmissionGate(capacity: config.capacity, maxQueueSize: config.queueSize)
        let scaledReserve = Double(config.capacity) * reservedPercentage
        // Preserve truncation of the established Double product. At Int.max,
        // Double(capacity) rounds to 2^63; clamp before Int conversion. Covered
        // by testReserveRoundingAndIntegerCapacityBoundaries.
        self.reservedCapacity = scaledReserve >= Double(config.capacity) ? config.capacity : Int(scaledReserve)
    }

    func tryAcquire(reservingCapacity: Bool = false) async -> AdmissionLease? {
        guard let lease = await admission.tryAcquire(reserving: reservingCapacity ? reservedCapacity : 0) else {
            return nil
        }
        totalExecutions += 1
        return lease
    }

    func acquire() async throws -> AdmissionLease {
        let start = ContinuousClock.now
        do {
            let lease = try await admission.acquire(timeout: admissionTimeout)
            totalExecutions += 1
            if lease.wasQueued {
                let components = lease.queueDuration.components
                recordQueueTime(Double(components.seconds) + Double(components.attoseconds) / 1e18)
            }
            return lease
        } catch AdmissionError.timedOut {
            totalTimeouts += 1
            let components = start.duration(to: .now).components
            throw PipelineError.bulkheadTimeout(
                timeout: config.queueTimeout ?? 0,
                queueTime: Double(components.seconds) + Double(components.attoseconds) / 1e18
            )
        }
    }

    func recordQueueTime(_ time: TimeInterval) {
        queueTimes.append(time)
        if queueTimes.count > 100 {
            queueTimes.removeFirst(50)
        }
    }

    func recordRejection() {
        totalRejections += 1
    }

    func getStats() async -> PartitionStats {
        let snapshot = await admission.snapshot()
        let avgQueueTime = queueTimes.isEmpty ? 0 : queueTimes.reduce(0, +) / Double(queueTimes.count)

        return PartitionStats(
            name: name,
            capacity: config.capacity,
            activeCount: snapshot.active,
            queuedCount: snapshot.queued,
            totalExecutions: totalExecutions,
            totalRejections: totalRejections,
            averageQueueTime: avgQueueTime
        )
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
