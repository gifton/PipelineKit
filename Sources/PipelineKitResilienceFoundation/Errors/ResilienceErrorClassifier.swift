import PipelineKit

package enum PipelineFailureCategory {
    case timeout
    case cancelled
    case other
}

package enum ResilienceErrorClassifier {
    package static func classifyPipelineError(_ error: any Error) -> PipelineFailureCategory? {
        guard let error = error as? PipelineError else { return nil }
        switch error {
        case .timeout, .bulkheadTimeout, .resilience(reason: .timeoutExceeded), .backPressure(reason: .timeout):
            return .timeout
        case .cancelled:
            return .cancelled
        default:
            return .other
        }
    }
}
