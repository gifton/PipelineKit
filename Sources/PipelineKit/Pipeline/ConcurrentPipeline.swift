import Foundation

/// A thread-safe pipeline manager that supports concurrent command execution with controlled concurrency.
///
/// `ConcurrentPipeline` manages multiple pipelines for different command types and provides
/// controlled concurrent execution using an async semaphore. It ensures that only a limited
/// number of commands execute simultaneously, preventing resource exhaustion.
///
/// ## Overview
/// This actor provides:
/// - Registration of pipelines for specific command types
/// - Concurrent execution of multiple commands with concurrency limits
/// - Type-safe command routing to appropriate pipelines
/// - Batch execution with individual error handling
///
/// ## Example
/// ```swift
/// // Create a concurrent pipeline with max 5 concurrent operations
/// let concurrentPipeline = ConcurrentPipeline(maxConcurrency: 5)
///
/// // Register pipelines for different command types
/// await concurrentPipeline.register(CreateUserCommand.self, pipeline: userPipeline)
/// await concurrentPipeline.register(SendEmailCommand.self, pipeline: emailPipeline)
///
/// // Execute a single command
/// let user = try await concurrentPipeline.execute(
///     CreateUserCommand(name: "John"),
///     metadata: metadata
/// )
///
/// // Execute multiple commands concurrently
/// let commands = [
///     SendEmailCommand(to: "user1@example.com"),
///     SendEmailCommand(to: "user2@example.com"),
///     SendEmailCommand(to: "user3@example.com")
/// ]
/// let results = try await concurrentPipeline.executeConcurrently(commands)
/// ```
public actor ConcurrentPipeline {
    /// Storage for registered pipelines, keyed by command type identifier.
    private var pipelines: [ObjectIdentifier: any Pipeline] = [:]
    
    /// Semaphore to control the maximum number of concurrent operations.
    private let semaphore: AsyncSemaphore
    
    /// Creates a new concurrent pipeline with the specified concurrency limit.
    ///
    /// - Parameter maxConcurrency: The maximum number of commands that can execute
    ///   concurrently. Defaults to 10.
    public init(maxConcurrency: Int = 10) {
        self.semaphore = AsyncSemaphore(value: maxConcurrency)
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
        metadata: CommandMetadata? = nil
    ) async throws -> T.Result {
        let key = ObjectIdentifier(T.self)
        guard let pipeline = pipelines[key] else {
            throw PipelineError.executionFailed("No pipeline registered for \(T.self)")
        }
        
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }
        
        let executionMetadata = metadata ?? DefaultCommandMetadata()
        return try await pipeline.execute(command, metadata: executionMetadata)
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
        metadata: CommandMetadata? = nil
    ) async throws -> [Result<T.Result, Error>] {
        return await withTaskGroup(of: Result<T.Result, Error>.self) { group in
            for command in commands {
                group.addTask {
                    do {
                        let result = try await self.execute(command, metadata: metadata)
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var results: [Result<T.Result, Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
}

/// An async-safe counting semaphore for controlling concurrent access to resources.
///
/// `AsyncSemaphore` provides a way to limit the number of concurrent operations
/// in an async/await context. It maintains a count of available resources and
/// queues waiters when resources are exhausted.
///
/// ## Example
/// ```swift
/// let semaphore = AsyncSemaphore(value: 3) // Allow 3 concurrent operations
///
/// // In multiple concurrent tasks:
/// await semaphore.wait()
/// defer { await semaphore.signal() }
/// // Perform work...
/// ```
actor AsyncSemaphore {
    /// The current number of available resources.
    private var value: Int
    
    /// Queue of continuations waiting for resources to become available.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    /// Creates a new semaphore with the specified initial value.
    ///
    /// - Parameter value: The initial number of available resources.
    init(value: Int) {
        self.value = value
    }
    
    /// Waits for a resource to become available.
    ///
    /// If resources are available (value > 0), this method decrements the count
    /// and returns immediately. Otherwise, it suspends until a resource is released.
    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    /// Signals that a resource has been released.
    ///
    /// If there are waiting tasks, this method resumes the first waiter.
    /// Otherwise, it increments the available resource count.
    func signal() {
        if waiters.isEmpty {
            value += 1
            return
        }
        
        let waiter = waiters.removeFirst()
        waiter.resume()
    }
}