import Foundation

/// Errors that can occur during command bus operations.
public enum CommandBusError: Error, Sendable, Equatable, Hashable, LocalizedError {
    /// No handler is registered for the command type
    case handlerNotFound(String)
    
    /// Command execution failed
    case executionFailed(String)
    
    /// Middleware execution failed
    case middlewareError(String)
    
    /// Maximum middleware depth exceeded
    case maxMiddlewareDepthExceeded(maxDepth: Int)
    
    /// Unknown error occurred during processing
    case unknownError
    
    public var errorDescription: String? {
        switch self {
        case .handlerNotFound(let commandType):
            return "No handler registered for command type: \(commandType)"
        case .executionFailed(let message):
            return "Command execution failed: \(message)"
        case .middlewareError(let message):
            return "Middleware error: \(message)"
        case .maxMiddlewareDepthExceeded(let maxDepth):
            return "Maximum middleware depth exceeded. Maximum allowed: \(maxDepth)"
        case .unknownError:
            return "An unknown error occurred during command processing"
        }
    }
}

/// Errors related to circuit breaker functionality.
public enum CircuitBreakerError: Error, Sendable, Equatable, LocalizedError {
    case circuitOpen
    
    public var errorDescription: String? {
        switch self {
        case .circuitOpen:
            return "Circuit breaker is open - failing fast to prevent cascading failures"
        }
    }
}