import Foundation
import PipelineKit
import PipelineKitResilience

private final class QualificationStoreFailure: Error, Sendable {}

private struct QualificationStore: DistributedRateLimitStore {
    let failure: any Error & Sendable
    func incrementAndGet(key: String, windowSize: TimeInterval) async throws -> Int { 1 }
    func getCount(key: String, windowSize: TimeInterval) async throws -> Int { throw failure }
    func reset(key: String) async throws {}
}

func qualificationContracts() async throws {
    let failure = QualificationStoreFailure()
    let limiter = RateLimiter(strategy: .distributed(
        store: QualificationStore(failure: failure), windowSize: 60, maxRequests: 10
    ))
    var statusError: (any Error)?
    do {
        _ = try await limiter.getStatus(identifier: "customer")
    } catch {
        statusError = error
    }
    try require((statusError as? QualificationStoreFailure) === failure, "status query replaced its store failure")

    let cancelled = RateLimiter(strategy: .distributed(
        store: QualificationStore(failure: CancellationError()), windowSize: 60, maxRequests: 10
    ))
    var cancellationPropagated = false
    do {
        _ = try await cancelled.getStatus(identifier: "customer")
    } catch is CancellationError {
        cancellationPropagated = true
    }
    try require(cancellationPropagated, "status query swallowed cancellation")
    try emit(["mode": "qualification", "statusFailures": "propagated"])
}
