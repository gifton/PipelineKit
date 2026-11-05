import PipelineKit

package enum PipelineFailureCategory {
    case timeout
    case cancelled
    case excluded
    case other
}

package enum ResilienceErrorClassifier {
    package static func classifyPipelineError(_ error: any Error) -> PipelineFailureCategory? {
        if PipelineCancellation.isCancellation(error) { return .cancelled }
        guard let error = error as? PipelineError else { return nil }
        switch error {
        case .timeout, .bulkheadTimeout, .resilience(reason: .timeoutExceeded), .backPressure(reason: .timeout):
            return .timeout
        case .cancelled:
            return .cancelled
        case .validation, .authentication, .authorization, .securityPolicy,
             .rateLimitExceeded, .circuitBreakerOpen, .bulkheadRejected,
             .resilience(reason: .bulkheadFull), .resilience(reason: .circuitBreakerOpen),
             .backPressure(reason: .queueFull), .backPressure(reason: .commandDropped),
             .backPressure(reason: .memoryPressure):
            return .excluded
        default:
            return .other
        }
    }
}
