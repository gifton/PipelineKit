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
/// - **suspend**: Suspends the producer until capacity becomes available
/// - **dropOldest**: Removes the oldest queued command to make room
/// - **dropNewest**: Rejects the new command if queue is full
/// - **error**: Throws an error immediately or after timeout
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
    
    /// Maximum number of commands that can be queued awaiting execution.
    /// This includes both actively executing and queued commands.
    /// If nil, no queue limit is applied.
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
    /// Suspend the producer until capacity becomes available.
    /// This provides flow control by naturally slowing down producers.
    case suspend
    
    /// Drop the oldest queued command to make room for the new one.
    /// Useful for scenarios where recent data is more valuable.
    case dropOldest
    
    /// Drop the newest command if the queue is full.
    /// Preserves existing work at the cost of rejecting new requests.
    case dropNewest
    
    /// Throw an error immediately or after the specified timeout.
    /// - Parameter timeout: Maximum time to wait before throwing. If nil, throws immediately.
    case error(timeout: TimeInterval?)
}
