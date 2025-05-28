import Foundation

/// Middleware that applies back-pressure control to command execution pipelines.
///
/// `BackPressureMiddleware` provides fine-grained control over command throughput
/// by managing concurrency limits and queue depths at the middleware level.
/// This allows for pipeline-specific back-pressure policies that can be different
/// from the overall pipeline configuration.
///
/// ## Use Cases
/// - Rate limiting specific command types
/// - Protecting downstream services from overload  
/// - Implementing different QoS levels for different commands
/// - Adding back-pressure to existing pipelines without modification
///
/// ## Example
/// ```swift
/// let options = PipelineOptions(
///     maxConcurrency: 3,
///     maxOutstanding: 10,
///     backPressureStrategy: .dropOldest
/// )
/// 
/// let backPressureMiddleware = BackPressureMiddleware(options: options)
/// 
/// // Add to pipeline with appropriate priority
/// try await pipeline.addMiddleware(
///     backPressureMiddleware,
///     priority: ExecutionPriority.throttling.rawValue
/// )
/// ```
public struct BackPressureMiddleware: Middleware, PrioritizedMiddleware {
    /// The back-pressure semaphore managing concurrency and queue limits.
    private let semaphore: BackPressureAsyncSemaphore
    
    /// Configuration options for this middleware.
    public let options: PipelineOptions
    
    /// Recommended execution priority for back-pressure control.
    nonisolated(unsafe) public static var recommendedOrder: ExecutionPriority { .throttling }
    
    /// Creates back-pressure middleware with the specified options.
    ///
    /// - Parameter options: Configuration for concurrency limits and back-pressure strategy.
    public init(options: PipelineOptions) {
        self.options = options
        self.semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: options.maxConcurrency ?? Int.max,
            maxOutstanding: options.maxOutstanding,
            maxQueueMemory: options.maxQueueMemory,
            strategy: options.backPressureStrategy
        )
    }
    
    /// Convenience initializer for simple concurrency limiting.
    ///
    /// - Parameters:
    ///   - maxConcurrency: Maximum concurrent executions.
    ///   - maxOutstanding: Maximum total outstanding commands. Defaults to 2x maxConcurrency.
    ///   - strategy: Back-pressure strategy. Defaults to .suspend.
    public init(
        maxConcurrency: Int,
        maxOutstanding: Int? = nil,
        strategy: BackPressureStrategy = .suspend
    ) {
        let options = PipelineOptions(
            maxConcurrency: maxConcurrency,
            maxOutstanding: maxOutstanding ?? (maxConcurrency * 2),
            backPressureStrategy: strategy
        )
        self.init(options: options)
    }
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Acquire semaphore with back-pressure control
        let token = try await semaphore.acquire()
        defer { _ = token } // Keep token alive until end of scope
        
        // Execute the command through the rest of the pipeline
        return try await next(command, metadata)
    }
}

// MARK: - Monitoring Extensions

extension BackPressureMiddleware {
    /// Gets current back-pressure statistics for monitoring.
    ///
    /// - Returns: Statistics about current middleware utilization and queue state.
    public func getStats() async -> BackPressureStats {
        let semaphoreStats = await semaphore.getStats()
        return BackPressureStats(
            maxConcurrency: semaphoreStats.maxConcurrency,
            maxOutstanding: semaphoreStats.maxOutstanding,
            activeOperations: semaphoreStats.activeOperations,
            queuedOperations: semaphoreStats.queuedOperations,
            totalOutstanding: semaphoreStats.totalOutstanding,
            utilizationPercent: Double(semaphoreStats.activeOperations) / Double(semaphoreStats.maxConcurrency) * 100,
            backPressureStrategy: options.backPressureStrategy
        )
    }
    
    /// Checks if the middleware is currently applying back-pressure.
    ///
    /// - Returns: True if new commands would be subject to back-pressure policies.
    public func isApplyingBackPressure() async -> Bool {
        let stats = await semaphore.getStats()
        return stats.totalOutstanding >= stats.maxOutstanding || stats.availableResources == 0
    }
}

/// Statistics about back-pressure middleware state.
public struct BackPressureStats: Sendable {
    /// Maximum allowed concurrent operations.
    public let maxConcurrency: Int
    
    /// Maximum allowed outstanding operations (nil = unlimited).
    public let maxOutstanding: Int?
    
    /// Number of operations currently executing.
    public let activeOperations: Int
    
    /// Number of operations waiting in queue.
    public let queuedOperations: Int
    
    /// Total outstanding operations (active + queued).
    public let totalOutstanding: Int
    
    /// Current utilization as a percentage (0-100).
    public let utilizationPercent: Double
    
    /// The back-pressure strategy being applied.
    public let backPressureStrategy: BackPressureStrategy
}

// MARK: - Predefined Configurations

extension BackPressureMiddleware {
    /// Creates middleware optimized for high-throughput scenarios.
    /// 
    /// Uses aggressive concurrency with drop-oldest strategy to maintain flow.
    public static func highThroughput() -> BackPressureMiddleware {
        BackPressureMiddleware(options: .highThroughput())
    }
    
    /// Creates middleware optimized for low-latency scenarios.
    /// 
    /// Uses conservative concurrency with fast-fail strategy.
    public static func lowLatency() -> BackPressureMiddleware {
        BackPressureMiddleware(options: .lowLatency())
    }
    
    /// Creates middleware with unlimited capacity and suspend strategy.
    /// 
    /// Provides natural flow control without dropping commands.
    public static func flowControl(maxConcurrency: Int) -> BackPressureMiddleware {
        BackPressureMiddleware(
            maxConcurrency: maxConcurrency,
            maxOutstanding: nil,
            strategy: .suspend
        )
    }
}