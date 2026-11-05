import Foundation

/// Extension to check for cancellation in async contexts
public extension Task where Success == Never, Failure == Never {
    /// Checks if the current task is cancelled and throws if so
    /// - Parameter context: Optional context for the error
    /// - Throws: PipelineError.cancelled if the task is cancelled
    static func checkCancellation(context: String? = nil) throws {
        try PipelineCancellation.check(message: context)
    }
}

/// Package boundaries share direct cancellation recognition and outward error identity.
package enum PipelineCancellation {
    package static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? PipelineError)?.isCancellation == true
    }

    package static func check(context: CommandContext? = nil, message: String? = nil) throws {
        guard Task.isCancelled else { return }
        context?.recordCancellationIfAbsent(reason: .userCancellation)
        throw PipelineError.cancelled(context: message)
    }

    /// Normalizes only recognized cancellation; unrelated failures retain their identity
    /// even when the current task is cancelled
    /// (PipelineCancellationBoundaryTests.testCancellationFlagDoesNotMaskDomainFailure).
    package static func normalize(
        _ error: any Error,
        context: CommandContext? = nil,
        message: String? = nil
    ) -> any Error {
        guard isCancellation(error) else { return error }
        context?.recordCancellationIfAbsent(reason: .userCancellation)
        if let pipelineError = error as? PipelineError { return pipelineError }
        return PipelineError.cancelled(context: message)
    }
}
