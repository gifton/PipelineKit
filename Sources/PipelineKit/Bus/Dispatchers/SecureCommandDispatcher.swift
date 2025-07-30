import Foundation
import os.log

/// A security-focused command dispatcher with built-in protection mechanisms.
/// 
/// The `SecureCommandDispatcher` wraps a `CommandBus` and adds security features:
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
/// let bus = CommandBus()
/// let rateLimiter = RateLimiter(
///     strategy: .tokenBucket(capacity: 100, refillRate: 10),
///     scope: .perUser
/// )
/// let dispatcher = SecureCommandDispatcher(bus: bus, rateLimiter: rateLimiter)
/// 
/// // Dispatch commands with automatic rate limiting
/// let result = try await dispatcher.dispatch(
///     CreateUserCommand(email: "user@example.com"),
///     metadata: StandardCommandMetadata(userId: "admin123")
/// )
/// ```
public actor SecureCommandDispatcher {
    private let bus: CommandBus
    private let logger = Logger(subsystem: "PipelineKit", category: "SecureDispatcher")
    private let rateLimiter: RateLimiter?
    private let circuitBreaker: CircuitBreaker?
    
    /// Creates a secure dispatcher wrapping the given command bus.
    /// 
    /// - Parameters:
    ///   - bus: The command bus to wrap with security features
    ///   - rateLimiter: Optional rate limiter for DoS protection
    ///   - circuitBreaker: Optional circuit breaker for failure protection
    public init(
        bus: CommandBus,
        rateLimiter: RateLimiter? = nil,
        circuitBreaker: CircuitBreaker? = nil
    ) {
        self.bus = bus
        self.rateLimiter = rateLimiter
        self.circuitBreaker = circuitBreaker
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
        metadata: CommandMetadata? = nil
    ) async throws -> T.Result {
        let commandType = String(describing: T.self)
        let executionMetadata = metadata ?? StandardCommandMetadata()
        
        // Check circuit breaker first
        if let breaker = circuitBreaker {
            guard await breaker.shouldAllow() else {
                logger.warning("Circuit breaker open for command: \(commandType, privacy: .public)")
                throw SecureDispatcherError.circuitBreakerOpen
            }
        }
        
        // Apply rate limiting
        if let limiter = rateLimiter {
            // TODO: Gifton - should this casting be to this specific type?
            let identifier = metadata?.userId ?? "unknown"
            let allowed = try await limiter.allowRequest(
                identifier: "\(identifier):\(commandType)",
                cost: calculateCommandCost(command)
            )
            
            guard allowed else {
                let status = await limiter.getStatus(identifier: "\(identifier):\(commandType)")
                logger.warning("Rate limit exceeded for: \(identifier, privacy: .private) - \(commandType, privacy: .public)")
                throw SecureDispatcherError.rateLimitExceeded(
                    commandType,
                    resetAt: status.resetAt
                )
            }
        }
        
        logger.debug("Dispatching command: \(commandType, privacy: .public)")
        
        do {
            let result = try await bus.send(command, context: CommandContext(metadata: executionMetadata))
            logger.debug("Command executed successfully: \(commandType, privacy: .public)")
            
            // Record success for circuit breaker
            if let breaker = circuitBreaker {
                await breaker.recordSuccess()
            }
            
            return result
        } catch {
            logger.error("Command execution failed: \(commandType, privacy: .public)")
            
            // Record failure for circuit breaker
            if let breaker = circuitBreaker {
                await breaker.recordFailure()
            }
            
            throw SecureDispatcherError.executionFailed(sanitizeError(error))
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
    private func sanitizeError(_ error: Error) -> String {
        switch error {
        case CommandBusError.handlerNotFound:
            return "Command handler not found"
        case CommandBusError.executionFailed:
            return "Command execution failed"
        case CommandBusError.middlewareError:
            return "Middleware processing error"
        case CommandBusError.maxMiddlewareDepthExceeded:
            return "Maximum processing depth exceeded"
        case is CommandBusError:
            return "Command processing error"
        default:
            return "An error occurred during command execution"
        }
    }
    
    /// Gets the current rate limit status for a user and command type.
    /// 
    /// - Parameters:
    ///   - userId: The user identifier
    ///   - commandType: The command type
    /// - Returns: The current rate limit status, if a rate limiter is configured
    public func getRateLimitStatus(
        userId: String,
        commandType: String
    ) async -> RateLimitStatus? {
        guard let limiter = rateLimiter else { return nil }
        return await limiter.getStatus(identifier: "\(userId):\(commandType)")
    }
    
    /// Gets the current circuit breaker state.
    /// 
    /// - Returns: The circuit breaker state, if configured
    public func getCircuitBreakerState() async -> CircuitBreaker.State? {
        guard let breaker = circuitBreaker else { return nil }
        return await breaker.getState()
    }
}

/// Errors specific to secure command dispatching.
public enum SecureDispatcherError: Error, Sendable {
    /// Rate limit exceeded for a specific command type
    case rateLimitExceeded(String, resetAt: Date)
    
    /// Command execution failed with sanitized error message
    case executionFailed(String)
    
    /// Unauthorized command execution attempt
    case unauthorized
    
    /// Circuit breaker is open
    case circuitBreakerOpen
    
    public var localizedDescription: String {
        switch self {
        case let .rateLimitExceeded(command, resetAt):
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            return "Rate limit exceeded for \(command). Try again at \(formatter.string(from: resetAt))"
        case let .executionFailed(message):
            return message
        case .unauthorized:
            return "Unauthorized command execution"
        case .circuitBreakerOpen:
            return "Service temporarily unavailable"
        }
    }
}
