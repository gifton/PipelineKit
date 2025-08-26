import Foundation

/// Defines retry behavior for command execution failures.
public struct RetryPolicy: Sendable {
    /// Maximum number of retry attempts
    public let maxAttempts: Int
    
    /// Delay strategy between retries
    public let delayStrategy: DelayStrategy
    
    /// Determines if an error should trigger a retry
    public let shouldRetry: @Sendable (Error) -> Bool
    
    /// Creates a retry policy.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum retry attempts (default: 3)
    ///   - delayStrategy: How to calculate delays between retries
    ///   - shouldRetry: Predicate to determine if error is retryable
    public init(
        maxAttempts: Int = 3,
        delayStrategy: DelayStrategy = .exponentialBackoff(base: 0.1, multiplier: 2.0, maxDelay: 10.0),
        shouldRetry: @escaping @Sendable (Error) -> Bool = { _ in true }
    ) {
        self.maxAttempts = maxAttempts
        self.delayStrategy = delayStrategy
        self.shouldRetry = shouldRetry
    }
    
    /// No retry policy - fail immediately on first error.
    public static let none = RetryPolicy(maxAttempts: 1, shouldRetry: { _ in false })
    
    /// Default retry policy with exponential backoff.
    public static let `default` = RetryPolicy()
    
    /// Aggressive retry policy for critical operations.
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        delayStrategy: .exponentialBackoff(base: 0.05, multiplier: 1.5, maxDelay: 5.0)
    )
    
    /// Conservative retry policy for expensive operations.
    public static let conservative = RetryPolicy(
        maxAttempts: 2,
        delayStrategy: .fixed(1.0),
        shouldRetry: { error in
            // Only retry for specific error types
            // Check if it's a PipelineError that's retryable
            if let pipelineError = error as? PipelineError {
                return pipelineError.isRetryable
            }
            // For other errors, don't retry by default
            return false
        }
    )
}

/// Strategy for calculating delays between retry attempts.
public enum DelayStrategy: Sendable {
    /// Fixed delay between all attempts
    case fixed(TimeInterval)
    
    /// Linear increase in delay (attempt * base)
    case linear(base: TimeInterval)
    
    /// Exponential backoff with optional jitter
    case exponentialBackoff(base: TimeInterval, multiplier: Double, maxDelay: TimeInterval, jitter: Double = 0.1)
    
    /// No delay between attempts
    case immediate
    
    /// Calculates the delay for a given attempt number.
    ///
    /// - Parameter attempt: The attempt number (1-based)
    /// - Returns: The delay in seconds before the next attempt
    public func delay(for attempt: Int) -> TimeInterval {
        switch self {
        case .immediate:
            return 0
            
        case .fixed(let interval):
            return interval
            
        case .linear(let base):
            return base * Double(attempt)
            
        case let .exponentialBackoff(base, multiplier, maxDelay, jitter):
            let exponentialDelay = base * pow(multiplier, Double(attempt - 1))
            let cappedDelay = min(exponentialDelay, maxDelay)
            
            // Add jitter to avoid thundering herd
            let jitterAmount = cappedDelay * jitter * Double.random(in: -1...1)
            return max(0, cappedDelay + jitterAmount)
        }
    }
}


/// Comprehensive error recovery context.
public struct ErrorRecoveryContext: Sendable {
    /// The type name of the command that failed
    public let commandType: String
    
    /// The error that occurred
    public let error: Error
    
    /// Current attempt number (1-based)
    public let attempt: Int
    
    /// Total elapsed time since first attempt
    public let totalElapsedTime: TimeInterval
    
    /// Whether this is the final attempt
    public let isFinalAttempt: Bool
    
    public init<T: Command>(
        command: T,
        error: Error,
        attempt: Int,
        totalElapsedTime: TimeInterval,
        isFinalAttempt: Bool
    ) {
        self.commandType = String(describing: T.self)
        self.error = error
        self.attempt = attempt
        self.totalElapsedTime = totalElapsedTime
        self.isFinalAttempt = isFinalAttempt
    }
}
