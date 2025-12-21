import Foundation
import PipelineKit
import PipelineKitResilience
#if canImport(os)
import os.log
#endif

/// A security-focused command dispatcher with built-in protection mechanisms.
/// 
/// The `SecureCommandDispatcher` wraps a `DynamicPipeline` and adds security features:
/// - Sophisticated rate limiting with multiple strategies
/// - Circuit breaker pattern for failure protection
/// - Sanitized error messages to prevent information leakage
/// - Structured logging for security auditing
/// 
/// This dispatcher is designed for use in security-sensitive environments where
/// command execution needs to be monitored and controlled.
/// 
/// Example:
/// ```swift
/// let pipeline = DynamicPipeline()
/// let rateLimiter = RateLimiter(
///     strategy: .tokenBucket(capacity: 100, refillRate: 10),
///     scope: .perUser
/// )
/// let dispatcher = SecureCommandDispatcher(pipeline: pipeline, rateLimiter: rateLimiter)
/// 
/// // Dispatch commands with automatic rate limiting
/// let result = try await dispatcher.dispatch(
///     CreateUserCommand(email: "user@example.com"),
///     metadata: DefaultCommandMetadata(userId: "admin123")
/// )
/// ```
public actor SecureCommandDispatcher {
    private let pipeline: DynamicPipeline
    #if canImport(os)
    private let logger = Logger(subsystem: "PipelineKit", category: "SecureDispatcher")
    #endif
    private let rateLimiter: RateLimiter?
    // Circuit breaker functionality now available via CircuitBreakerMiddleware
    
    /// Creates a secure dispatcher wrapping the given command bus.
    /// 
    /// - Parameters:
    ///   - pipeline: The dynamic pipeline to wrap with security features
    ///   - rateLimiter: Optional rate limiter for DoS protection
    /// 
    /// Note: Circuit breaker functionality is now available via CircuitBreakerMiddleware.
    /// Add it to your pipeline for circuit breaking behavior.
    public init(
        pipeline: DynamicPipeline,
        rateLimiter: RateLimiter? = nil
    ) {
        self.pipeline = pipeline
        self.rateLimiter = rateLimiter
    }
    
    /// Dispatches a command with security protections.
    /// 
    /// This method adds rate limiting and error sanitization on top of
    /// the standard command bus execution.
    /// 
    /// - Parameters:
    ///   - command: The command to dispatch
    ///   - metadata: Optional metadata for the command execution
    /// - Returns: The result of executing the command
    /// - Throws: `SecureDispatcherError.rateLimitExceeded` if rate limit is hit,
    ///           `SecureDispatcherError.executionFailed` with sanitized error message
    public func dispatch<T: Command>(
        _ command: T,
        metadata: (any CommandMetadata)? = nil
    ) async throws -> T.Result {
        let commandType = String(describing: T.self)
        let executionMetadata = metadata ?? DefaultCommandMetadata()
        
        // Note: Circuit breaker functionality now available via CircuitBreakerMiddleware
        
        // Apply rate limiting
        if let limiter = rateLimiter {
            // Use userID from metadata for rate limiting, defaulting to "unknown" for anonymous requests
            let identifier = metadata?.userID ?? "unknown"
            let allowed = try await limiter.allowRequest(
                identifier: "\(identifier):\(commandType)",
                cost: calculateCommandCost(command)
            )
            
            guard allowed else {
                let status = await limiter.getStatus(identifier: "\(identifier):\(commandType)")
                #if canImport(os)
                logger.warning("Rate limit exceeded for: \(identifier, privacy: .private) - \(commandType, privacy: .public)")
#endif
                throw PipelineError.rateLimitExceeded(
                    limit: status.limit,
                    resetTime: status.resetAt,
                    retryAfter: nil
                )
            }
        }
        
        #if canImport(os)
        logger.debug("Dispatching command: \(commandType, privacy: .public)")
#endif
        
        do {
            let result = try await pipeline.send(command, context: CommandContext(metadata: executionMetadata))
            #if canImport(os)
            logger.debug("Command executed successfully: \(commandType, privacy: .public)")
#endif
            
            return result
        } catch {
            #if canImport(os)
            logger.error("Command execution failed: \(commandType, privacy: .public)")
#endif
            
            throw PipelineError.executionFailed(
                message: sanitizeError(error),
                context: PipelineError.ErrorContext(
                    commandType: String(describing: type(of: command))
                )
            )
        }
    }
    
    /// Calculates the cost of a command for rate limiting.
    /// 
    /// Override this method to provide custom cost calculation based on command type
    /// or complexity. Default implementation returns 1.0 for all commands.
    /// 
    /// - Parameter command: The command to calculate cost for
    /// - Returns: The cost value for rate limiting
    private func calculateCommandCost<T: Command>(_ command: T) -> Double {
        // Default implementation - can be customized based on command type
        switch command {
        default:
            return 1.0
        }
    }
    
    /// Sanitizes error messages to prevent information leakage.
    /// 
    /// - Parameter error: The error to sanitize
    /// - Returns: A safe error message suitable for external consumption
    private func sanitizeError(_ error: any Error) -> String {
        switch error {
        case PipelineError.handlerNotFound:
            return "Command handler not found"
        case PipelineError.executionFailed:
            return "Command execution failed"
        case PipelineError.middlewareError:
            return "Middleware processing error"
        case PipelineError.maxDepthExceeded:
            return "Maximum processing depth exceeded"
        case is PipelineError:
            return "Command processing error"
        default:
            return "An error occurred during command execution"
        }
    }
    
    /// Gets the current rate limit status for a user and command type.
    /// 
    /// - Parameters:
    ///   - userID: The user identifier
    ///   - commandType: The command type
    /// - Returns: The current rate limit status, if a rate limiter is configured
    public func getRateLimitStatus(
        userID: String,
        commandType: String
    ) async -> RateLimitStatus? {
        guard let limiter = rateLimiter else { return nil }
        return await limiter.getStatus(identifier: "\(userID):\(commandType)")
    }
}
