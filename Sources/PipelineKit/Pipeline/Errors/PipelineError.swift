import Foundation

/// Errors that can occur during pipeline operations.
///
/// These errors indicate various failure conditions that can occur when
/// configuring or executing a pipeline.
public enum PipelineError: Error, Sendable, Equatable, Hashable, LocalizedError {
    /// Thrown when a command cannot be cast to the expected type.
    ///
    /// This typically indicates a type mismatch in the pipeline configuration.
    case invalidCommandType
    
    /// Thrown when a handler result cannot be cast to the expected result type.
    ///
    /// This indicates the handler returned a value of an unexpected type.
    case invalidResultType
    
    /// Thrown when attempting to add middleware would exceed the maximum depth limit.
    ///
    /// This safety mechanism prevents stack overflow from excessively deep middleware chains.
    case maxDepthExceeded
    
    /// Thrown when command execution fails with a specific error message.
    ///
    /// - Parameter String: A descriptive error message explaining the failure.
    case executionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidCommandType:
            return "Command could not be cast to the expected type"
        case .invalidResultType:
            return "Handler result could not be cast to the expected result type"
        case .maxDepthExceeded:
            return "Maximum middleware depth exceeded. This may indicate a circular reference."
        case .executionFailed(let message):
            return "Pipeline execution failed: \(message)"
        }
    }
}