import Foundation
import PipelineKitCore
import PipelineKitObservability

/// Middleware that provides configurable retry logic with various backoff strategies
///
/// Supports multiple backoff strategies:
/// - **Fixed**: Wait a constant time between retries
/// - **Linear**: Increase wait time linearly
/// - **Exponential**: Double wait time after each retry
/// - **Jittered**: Add randomness to prevent thundering herd
///
/// ## Example Usage
/// ```swift
/// let retry = RetryMiddleware(
///     maxAttempts: 3,
///     strategy: .exponential(baseDelay: 1.0, maxDelay: 30.0)
/// )
/// pipeline.use(retry)
/// ```
public struct RetryMiddleware: Middleware {
    public let priority: ExecutionPriority = .resilience
    
    // MARK: - Backoff Strategies
    
    /// Strategy for calculating delay between retry attempts
    public enum BackoffStrategy: Sendable {
        /// Fixed delay between retries
        case fixed(delay: TimeInterval)
        
        /// Linear backoff (delay = attempt * baseDelay)
        case linear(baseDelay: TimeInterval, maxDelay: TimeInterval)
        
        /// Exponential backoff (delay = baseDelay * 2^(attempt-1))
        case exponential(baseDelay: TimeInterval, maxDelay: TimeInterval)
        
        /// Exponential with jitter to prevent thundering herd
        case exponentialJitter(baseDelay: TimeInterval, maxDelay: TimeInterval)
        
        /// Custom backoff function
        case custom(@Sendable (Int) -> TimeInterval)
        
        func delay(for attempt: Int) -> TimeInterval {
            switch self {
            case .fixed(let delay):
                return delay
                
            case .linear(let baseDelay, let maxDelay):
                return min(Double(attempt) * baseDelay, maxDelay)
                
            case .exponential(let baseDelay, let maxDelay):
                let exponentialDelay = baseDelay * pow(2.0, Double(attempt - 1))
                return min(exponentialDelay, maxDelay)
                
            case .exponentialJitter(let baseDelay, let maxDelay):
                let exponentialDelay = baseDelay * pow(2.0, Double(attempt - 1))
                let jitteredDelay = exponentialDelay * (0.5 + Double.random(in: 0...0.5))
                return min(jitteredDelay, maxDelay)
                
            case .custom(let function):
                return function(attempt)
            }
        }
    }
    
    // MARK: - Configuration
    
    public struct Configuration: Sendable {
        /// Maximum number of retry attempts (not including the initial attempt)
        public let maxAttempts: Int
        
        /// Backoff strategy to use
        public let strategy: BackoffStrategy
        
        /// Types of errors that should trigger a retry
        public let retryableErrors: Set<RetryableError.ErrorType>
        
        /// Custom error evaluator
        public let errorEvaluator: (@Sendable (Error) -> Bool)?
        
        /// Whether to emit observability events
        public let emitEvents: Bool
        
        /// Maximum total time allowed for all retry attempts
        public let maxRetryTime: TimeInterval?
        
        public init(
            maxAttempts: Int = 3,
            strategy: BackoffStrategy = .exponentialJitter(baseDelay: 1.0, maxDelay: 30.0),
            retryableErrors: Set<RetryableError.ErrorType> = [.timeout, .networkError, .temporaryFailure],
            errorEvaluator: (@Sendable (Error) -> Bool)? = nil,
            emitEvents: Bool = true,
            maxRetryTime: TimeInterval? = nil
        ) {
            self.maxAttempts = maxAttempts
            self.strategy = strategy
            self.retryableErrors = retryableErrors
            self.errorEvaluator = errorEvaluator
            self.emitEvents = emitEvents
            self.maxRetryTime = maxRetryTime
        }
    }
    
    private let configuration: Configuration
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    public init(
        maxAttempts: Int = 3,
        strategy: BackoffStrategy = .exponentialJitter(baseDelay: 1.0, maxDelay: 30.0)
    ) {
        self.init(
            configuration: Configuration(
                maxAttempts: maxAttempts,
                strategy: strategy
            )
        )
    }
    
    // MARK: - Middleware Implementation
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let commandType = String(describing: type(of: command))
        let startTime = Date()
        var lastError: Error?
        
        for attempt in 0...configuration.maxAttempts {
            // Check max retry time
            if let maxTime = configuration.maxRetryTime {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > maxTime {
                    await emitMaxTimeExceeded(
                        commandType: commandType,
                        attempts: attempt,
                        context: context
                    )
                    throw lastError ?? RetryError.maxRetryTimeExceeded
                }
            }
            
            do {
                // Log retry attempt if not the first
                if attempt > 0 {
                    await emitRetryAttempt(
                        commandType: commandType,
                        attempt: attempt,
                        context: context
                    )
                }
                
                // Execute the command
                let result = try await next(command, context)
                
                // Success - log if it was a retry
                if attempt > 0 {
                    await emitRetrySuccess(
                        commandType: commandType,
                        attempts: attempt,
                        context: context
                    )
                }
                
                return result
            } catch {
                lastError = error
                
                // Check if we should retry
                guard attempt < configuration.maxAttempts,
                      shouldRetry(error: error) else {
                    // Don't retry - either max attempts reached or non-retryable error
                    if attempt > 0 {
                        await emitRetryExhausted(
                            commandType: commandType,
                            attempts: attempt,
                            error: error,
                            context: context
                        )
                    }
                    throw error
                }
                
                // Calculate delay
                let delay = configuration.strategy.delay(for: attempt + 1)
                
                // Wait before retry
                await emitRetryDelay(
                    commandType: commandType,
                    attempt: attempt + 1,
                    delay: delay,
                    error: error,
                    context: context
                )
                
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        // Should never reach here, but throw last error if we do
        throw lastError ?? RetryError.unexpectedState
    }
    
    // MARK: - Private Methods
    
    private func shouldRetry(error: Error) -> Bool {
        // Check cancellation first
        if error is CancellationError {
            return false
        }
        
        // Check custom evaluator
        if let evaluator = configuration.errorEvaluator {
            return evaluator(error)
        }
        
        // Check retryable errors
        if let retryableError = error as? RetryableError {
            return configuration.retryableErrors.contains(retryableError.errorType)
        }
        
        // Map common errors
        switch error {
        case let urlError as URLError:
            return shouldRetryURLError(urlError)
        default:
            // Check for timeout in error description
            if error.localizedDescription.lowercased().contains("timeout") {
                return configuration.retryableErrors.contains(.timeout)
            }
            // Default to not retrying unknown errors
            return false
        }
    }
    
    private func shouldRetryURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut:
            return configuration.retryableErrors.contains(.timeout)
        case .networkConnectionLost, .notConnectedToInternet:
            return configuration.retryableErrors.contains(.networkError)
        case .badServerResponse, .cannotLoadFromNetwork:
            return configuration.retryableErrors.contains(.temporaryFailure)
        default:
            return false
        }
    }
    
    // MARK: - Observability Events
    
    private func emitRetryAttempt(
        commandType: String,
        attempt: Int,
        context: CommandContext
    ) async {
        guard configuration.emitEvents else { return }
        
        await context.emitCustomEvent(
            "retry_attempt",
            properties: [
                "command_type": commandType,
                "attempt": attempt,
                "max_attempts": configuration.maxAttempts
            ]
        )
    }
    
    private func emitRetryDelay(
        commandType: String,
        attempt: Int,
        delay: TimeInterval,
        error: Error,
        context: CommandContext
    ) async {
        guard configuration.emitEvents else { return }
        
        await context.emitCustomEvent(
            "retry_delay",
            properties: [
                "command_type": commandType,
                "attempt": attempt,
                "delay_seconds": delay,
                "error_type": String(describing: type(of: error)),
                "error_message": error.localizedDescription
            ]
        )
    }
    
    private func emitRetrySuccess(
        commandType: String,
        attempts: Int,
        context: CommandContext
    ) async {
        guard configuration.emitEvents else { return }
        
        await context.emitCustomEvent(
            "retry_success",
            properties: [
                "command_type": commandType,
                "total_attempts": attempts + 1,
                "retries": attempts
            ]
        )
    }
    
    private func emitRetryExhausted(
        commandType: String,
        attempts: Int,
        error: Error,
        context: CommandContext
    ) async {
        guard configuration.emitEvents else { return }
        
        await context.emitCustomEvent(
            "retry_exhausted",
            properties: [
                "command_type": commandType,
                "total_attempts": attempts + 1,
                "max_attempts": configuration.maxAttempts,
                "final_error": String(describing: error)
            ]
        )
    }
    
    private func emitMaxTimeExceeded(
        commandType: String,
        attempts: Int,
        context: CommandContext
    ) async {
        guard configuration.emitEvents else { return }
        
        await context.emitCustomEvent(
            "retry_max_time_exceeded",
            properties: [
                "command_type": commandType,
                "attempts": attempts,
                "max_time": configuration.maxRetryTime ?? 0
            ]
        )
    }
}

// MARK: - Retry Errors

/// Errors that can be retried
public struct RetryableError: Error, LocalizedError {
    public enum ErrorType: String, Sendable {
        case timeout
        case networkError
        case temporaryFailure
        case serverError
        case resourceUnavailable
    }
    
    public let errorType: ErrorType
    public let message: String
    
    public var errorDescription: String? {
        return message
    }
}

/// Errors specific to retry functionality
public enum RetryError: Error, LocalizedError {
    case maxRetryTimeExceeded
    case unexpectedState
    
    public var errorDescription: String? {
        switch self {
        case .maxRetryTimeExceeded:
            return "Maximum retry time exceeded"
        case .unexpectedState:
            return "Retry middleware reached unexpected state"
        }
    }
}

// MARK: - Public API Extensions

public extension RetryMiddleware {
    /// Creates retry middleware optimized for network requests
    static func forNetworkRequests() -> RetryMiddleware {
        RetryMiddleware(
            configuration: Configuration(
                maxAttempts: 3,
                strategy: .exponentialJitter(baseDelay: 1.0, maxDelay: 10.0),
                retryableErrors: [.timeout, .networkError, .temporaryFailure]
            )
        )
    }
    
    /// Creates retry middleware for database operations
    static func forDatabaseOperations() -> RetryMiddleware {
        RetryMiddleware(
            configuration: Configuration(
                maxAttempts: 2,
                strategy: .exponential(baseDelay: 0.5, maxDelay: 5.0),
                retryableErrors: [.timeout, .resourceUnavailable]
            )
        )
    }
    
    /// Creates retry middleware with aggressive retry policy
    static func aggressive() -> RetryMiddleware {
        RetryMiddleware(
            configuration: Configuration(
                maxAttempts: 5,
                strategy: .exponentialJitter(baseDelay: 0.5, maxDelay: 30.0),
                retryableErrors: [.timeout, .networkError, .temporaryFailure, .serverError],
                maxRetryTime: 120.0
            )
        )
    }
    
    /// Creates retry middleware that only retries on specific HTTP status codes
    static func forHTTPStatusCodes(_ statusCodes: Set<Int>) -> RetryMiddleware {
        RetryMiddleware(
            configuration: Configuration(
                maxAttempts: 3,
                strategy: .exponentialJitter(baseDelay: 1.0, maxDelay: 10.0),
                errorEvaluator: { error in
                    // Check if error contains HTTP status code
                    if let httpError = error as? HTTPError {
                        return statusCodes.contains(httpError.statusCode)
                    }
                    return false
                }
            )
        )
    }
}

// Example HTTP error for demonstration
private struct HTTPError: Error {
    let statusCode: Int
}