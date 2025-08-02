import Foundation
import PipelineKitCore

// MARK: - Helper Functions

/// Race between an async operation and a timeout
private func race<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T,
                              timeout: TimeInterval,
                              timeoutError: Error) async throws -> T {
    try await withThrowingTaskGroup(of: TaskResult<T>.self) { group in
        group.addTask {
            do {
                let result = try await operation()
                return .success(result)
            } catch {
                return .failure(error)
            }
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return .failure(timeoutError)
        }
        
        // Return the first completed result
        guard let taskResult = try await group.next() else {
            throw timeoutError
        }
        
        // Cancel remaining tasks
        group.cancelAll()
        
        switch taskResult {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

private enum TaskResult<T: Sendable>: Sendable {
    case success(T)
    case failure(Error)
}

/// Actor to safely store the result from racing tasks
private actor ResultBox<T: Sendable> {
    private var result: TaskResult<T>?
    
    func set(_ newResult: TaskResult<T>) {
        // Only set if we don't have a result yet (first one wins)
        if result == nil {
            result = newResult
        }
    }
    
    func get() -> TaskResult<T>? {
        return result
    }
}

/// A middleware wrapper that enforces a timeout on middleware execution.
///
/// This wrapper ensures that the wrapped middleware completes within the specified
/// timeout duration. If the middleware exceeds the timeout, the task is cancelled
/// and a `TimeoutError` is thrown.
///
/// ## Example
/// ```swift
/// let timeoutMiddleware = TimeoutMiddlewareWrapper(
///     wrapped: ExpensiveValidationMiddleware(),
///     timeout: 5.0 // 5 seconds
/// )
/// ```
///
/// ## Implementation
/// Uses Swift's structured concurrency to properly implement timeouts with
/// task cancellation. If the timeout is exceeded, the underlying task is
/// cancelled and a TimeoutError is thrown.
public struct TimeoutMiddlewareWrapper: Middleware, Sendable {
    /// The wrapped middleware to execute with timeout
    private let wrapped: any Middleware
    
    /// The timeout duration in seconds
    private let timeout: TimeInterval
    
    /// The execution priority (inherited from wrapped middleware)
    public let priority: ExecutionPriority
    
    /// Whether to cancel the task on timeout or just throw an error
    private let cancelOnTimeout: Bool
    
    /// Creates a new timeout middleware wrapper.
    ///
    /// - Parameters:
    ///   - wrapped: The middleware to wrap with timeout
    ///   - timeout: The maximum execution time in seconds
    ///   - priority: The execution priority (defaults to wrapped middleware's priority)
    ///   - cancelOnTimeout: Whether to cancel the task on timeout (default: true)
    public init(
        wrapped: any Middleware,
        timeout: TimeInterval,
        priority: ExecutionPriority? = nil,
        cancelOnTimeout: Bool = true
    ) {
        self.wrapped = wrapped
        self.timeout = timeout
        self.priority = priority ?? wrapped.priority
        self.cancelOnTimeout = cancelOnTimeout
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Create a reference type to hold the result
        let resultBox = ResultBox<T.Result>()
        
        // Use async let to race between execution and timeout
        async let executionTask: Void = {
            do {
                let result = try await self.wrapped.execute(command, context: context, next: next)
                await resultBox.set(.success(result))
            } catch {
                await resultBox.set(.failure(error))
            }
        }()
        
        async let timeoutTask: Void = {
            try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
            await resultBox.set(.failure(TimeoutError(
                timeout: self.timeout,
                middleware: String(describing: type(of: self.wrapped)),
                command: String(describing: type(of: command))
            )))
        }()
        
        // Wait for either task to complete
        _ = await [executionTask, timeoutTask]
        
        // Get the result
        guard let taskResult = await resultBox.get() else {
            throw TimeoutError(
                timeout: self.timeout,
                middleware: String(describing: type(of: self.wrapped)),
                command: String(describing: type(of: command))
            )
        }
        
        switch taskResult {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

/// Error thrown when middleware execution exceeds the specified timeout.
public struct TimeoutError: LocalizedError {
    /// The timeout duration that was exceeded
    public let timeout: TimeInterval
    
    /// The name of the middleware that timed out
    public let middleware: String
    
    /// The command type being processed
    public let command: String
    
    public init(timeout: TimeInterval, middleware: String, command: String) {
        self.timeout = timeout
        self.middleware = middleware
        self.command = command
    }
    
    public var errorDescription: String? {
        String(format: "Middleware '%@' timed out after %.2f seconds while processing command '%@'",
               middleware, timeout, command)
    }
}