import XCTest
import PipelineKit
import PipelineKitResilience

final class RateLimitStatusContractTests: XCTestCase {
    func testDistributedStatusBoundsRemainingAtEveryCountBoundary() async throws {
        let cases: [(count: Int, limit: Int, remaining: Int)] = [
            (0, 5, 5), (1, 5, 4), (5, 5, 0), (6, 5, 0), (.max, 5, 0),
            (0, .max, .max), (.max, .max, 0), (0, 0, 0)
        ]
        for fixture in cases {
            let limiter = RateLimiter(strategy: .distributed(
                store: StatusContractStore(count: fixture.count, failure: nil), windowSize: 60, maxRequests: fixture.limit
            ))
            let status = try await limiter.getStatus(identifier: "key")
            XCTAssertEqual(status.remaining, fixture.remaining)
            XCTAssertEqual(status.limit, fixture.limit)
        }
    }

    func testBothRateMiddlewareVariantsPropagateStatusErrorsWithoutCallingNext() async {
        let failures: [any Error & Sendable] = [StatusStoreFailure.expected, CancellationError()]
        for failure in failures {
            let limiter = RateLimiter(strategy: .distributed(
                store: StatusContractStore(count: 10, failure: failure), windowSize: 60, maxRequests: 5
            ))
            let middlewares: [any Middleware] = [
                RateLimitingMiddleware(limiter: limiter), EnhancedRateLimitingMiddleware(limiter: limiter)
            ]
            for middleware in middlewares {
                let context = CommandContext()
                do {
                    _ = try await middleware.execute(StatusContractCommand(), context: context) { _, _ in
                        XCTFail("A denied request must not reach its handler")
                        return 1
                    }
                    XCTFail("Status error must be surfaced")
                } catch {
                    XCTAssertEqual(error is CancellationError, failure is CancellationError)
                    XCTAssertEqual(error is StatusStoreFailure, failure is StatusStoreFailure)
                }
                XCTAssertNil(context.getMetadata("rateLimitStatus"), "Unavailable status must not be stored as factual metadata")
            }
        }
    }

    func testStatusObservesCancellationWhenStoreReturnsWithoutThrowing() async {
        let limiter = RateLimiter(strategy: .distributed(
            store: CancellingStatusContractStore(), windowSize: 60, maxRequests: 5
        ))
        let query = Task { try await limiter.getStatus(identifier: "key") }
        do {
            _ = try await query.value
            XCTFail("Cancellation must be checked after the store suspension")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    func testDistributedStatusPreservesStoreErrorAndCancellation() async {
        let errors: [any Error & Sendable] = [StatusStoreFailure.expected, CancellationError()]
        for failure in errors {
            let limiter = RateLimiter(strategy: .distributed(
                store: StatusContractStore(count: 0, failure: failure), windowSize: 60, maxRequests: 5
            ))
            do {
                _ = try await limiter.getStatus(identifier: "key")
                XCTFail("Unavailable status must not advertise a fabricated full budget")
            } catch {
                XCTAssertEqual(error is CancellationError, failure is CancellationError)
                XCTAssertEqual(error is StatusStoreFailure, failure is StatusStoreFailure)
            }
        }
    }

    func testDistributedStatusRejectsNegativeCounts() async {
        for count in [-1, Int.min] {
            let limiter = RateLimiter(strategy: .distributed(
                store: StatusContractStore(count: count, failure: nil), windowSize: 60, maxRequests: 5
            ))
            do {
                _ = try await limiter.getStatus(identifier: "key")
                XCTFail("A malformed store count must not become a valid status")
            } catch let error as PipelineError {
                guard case .validation(let field, _) = error else {
                    return XCTFail("Expected validation error, received \(error)")
                }
                XCTAssertEqual(field, "count")
            } catch {
                XCTFail("Expected validation error, received \(error)")
            }
        }
    }
}

private enum StatusStoreFailure: Error { case expected }
private struct StatusContractCommand: Command { typealias Result = Int }

private struct StatusContractStore: DistributedRateLimitStore {
    let count: Int
    let failure: (any Error & Sendable)?
    func incrementAndGet(key: String, windowSize: TimeInterval) async throws -> Int { count }
    func getCount(key: String, windowSize: TimeInterval) async throws -> Int {
        if let failure { throw failure }
        return count
    }
    func reset(key: String) async throws {}
}

private struct CancellingStatusContractStore: DistributedRateLimitStore {
    func incrementAndGet(key: String, windowSize: TimeInterval) async throws -> Int { 0 }
    func getCount(key: String, windowSize: TimeInterval) async throws -> Int {
        withUnsafeCurrentTask { $0?.cancel() }
        return 0
    }
    func reset(key: String) async throws {}
}
