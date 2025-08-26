import Foundation

/// Extension to check for cancellation in async contexts
public extension Task where Success == Never, Failure == Never {
    /// Checks if the current task is cancelled and throws if so
    /// - Parameter context: Optional context for the error
    /// - Throws: PipelineError.cancelled if the task is cancelled
    static func checkCancellation(context: String? = nil) throws {
        if Task.isCancelled {
            throw PipelineError.cancelled(context: context)
        }
    }
}
