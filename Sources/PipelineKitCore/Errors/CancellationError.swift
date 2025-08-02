import Foundation

/// Error thrown when an operation is cancelled.
///
/// This error is thrown when:
/// - A task is cancelled while waiting for resources
/// - A pipeline execution is cancelled mid-flight
/// - A command execution is interrupted by cancellation
public struct CancellationError: Error, LocalizedError, Sendable {
    /// Optional context about what was cancelled
    public let context: String?
    
    /// Creates a new cancellation error
    /// - Parameter context: Optional context about what operation was cancelled
    public init(context: String? = nil) {
        self.context = context
    }
    
    public var errorDescription: String? {
        if let context = context {
            return "Operation cancelled: \(context)"
        }
        return "Operation cancelled"
    }
}

/// Extension to check for cancellation in async contexts
public extension Task where Success == Never, Failure == Never {
    /// Checks if the current task is cancelled and throws if so
    /// - Parameter context: Optional context for the error
    /// - Throws: CancellationError if the task is cancelled
    static func checkCancellation(context: String? = nil) throws {
        if Task.isCancelled {
            throw PipelineKitCore.CancellationError(context: context)
        }
    }
}