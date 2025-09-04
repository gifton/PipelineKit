import Foundation

/// Reason for command execution cancellation.
///
/// Provides explicit tracking of why a command was cancelled,
/// enabling better debugging and proper handling of different
/// cancellation scenarios.
public enum CancellationReason: Sendable, Equatable {
    /// Command was cancelled due to timeout
    case timeout(duration: TimeInterval, gracePeriod: TimeInterval?)
    
    /// Command was cancelled by user request
    case userCancellation
    
    /// Command was cancelled due to system shutdown
    case systemShutdown
    
    /// Command was cancelled due to pipeline error
    case pipelineError(String)
    
    /// Command was cancelled due to resource constraints
    case resourceConstraints(String)
    
    /// Generic cancellation with custom reason
    case custom(String)
}

// MARK: - CustomStringConvertible

extension CancellationReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .timeout(duration, gracePeriod):
            if let gracePeriod = gracePeriod {
                return "Timeout after \(duration)s (grace period: \(gracePeriod)s)"
            } else {
                return "Timeout after \(duration)s"
            }
        case .userCancellation:
            return "User cancellation"
        case .systemShutdown:
            return "System shutdown"
        case .pipelineError(let error):
            return "Pipeline error: \(error)"
        case .resourceConstraints(let reason):
            return "Resource constraints: \(reason)"
        case .custom(let reason):
            return reason
        }
    }
}
