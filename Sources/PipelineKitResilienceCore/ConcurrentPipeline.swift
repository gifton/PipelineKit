import Foundation
#if !canImport(Darwin)
@inline(__always)
func autoreleasepool<T>(invoking body: () -> T) -> T { body() }
#endif
import PipelineKit
import _ResilienceFoundation


/// A thread-safe pipeline manager that supports concurrent command execution with back-pressure control.
///
/// `ConcurrentPipeline` manages multiple pipelines for different command types and provides
/// controlled concurrent execution with configurable back-pressure strategies. It can suspend
/// producers, drop commands, or throw errors when capacity limits are exceeded.
///
/// ## Overview
/// This actor provides:
/// - Registration of pipelines for specific command types
/// - Concurrent execution with concurrency and queue limits
/// - Configurable back-pressure strategies (suspend, drop, error)
/// - Type-safe command routing to appropriate pipelines
/// - Batch execution with individual error handling
/// - Real-time capacity monitoring
///
/// ## Example
/// ```swift
/// // Create a pipeline with back-pressure control
/// let options = PipelineOptions(
///     maxConcurrency: 5,
///     maxOutstanding: 20,
///     backPressureStrategy: .suspend
/// )
/// let concurrentPipeline = ConcurrentPipeline(options: options)
///
/// // Register pipelines for different command types
/// await concurrentPipeline.register(CreateUserCommand.self, pipeline: userPipeline)
/// await concurrentPipeline.register(SendEmailCommand.self, pipeline: emailPipeline)
///
/// // Execute commands - will suspend if capacity exceeded
/// let user = try await concurrentPipeline.execute(
///     CreateUserCommand(name: "John"),
///     metadata: metadata
/// )
/// ```
public actor ConcurrentPipeline: Pipeline {
    /// Storage for registered pipelines, keyed by command type identifier.
    private var pipelines: [ObjectIdentifier: any Pipeline] = [:]
    
    /// Back-pressure aware semaphore to control concurrency and queue limits.
    private let semaphore: BackPressureSemaphore
    
    /// Configuration options for this pipeline.
    public let options: PipelineOptions
    
    /// Creates a new concurrent pipeline with back-pressure control.
    ///
    /// - Parameter options: Configuration options including concurrency limits and back-pressure strategy.
    public init(options: PipelineOptions = PipelineOptions()) {
        self.options = options
        self.semaphore = BackPressureSemaphore(
            maxConcurrency: options.maxConcurrency ?? 10,
            maxOutstanding: options.maxOutstanding,
            maxQueueMemory: options.maxQueueMemory,
            strategy: options.backPressureStrategy
        )
    }
    
    
    /// Registers a pipeline for a specific command type.
    ///
    /// Once registered, commands of the specified type can be executed through this
    /// concurrent pipeline manager.
    ///
    /// - Parameters:
    ///   - commandType: The type of command this pipeline will handle.
    ///   - pipeline: The pipeline that will process commands of this type.
    ///
    /// - Note: If a pipeline is already registered for the command type, it will be replaced.
    public func register<T: Command>(_ commandType: T.Type, pipeline: any Pipeline) {
        let key = ObjectIdentifier(commandType)
        pipelines[key] = pipeline
    }
    
    /// Executes a single command with concurrency control.
    ///
    /// The command is routed to the appropriate registered pipeline based on its type.
    /// Execution is throttled by the semaphore to respect concurrency limits.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - metadata: Optional metadata for the command execution. If nil, default metadata is used.
    /// - Returns: The result of the command execution.
    /// - Throws: `PipelineError.executionFailed` if no pipeline is registered for the command type,
    ///           or any error thrown by the pipeline execution.
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result {
        let key = ObjectIdentifier(T.self)
        guard let pipeline = pipelines[key] else {
            throw PipelineError.handlerNotFound(commandType: String(describing: T.self))
        }
        
        let token = try await semaphore.acquire()
        defer { _ = token } // Keep token alive until end of scope
        
        return try await pipeline.execute(command, context: context)
    }
    
    /// Convenience method to execute with default context
    public func execute<T: Command>(
        _ command: T
    ) async throws -> T.Result {
        try await execute(command, context: CommandContext())
    }
    
    /// Executes a single command with concurrency control and timeout.
    ///
    /// The command is routed to the appropriate registered pipeline based on its type.
    /// Execution is throttled by the semaphore to respect concurrency limits.
    /// If the semaphore cannot be acquired within the timeout, the execution fails.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - metadata: Optional metadata for the command execution. If nil, default metadata is used.
    ///   - timeout: Maximum time to wait for semaphore acquisition, in seconds.
    /// - Returns: The result of the command execution.
    /// - Throws: `PipelineError.executionFailed` if no pipeline is registered or timeout occurs,
    ///           or any error thrown by the pipeline execution.
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext? = nil,
        timeout: TimeInterval
    ) async throws -> T.Result {
        let key = ObjectIdentifier(T.self)
        guard let pipeline = pipelines[key] else {
            throw PipelineError.handlerNotFound(commandType: String(describing: T.self))
        }
        
        guard let token = try await semaphore.acquire(timeout: timeout) else {
            throw PipelineError.timeout(duration: timeout, command: command)
        }
        
        defer { _ = token } // Keep token alive until end of scope
        
        let executionContext = context ?? CommandContext()
        return try await pipeline.execute(command, context: executionContext)
    }
    
    /// Executes multiple commands concurrently with individual error handling.
    ///
    /// Commands are executed in parallel up to the concurrency limit. Each command's
    /// result is wrapped in a `Result` type to capture success or failure individually.
    ///
    /// - Parameters:
    ///   - commands: An array of commands to execute concurrently.
    ///   - metadata: Optional metadata for all command executions. If nil, default metadata is used.
    /// - Returns: An array of results corresponding to each command, preserving order.
    /// - Throws: This method doesn't throw; individual command failures are captured in the results.
    ///
    /// - Note: The order of results matches the order of input commands.
    public func executeConcurrently<T: Command>(
        _ commands: [T],
        context: CommandContext? = nil
    ) async throws -> [Result<T.Result, Error>] {
        return await withTaskGroup(of: (Int, Result<T.Result, Error>).self) { group in
            for (index, command) in commands.enumerated() {
                group.addTask {
                    do {
                        let ctx = context ?? CommandContext()
                        let result = try await self.execute(command, context: ctx)
                        return (index, .success(result))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            
            var results: [(Int, Result<T.Result, Error>)] = []
            for await indexedResult in group {
                results.append(indexedResult)
            }
            
            // Sort by index to preserve order
            return autoreleasepool {
                results.sort { $0.0 < $1.0 }
                return results.map { $0.1 }
            }
        }
    }
    
    /// Gets current pipeline capacity statistics for monitoring.
    ///
    /// - Returns: Statistics about current pipeline utilization and queue state.
    public func getCapacityStats() async -> PipelineCapacityStats {
        let semaphoreStats = await semaphore.getStats()
        return PipelineCapacityStats(
            maxConcurrency: semaphoreStats.maxConcurrency,
            maxOutstanding: semaphoreStats.maxOutstanding,
            activeOperations: semaphoreStats.activeOperations,
            queuedOperations: semaphoreStats.queuedOperations,
            totalOutstanding: semaphoreStats.totalOutstanding,
            utilizationPercent: Double(semaphoreStats.activeOperations) / Double(semaphoreStats.maxConcurrency) * 100,
            registeredPipelineCount: pipelines.count
        )
    }
    
    /// Checks if the pipeline is currently at capacity.
    ///
    /// - Returns: True if no more commands can be accepted without back-pressure.
    public func isAtCapacity() async -> Bool {
        let stats = await semaphore.getStats()
        return stats.totalOutstanding >= stats.maxOutstanding || stats.availableResources == 0
    }
}

/// Statistics about pipeline capacity and utilization.
public struct PipelineCapacityStats: Sendable {
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
    
    /// Number of registered command type pipelines.
    public let registeredPipelineCount: Int
}
