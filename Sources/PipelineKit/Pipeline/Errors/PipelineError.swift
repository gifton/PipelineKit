import Foundation

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
    
    /// Creates an execution failed error.
    /// - Parameter message: The error message.
    /// - Returns: A PipelineError instance.
    @available(*, deprecated, message: "Use PipelineError(underlyingError:command:middleware:) instead")
    public static func executionFailed(_ message: String) -> PipelineError {
        struct ExecutionError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        
        // Create a placeholder command for the error
        struct PlaceholderCommand: Command {
            typealias Result = Void
            func execute() async throws -> Void {}
        }
        
        return PipelineError(
            underlyingError: ExecutionError(message: message),
            command: PlaceholderCommand(),
            middleware: nil
        )
    }
}
