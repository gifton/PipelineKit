import Foundation

/// Enumeration of specific error types that can occur during pipeline execution.
///
/// These errors represent various failure scenarios in the command pipeline,
/// from configuration issues to runtime failures.
///
/// - SeeAlso: `PipelineError`
public enum PipelineErrorType: Error, Sendable, LocalizedError {
    case maxDepthExceeded(depth: Int)
    case invalidCommandType
    case timeout(duration: TimeInterval)
    case retryExhausted(attempts: Int)
    case parallelExecutionFailed(errors: [Error])
    case middlewareNotFound(name: String)
    case pipelineNotConfigured
    case contextMissing
    
    public var errorDescription: String? {
        switch self {
        case .maxDepthExceeded(let depth):
            return "Maximum pipeline depth exceeded: \(depth)"
        case .invalidCommandType:
            return "Invalid command type provided to pipeline"
        case .timeout(let duration):
            return "Operation timed out after \(duration) seconds"
        case .retryExhausted(let attempts):
            return "Retry exhausted after \(attempts) attempts"
        case .parallelExecutionFailed(let errors):
            return "Parallel execution failed with \(errors.count) errors"
        case .middlewareNotFound(let name):
            return "Middleware not found: \(name)"
        case .pipelineNotConfigured:
            return "Pipeline not configured"
        case .contextMissing:
            return "Command context is missing"
        }
    }
}

/// A structured error type that provides more context about errors that occur within the pipeline.
public struct PipelineError: Error, Sendable, LocalizedError {
    /// The underlying error that occurred.
    public let underlyingError: Error

    /// The type of command that was being processed when the error occurred.
    public let commandType: String

    /// The middleware that threw the error, if any.
    public let middlewareType: String?

    /// A description of the error.
    public var errorDescription: String? {
        if let middlewareType = middlewareType {
            return "Pipeline error occurred in middleware '\(middlewareType)' while processing command '\(commandType)': \(underlyingError.localizedDescription)"
        } else {
            return "Pipeline error occurred while processing command '\(commandType)': \(underlyingError.localizedDescription)"
        }
    }

    internal init<T: Command>(
        underlyingError: Error,
        command: T,
        middleware: (any Middleware)? = nil
    ) {
        self.underlyingError = underlyingError
        self.commandType = String(describing: T.self)
        if let middleware = middleware {
            self.middlewareType = String(describing: type(of: middleware))
        } else {
            self.middlewareType = nil
        }
    }
    
    
    // MARK: - Static Factory Methods
    
    /// Creates a pipeline error for when the maximum middleware depth is exceeded.
    ///
    /// - Parameters:
    ///   - depth: The depth that was exceeded
    ///   - command: The command being processed
    ///
    /// - Returns: A configured `PipelineError` instance
    public static func maxDepthExceeded<T: Command>(depth: Int, command: T) -> PipelineError {
        PipelineError(
            underlyingError: PipelineErrorType.maxDepthExceeded(depth: depth),
            command: command,
            middleware: nil
        )
    }
    
    /// Creates an invalid command type error.
    public static func invalidCommandType<T: Command>(command: T) -> PipelineError {
        PipelineError(
            underlyingError: PipelineErrorType.invalidCommandType,
            command: command,
            middleware: nil
        )
    }
    
    /// Creates a timeout error.
    public static func timeout<T: Command>(duration: TimeInterval, command: T, middleware: (any Middleware)? = nil) -> PipelineError {
        PipelineError(
            underlyingError: PipelineErrorType.timeout(duration: duration),
            command: command,
            middleware: middleware
        )
    }
    
    /// Creates a retry exhausted error.
    public static func retryExhausted<T: Command>(attempts: Int, command: T, middleware: (any Middleware)? = nil) -> PipelineError {
        PipelineError(
            underlyingError: PipelineErrorType.retryExhausted(attempts: attempts),
            command: command,
            middleware: middleware
        )
    }
}
