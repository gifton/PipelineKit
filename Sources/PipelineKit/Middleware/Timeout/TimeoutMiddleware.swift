import Foundation

/// Middleware that enforces execution timeouts for commands.
///
/// This middleware ensures that command execution completes within a specified
/// time limit. If the timeout is exceeded, the execution is cancelled and a
/// timeout error is thrown.
///
/// ## Example Usage
/// ```swift
/// let middleware = TimeoutMiddleware(
///     timeout: 30.0, // 30 seconds
///     timeoutProvider: { command in
///         // Custom timeout based on command type
///         if command is LongRunningCommand {
///             return 60.0
///         }
///         return 30.0
///     }
/// )
/// ```
public final class TimeoutMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .resilience
    
    private let defaultTimeout: TimeInterval
    private let timeoutProvider: (@Sendable (any Command) -> TimeInterval)?
    private let includeCleanupTime: Bool
    
    /// Creates a timeout middleware with the specified configuration.
    ///
    /// - Parameters:
    ///   - timeout: Default timeout in seconds
    ///   - timeoutProvider: Optional function to provide command-specific timeouts
    ///   - includeCleanupTime: Whether to include cleanup time in timeout calculation
    public init(
        timeout: TimeInterval,
        timeoutProvider: (@Sendable (any Command) -> TimeInterval)? = nil,
        includeCleanupTime: Bool = true
    ) {
        self.defaultTimeout = timeout
        self.timeoutProvider = timeoutProvider
        self.includeCleanupTime = includeCleanupTime
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Determine timeout for this command
        let timeout = timeoutProvider?(command) ?? defaultTimeout
        
        // Store timeout in context for downstream use
        await context.set(timeout, for: CommandTimeoutKey.self)
        
        // Emit timeout started event
        await context.emitCustomEvent(
            "timeout.started",
            properties: [
                "command": String(describing: type(of: command)),
                "timeout": timeout
            ]
        )
        
        // Create a task group to race timeout vs execution
        return try await withThrowingTaskGroup(of: TimeoutResult<T.Result>.self) { group in
            // Start the actual command execution
            group.addTask {
                do {
                    let result = try await next(command, context)
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }
            
            // Start the timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timeout
            }
            
            // Wait for the first task to complete
            guard let firstResult = try await group.next() else {
                throw TimeoutError.internalError("No tasks completed")
            }
            
            // Cancel remaining tasks
            group.cancelAll()
            
            // Handle the result
            switch firstResult {
            case .success(let result):
                // Command completed successfully
                await context.emitCustomEvent(
                    "timeout.completed",
                    properties: [
                        "command": String(describing: type(of: command)),
                        "timeout": timeout
                    ]
                )
                return result
                
            case .failure(let error):
                // Command failed with an error
                await context.emitCustomEvent(
                    "timeout.failed",
                    properties: [
                        "command": String(describing: type(of: command)),
                        "timeout": timeout,
                        "error": String(describing: error)
                    ]
                )
                throw error
                
            case .timeout:
                // Timeout occurred
                await context.emitCustomEvent(
                    "timeout.exceeded",
                    properties: [
                        "command": String(describing: type(of: command)),
                        "timeout": timeout
                    ]
                )
                
                if includeCleanupTime {
                    // Give a small grace period for cleanup
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                }
                
                throw TimeoutError.executionTimeout(
                    command: String(describing: type(of: command)),
                    timeout: timeout
                )
            }
        }
    }
}

// MARK: - Timeout Result

private enum TimeoutResult<T: Sendable>: Sendable {
    case success(T)
    case failure(Error)
    case timeout
}

// MARK: - Context Key

private struct CommandTimeoutKey: ContextKey {
    typealias Value = TimeInterval
}

public extension CommandContext {
    /// Gets the timeout value set by TimeoutMiddleware.
    var commandTimeout: TimeInterval? {
        get async { self[CommandTimeoutKey.self] }
    }
}

// MARK: - Errors

public enum TimeoutError: LocalizedError {
    case executionTimeout(command: String, timeout: TimeInterval)
    case internalError(String)
    
    public var errorDescription: String? {
        switch self {
        case .executionTimeout(let command, let timeout):
            return "Command '\(command)' exceeded timeout of \(timeout) seconds"
        case .internalError(let message):
            return "Timeout middleware internal error: \(message)"
        }
    }
}

// MARK: - Convenience Initializers

public extension TimeoutMiddleware {
    /// Creates a timeout middleware with different timeouts by command type.
    convenience init(timeouts: [String: TimeInterval], defaultTimeout: TimeInterval = 30.0) {
        self.init(
            timeout: defaultTimeout,
            timeoutProvider: { command in
                let typeName = String(describing: type(of: command))
                return timeouts[typeName] ?? defaultTimeout
            }
        )
    }
    
    /// Creates a timeout middleware that reads timeout from command if it implements TimeoutProvider.
    static func dynamic(defaultTimeout: TimeInterval = 30.0) -> TimeoutMiddleware {
        TimeoutMiddleware(
            timeout: defaultTimeout,
            timeoutProvider: { command in
                if let provider = command as? TimeoutProvider {
                    return provider.timeout
                }
                return defaultTimeout
            }
        )
    }
    
    /// Creates a timeout middleware with scaling based on context.
    static func contextAware(
        baseTimeout: TimeInterval,
        debugMultiplier: Double = 3.0
    ) -> TimeoutMiddleware {
        TimeoutMiddleware(
            timeout: baseTimeout,
            timeoutProvider: { command in
                // In debug mode, give more time
                #if DEBUG
                return baseTimeout * debugMultiplier
                #else
                return baseTimeout
                #endif
            }
        )
    }
}

// MARK: - Timeout Provider Protocol

/// Protocol for commands that specify their own timeout.
public protocol TimeoutProvider {
    /// The timeout for this command in seconds.
    var timeout: TimeInterval { get }
}

// MARK: - Timeout Utilities

/// Utility functions for working with timeouts.
public enum TimeoutUtilities {
    /// Calculates timeout based on data size and expected throughput.
    public static func dataTransferTimeout(
        bytes: Int,
        bytesPerSecond: Double = 1_048_576, // 1MB/s default
        minimumTimeout: TimeInterval = 5.0,
        overhead: TimeInterval = 2.0
    ) -> TimeInterval {
        let transferTime = Double(bytes) / bytesPerSecond
        return max(minimumTimeout, transferTime + overhead)
    }
    
    /// Calculates timeout based on number of operations.
    public static func operationBasedTimeout(
        operationCount: Int,
        secondsPerOperation: Double = 0.1,
        minimumTimeout: TimeInterval = 5.0,
        maximumTimeout: TimeInterval = 300.0
    ) -> TimeInterval {
        let calculatedTimeout = Double(operationCount) * secondsPerOperation
        return min(maximumTimeout, max(minimumTimeout, calculatedTimeout))
    }
    
    /// Creates an exponential backoff timeout provider.
    public static func exponentialBackoff(
        baseTimeout: TimeInterval,
        attempt: Int,
        maxTimeout: TimeInterval = 300.0
    ) -> TimeInterval {
        let timeout = baseTimeout * pow(2.0, Double(attempt - 1))
        return min(timeout, maxTimeout)
    }
}

// MARK: - Testing Support

#if DEBUG
public extension TimeoutMiddleware {
    /// Creates a timeout middleware that can be controlled for testing.
    static func testable(
        timeout: TimeInterval = 1.0,
        onTimeout: @escaping @Sendable () async -> Void = {}
    ) -> TimeoutMiddleware {
        TimeoutMiddleware(
            timeout: timeout,
            timeoutProvider: { _ in timeout }
        )
    }
}
#endif