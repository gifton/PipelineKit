import Foundation
import PipelineKit
import PipelineKitCore
import _ResilienceFoundation
/// Middleware that implements the Bulkhead pattern for resource isolation.
///
/// The Bulkhead pattern prevents a failure in one part of the system from
/// cascading to other parts by isolating resources (threads, connections, etc.).
/// This implementation provides several isolation strategies.
///
/// ## Features
/// - Semaphore-based isolation for concurrent request limiting
/// - Queue-based isolation with configurable queue sizes
/// - Thread pool isolation (conceptual, using tasks)
/// - Metrics and monitoring support
/// - Configurable rejection policies
///
/// ## Example Usage
/// ```swift
/// // Simple concurrency limiting
/// let middleware = BulkheadMiddleware(maxConcurrency: 10)
/// 
/// // With queue for overflow
/// let middleware = BulkheadMiddleware(
///     maxConcurrency: 10,
///     maxQueueSize: 50,
///     queueTimeout: 5.0
/// )
/// 
/// // With custom rejection handler
/// let middleware = BulkheadMiddleware(
///     maxConcurrency: 10,
///     rejectionHandler: { command, context in
///         context.emitCustomEvent("bulkhead_rejected", properties: [
///             "command": String(describing: type(of: command))
///         ])
///     }
/// )
/// ```
/// 
/// Admission uses an actor-owned FIFO and leases. The shared
/// `BulkheadAdmissionConservationTests` exercise queue reuse, cancellation and
/// handler concurrency for ordinary and legacy wrappers.
///
/// ## Combining Resilience Patterns
/// 
/// Recommended ordering when using multiple resilience middleware:
/// 1. RateLimiting (prevent overload at source)
/// 2. CircuitBreaker (fail fast for unhealthy services)  
/// 3. Bulkhead (isolate resources)
/// 4. Timeout (bound execution time)
/// 5. Retry (handle transient failures)
public struct BulkheadMiddleware: Middleware, NextGuardWarningSuppressing {
    public let priority: ExecutionPriority = .resilience

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Maximum concurrent executions allowed
        public let maxConcurrency: Int

        /// Maximum number of commands that can wait in queue
        public let maxQueueSize: Int

        /// Timeout for queued commands
        public let queueTimeout: TimeInterval?

        /// Strategy for handling rejected commands
        public let rejectionPolicy: RejectionPolicy

        /// Custom rejection handler
        public let rejectionHandler: (@Sendable (any Command, CommandContext) async -> Void)?

        /// Whether to emit metrics
        public let emitMetrics: Bool

        /// Isolation mode
        public let isolationMode: IsolationMode

        public init(
            maxConcurrency: Int,
            maxQueueSize: Int = 0,
            queueTimeout: TimeInterval? = nil,
            rejectionPolicy: RejectionPolicy = .failFast,
            rejectionHandler: (@Sendable (any Command, CommandContext) async -> Void)? = nil,
            emitMetrics: Bool = true,
            isolationMode: IsolationMode = .semaphore
        ) {
            self.maxConcurrency = maxConcurrency
            self.maxQueueSize = maxQueueSize
            self.queueTimeout = queueTimeout
            self.rejectionPolicy = rejectionPolicy
            self.rejectionHandler = rejectionHandler
            self.emitMetrics = emitMetrics
            self.isolationMode = isolationMode
        }
    }

    /// Rejection policy for commands when bulkhead is full
    public enum RejectionPolicy: Sendable {
        /// Immediately fail with an error
        case failFast

        /// Queue the command if queue space available
        case queue

        /// Use a fallback value
        case fallback(value: @Sendable () async -> Any)

        /// Custom rejection logic
        case custom(handler: @Sendable (any Command) async throws -> Any)
    }

    /// Isolation mode for the bulkhead
    public enum IsolationMode: Sendable {
        /// Use a semaphore for concurrency control
        case semaphore

        /// Use task-based isolation with priority
        case taskGroup(priority: TaskPriority?)

        /// Use tagged isolation for different command types
        @available(*, deprecated, message: "Tagged mode never provided per-tag isolation — every tag contends on the same shared semaphore, and the tag is recorded only as context metadata (#86). For real per-tenant capacity use PartitionedBulkheadMiddleware with allowBorrowing: false. This mode will be removed in 0.6.")
        case tagged(keyExtractor: @Sendable (any Command) -> String)
    }

    private let configuration: Configuration
    private let admission: AdmissionGate
    private let metrics: BulkheadMetricsTracker

    public init(configuration: Configuration) {
        precondition(configuration.maxConcurrency > 0, "Bulkhead concurrency must be positive")
        precondition(configuration.maxQueueSize >= 0, "Bulkhead queue size must be nonnegative")
        self.init(configuration: configuration, admission: AdmissionGate(
            capacity: configuration.maxConcurrency,
            maxQueueSize: configuration.maxQueueSize
        ))
    }

    /// Package test seam; the supplied gate must match the configuration limits.
    package init(configuration: Configuration, admission: AdmissionGate) {
        precondition(configuration.queueTimeout?.isFinite != false, "Bulkhead queue timeout must be finite")
        self.configuration = configuration
        self.admission = admission
        self.metrics = BulkheadMetricsTracker()
    }

    public init(
        maxConcurrency: Int,
        maxQueueSize: Int = 0,
        queueTimeout: TimeInterval? = nil
    ) {
        self.init(
            configuration: Configuration(
                maxConcurrency: maxConcurrency,
                maxQueueSize: maxQueueSize,
                queueTimeout: queueTimeout
            )
        )
    }

    // MARK: - Middleware Implementation

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let startTime = Date()

        // Record attempt
        await metrics.recordAttempt()

        switch configuration.isolationMode {
        case .semaphore:
            return try await executeSemaphoreIsolation(
                command,
                context: context,
                next: next,
                startTime: startTime
            )

        case let .taskGroup(priority):
            return try await executeTaskGroupIsolation(
                command,
                context: context,
                next: next,
                priority: priority,
                startTime: startTime
            )

        // This case is deprecated (#86) but the match must stay exhaustive so
        // .tagged keeps working until its removal in 0.6. Swift's deprecation
        // diagnostic fires at construction sites, not on this pattern match, so
        // no warning appears here — that's expected.
        case let .tagged(keyExtractor):
            let tag = keyExtractor(command)
            return try await executeTaggedIsolation(
                command,
                context: context,
                next: next,
                tag: tag,
                startTime: startTime
            )
        }
    }

    // MARK: - Private Methods

    package func admissionSnapshot() async -> (active: Int, queued: Int) {
        let snapshot = await admission.snapshot()
        return (snapshot.active, snapshot.queued)
    }

    private func executeSemaphoreIsolation<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>,
        startTime: Date
    ) async throws -> T.Result {
        try Task.checkCancellation()
        if let lease = await admission.tryAcquire() {
            return try await executeAdmitted(command, context: context, next: next, lease: lease, startTime: startTime)
        }

        switch configuration.rejectionPolicy {
        case .failFast:
            await metrics.recordRejection()
            await handleRejection(command, context: context)
            throw PipelineError.bulkheadRejected(
                reason: "Maximum concurrency limit reached: \(configuration.maxConcurrency)"
            )

        case .queue:
            let queueStart = ContinuousClock.now
            let lease: AdmissionLease
            do {
                lease = try await admission.acquire(timeout: configuration.queueTimeout.map { .seconds($0) })
            } catch AdmissionError.full {
                await metrics.recordRejection()
                await handleRejection(command, context: context)
                throw PipelineError.bulkheadRejected(reason: "Queue is full: \(configuration.maxQueueSize)")
            } catch AdmissionError.timedOut {
                await metrics.recordTimeout()
                throw PipelineError.bulkheadTimeout(
                    timeout: configuration.queueTimeout ?? 0,
                    queueTime: Self.seconds(queueStart.duration(to: .now))
                )
            }
            return try await executeAdmitted(command, context: context, next: next, lease: lease, startTime: startTime)

        case let .fallback(fallbackProvider):
            await metrics.recordFallback()
            if let result = await fallbackProvider() as? T.Result {
                return result
            }
            throw PipelineError.bulkheadRejected(
                reason: "Fallback failed to provide valid result"
            )

        case let .custom(handler):
            await metrics.recordRejection()
            if let result = try await handler(command) as? T.Result {
                return result
            }
            throw PipelineError.bulkheadRejected(
                reason: "Custom handler failed to provide valid result"
            )
        }
    }

    private func executeAdmitted<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>,
        lease: AdmissionLease,
        startTime: Date
    ) async throws -> T.Result {
        do {
            try Task.checkCancellation()
            await metrics.recordExecution()
            if lease.wasQueued {
                await metrics.recordQueueTime(Self.seconds(lease.queueDuration))
            }
            let result = try await next(command, context)
            await lease.release()
            await emitMetrics(context: context, startTime: startTime, wasQueued: lease.wasQueued)
            return result
        } catch {
            await lease.release()
            await emitMetrics(context: context, startTime: startTime, wasQueued: lease.wasQueued)
            throw error
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func executeTaskGroupIsolation<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>,
        priority: TaskPriority?,
        startTime: Date
    ) async throws -> T.Result {
        // This is a conceptual implementation using task groups
        // In practice, Swift doesn't provide true thread pool isolation
        // Just delegate to semaphore isolation

        return try await executeSemaphoreIsolation(
            command,
            context: context,
            next: next,
            startTime: startTime
        )
    }

    private func executeTaggedIsolation<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>,
        tag: String,
        startTime: Date
    ) async throws -> T.Result {
        // Deprecated tagged mode shares admission; the tag is metadata only.
        context.setMetadata("bulkheadTag", value: tag)

        return try await executeSemaphoreIsolation(
            command,
            context: context,
            next: next,
            startTime: startTime
        )
    }

    private func handleRejection(_ command: any Command, context: CommandContext) async {
        if let handler = configuration.rejectionHandler {
            await handler(command, context)
        }

        if configuration.emitMetrics {
            await context.emitMiddlewareEvent(
                PipelineEvent.Name.bulkheadRejected,
                middleware: "BulkheadMiddleware",
                properties: [
                    "commandType": String(describing: type(of: command))
                ]
            )
        }
    }

    private func emitMetrics(
        context: CommandContext,
        startTime: Date,
        wasQueued: Bool
    ) async {
        guard configuration.emitMetrics else { return }

        let duration = Date().timeIntervalSince(startTime)
        let snapshot = await admission.snapshot()
        let stats = await metrics.getStats(admission: snapshot)

        context.setMetadata("bulkhead.duration", value: duration)
        context.setMetadata("bulkhead.wasQueued", value: wasQueued)
        context.setMetadata("bulkhead.activeCount", value: stats.activeExecutions)
        context.setMetadata("bulkhead.queuedCount", value: stats.queuedCommands)
    }
}

// MARK: - Supporting Types

/// Metrics tracking for bulkhead
private actor BulkheadMetricsTracker {
    private var totalAttempts = 0
    private var totalExecutions = 0
    private var totalRejections = 0
    private var totalTimeouts = 0
    private var totalFallbacks = 0
    private var queueTimes: [TimeInterval] = []

    func recordAttempt() {
        totalAttempts += 1
    }

    func recordExecution() {
        totalExecutions += 1
    }

    func recordRejection() {
        totalRejections += 1
    }

    func recordTimeout() {
        totalTimeouts += 1
    }

    func recordFallback() {
        totalFallbacks += 1
    }

    func recordQueueTime(_ time: TimeInterval) {
        queueTimes.append(time)
        // Keep only recent queue times
        if queueTimes.count > 1000 {
            queueTimes.removeFirst(500)
        }
    }

    func getStats(admission: AdmissionSnapshot) -> BulkheadMetrics {
        let avgQueueTime = queueTimes.isEmpty ? 0 : queueTimes.reduce(0, +) / Double(queueTimes.count)

        return BulkheadMetrics(
            totalAttempts: totalAttempts,
            totalExecutions: totalExecutions,
            totalRejections: totalRejections,
            totalTimeouts: totalTimeouts,
            totalFallbacks: totalFallbacks,
            activeExecutions: admission.active,
            queuedCommands: admission.queued,
            averageQueueTime: avgQueueTime
        )
    }
}

/// Statistics for bulkhead operations
public struct BulkheadMetrics: Sendable {
    public let totalAttempts: Int
    public let totalExecutions: Int
    public let totalRejections: Int
    public let totalTimeouts: Int
    public let totalFallbacks: Int
    public let activeExecutions: Int
    public let queuedCommands: Int
    public let averageQueueTime: TimeInterval
}

// MARK: - Pipeline Error Extensions

public extension PipelineError {
    /// Error when a command is rejected by the bulkhead
    static func bulkheadRejected(reason: String) -> PipelineError {
        .middlewareError(
            middleware: "BulkheadMiddleware",
            message: reason,
            context: ErrorContext(
                commandType: "Unknown",
                middlewareType: "BulkheadMiddleware",
                additionalInfo: ["type": "BulkheadRejection"]
            )
        )
    }

    /// Error when a command times out in the bulkhead queue
    static func bulkheadTimeout(timeout: TimeInterval, queueTime: TimeInterval) -> PipelineError {
        .middlewareError(
            middleware: "BulkheadMiddleware",
            message: "Command timed out after \(queueTime)s in queue (timeout: \(timeout)s)",
            context: ErrorContext(
                commandType: "Unknown",
                middlewareType: "BulkheadMiddleware",
                additionalInfo: [
                    "type": "BulkheadTimeout",
                    "timeout": String(timeout),
                    "queueTime": String(queueTime)
                ]
            )
        )
    }
}
