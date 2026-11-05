import XCTest
import PipelineKit
import PipelineKitResilience
import PipelineKitSecurity

final class SecureDispatcherStatusContractTests: XCTestCase {
    func testUnconfiguredDispatcherStatusRemainsAbsent() async throws {
        let dispatcher = SecureCommandDispatcher(pipeline: DynamicPipeline())
        let status = try await dispatcher.getRateLimitStatus(userID: "user", commandType: "Command")
        XCTAssertNil(status)
    }

    func testStatusAndDeniedDispatchPreserveStoreErrorsAndCancellation() async {
        let failures: [any Error & Sendable] = [DispatcherStatusFailure.expected, CancellationError()]
        for failure in failures {
            let limiter = RateLimiter(strategy: .distributed(
                store: DispatcherStatusStore(failure: failure), windowSize: 60, maxRequests: 1
            ))
            let dispatcher = SecureCommandDispatcher(pipeline: DynamicPipeline(), rateLimiter: limiter)
            for directQuery in [true, false] {
                do {
                    if directQuery {
                        _ = try await dispatcher.getRateLimitStatus(userID: "user", commandType: "Command")
                    } else {
                        _ = try await dispatcher.dispatch(DispatcherStatusCommand())
                    }
                    XCTFail("An unavailable status must surface its original error")
                } catch {
                    XCTAssertEqual(error is CancellationError, failure is CancellationError)
                    XCTAssertEqual(error is DispatcherStatusFailure, failure is DispatcherStatusFailure)
                }
            }
        }
    }
}

private struct DispatcherStatusCommand: Command { typealias Result = Int }
private enum DispatcherStatusFailure: Error { case expected }
private struct DispatcherStatusStore: DistributedRateLimitStore {
    let failure: any Error & Sendable
    func incrementAndGet(key: String, windowSize: TimeInterval) async throws -> Int { 2 }
    func getCount(key: String, windowSize: TimeInterval) async throws -> Int { throw failure }
    func reset(key: String) async throws {}
}
