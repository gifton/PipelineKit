import Foundation

/// Configuration options for pipeline execution behavior and back-pressure control.
///
/// `PipelineOptions` provides fine-grained control over how pipelines handle
/// command execution, concurrency limits, and back-pressure situations.
///
/// ## Back-Pressure Control
///
/// When the pipeline reaches its capacity limits, back-pressure determines how
/// new incoming commands are handled:
///
/// - **suspend**: Queues within the outstanding bound until execution capacity becomes available
/// - **dropOldest**: Removes the oldest queued command to make room
/// - **dropNewest**: Rejects the new command if queue is full
/// - **error**: Rejects excess outstanding work or applies an admission timeout
///
/// ## Example
/// ```swift
/// let options = PipelineOptions(
///     maxConcurrency: 5,
///     maxOutstanding: 20,
///     backPressureStrategy: .suspend
/// )
///
/// let pipeline = ConcurrentPipeline(options: options)
/// ```
@frozen
public struct PipelineOptions: Sendable {
    /// Maximum number of commands that can execute concurrently.
    /// If nil, no concurrency limit is applied.
    public let maxConcurrency: Int?
    
    /// Hard limit on the total of actively executing and queued commands.
    /// Every strategy rejects overflow unless dropping a queued command creates room.
    /// If nil, no outstanding limit is applied.
    public let maxOutstanding: Int?
    
    /// Maximum memory (in bytes) that can be used by queued operations.
    /// If nil, no memory limit is applied.
    public let maxQueueMemory: Int?
    
    /// Strategy for handling back-pressure when limits are reached.
    public let backPressureStrategy: BackPressureStrategy
    
    /// Creates pipeline options with specified limits and back-pressure behavior.
    ///
    /// - Parameters:
    ///   - maxConcurrency: Maximum concurrent executions. Defaults to 10.
    ///   - maxOutstanding: Maximum total outstanding commands (executing + queued). Defaults to 50.
    ///   - maxQueueMemory: Maximum memory for queued operations. Defaults to nil (unlimited).
    ///   - backPressureStrategy: How to handle capacity overflow. Defaults to .suspend.
    @inlinable
    public init(
        maxConcurrency: Int? = 10,
        maxOutstanding: Int? = 50,
        maxQueueMemory: Int? = nil,
        backPressureStrategy: BackPressureStrategy = .suspend
    ) {
        self.maxConcurrency = maxConcurrency
        self.maxOutstanding = maxOutstanding
        self.maxQueueMemory = maxQueueMemory
        self.backPressureStrategy = backPressureStrategy
    }
    
    /// Creates default options with sensible limits.
    public static let `default` = PipelineOptions()
    
    /// Creates options with unlimited capacity and suspend strategy.
    @inlinable
    public static func unlimited() -> PipelineOptions {
        PipelineOptions(
            maxConcurrency: nil,
            maxOutstanding: nil,
            backPressureStrategy: .suspend
        )
    }
    
    /// Creates options optimized for high-throughput scenarios.
    @inlinable
    public static func highThroughput() -> PipelineOptions {
        PipelineOptions(
            maxConcurrency: 50,
            maxOutstanding: 200,
            maxQueueMemory: 104_857_600, // 100MB
            backPressureStrategy: .dropOldest
        )
    }
    
    /// Creates options optimized for low-latency scenarios.
    @inlinable
    public static func lowLatency() -> PipelineOptions {
        PipelineOptions(
            maxConcurrency: 5,
            maxOutstanding: 10,
            maxQueueMemory: 10_485_760, // 10MB
            backPressureStrategy: .error(timeout: 0.1)
        )
    }
}

/// Strategies for handling back-pressure when pipeline capacity is exceeded.
@frozen
public enum BackPressureStrategy: Sendable, Equatable {
    /// Suspend admitted queued work until execution capacity becomes available.
    /// Reject new work when the outstanding bound is full.
    case suspend
    
    /// Drop the earliest-enqueued command, regardless of its service priority,
    /// to make room for the new one. Reject if every outstanding command is active.
    case dropOldest
    
    /// Drop the newest command if the queue is full.
    /// Preserves existing work at the cost of rejecting new requests.
    case dropNewest
    
    /// Controls admission waiting when execution capacity is occupied.
    ///
    /// Every timeout setting rejects excess outstanding work immediately.
    /// A nil timeout allows waiting without an admission deadline while the
    /// outstanding limit permits queueing.
    /// A finite nonpositive timeout permits immediate acquisition only. A positive
    /// timeout bounds waiting and must be at most 86400 seconds. Nonfinite values
    /// and values above that bound fail a precondition when constructing the
    /// concurrent pipeline or back-pressure semaphore.
    ///
    /// An explicit per-call acquisition timeout overrides this deadline while
    /// retaining the queue rejection policy. Deadlines end at acquisition and
    /// do not cancel or shorten execution of an admitted command.
    case error(timeout: TimeInterval?)
}
