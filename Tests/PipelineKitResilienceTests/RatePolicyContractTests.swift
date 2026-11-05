import Foundation
import PipelineKit
import PipelineKitResilience
import XCTest
@testable import _RateLimiting

final class RatePolicyContractTests: XCTestCase {
    private static let scopes: [RateLimitScope] = [.global, .perUser, .perIP, .perCommand]
    private static let window: TimeInterval = 1_000_000_000_000

    func testEnhancedMiddlewareUsesExtractedPriorityForAdmissionAndDenialStatus() async throws {
        let limits: [Priority: Int] = [.low: 0, .medium: 1, .high: 2, .critical: 3]
        for scope in Self.scopes {
            for priority in Priority.allCases {
                let limit = try XCTUnwrap(limits[priority])
                let limiter = makePriorityLimiter(scope: scope, limits: limits)
                let middleware = enhanced(limiter, priority: priority)
                var outcomes: [Bool] = []
                for attempt in 0...limit {
                    let context = CommandContext()
                    do {
                        let result = try await middleware.execute(RatePolicyCommand(), context: context) { _, _ in 7 }
                        XCTAssertEqual(result, 7)
                        outcomes.append(true)
                    } catch PipelineError.rateLimitExceeded(let reportedLimit, _, _) {
                        outcomes.append(false)
                        XCTAssertEqual(reportedLimit, limit, "\(scope), \(priority), attempt \(attempt)")
                        let status = context.getMetadata("rateLimitStatus") as? [String: any Sendable]
                        XCTAssertEqual(status?["limit"] as? Int, limit)
                        XCTAssertEqual(status?["remaining"] as? Int, 0)
                        XCTAssertEqual(context.getMetadata("rateLimitPriority") as? String, priority.rawValue)
                    }
                }
                XCTAssertEqual(outcomes, Array(repeating: true, count: limit) + [false], "\(scope), \(priority)")
            }
        }
    }

    func testEnhancedMiddlewareKeepsPriorityBudgetsIndependent() async throws {
        for scope in Self.scopes {
            let limiter = makePriorityLimiter(scope: scope, limits: [.low: 1, .medium: 1, .high: 1, .critical: 1])
            var firstAdmissions: [Bool] = []
            var repeatedAdmissions: [Bool] = []
            for priority in Priority.allCases {
                firstAdmissions.append(try await admitted(enhanced(limiter, priority: priority)))
            }
            for priority in Priority.allCases {
                repeatedAdmissions.append(try await admitted(enhanced(limiter, priority: priority)))
            }
            XCTAssertEqual(firstAdmissions, [true, true, true, true], "\(scope)")
            XCTAssertEqual(repeatedAdmissions, [false, false, false, false], "\(scope)")
        }
    }

    func testEnhancedMiddlewareRejectsMissingPriorityWithoutConsumingMediumBudget() async throws {
        for scope in Self.scopes {
            let limiter = makePriorityLimiter(scope: scope, limits: [.medium: 1])
            let missing = try await admitted(enhanced(limiter, priority: .high))
            let medium = try await admitted(enhanced(limiter, priority: .medium))
            let exhausted = try await admitted(enhanced(limiter, priority: .medium))
            XCTAssertEqual([missing, medium, exhausted], [false, true, false], "\(scope)")
        }
    }

    func testKeyedPriorityResetRestoresOnlySelectedScopeBudget() async throws {
        for scope in Self.scopes {
            let limiter = makePriorityLimiter(scope: scope, limits: [.medium: 1])
            _ = try await limiter.allowRequest(identifier: "A")
            _ = try await limiter.allowRequest(identifier: "B")
            try await limiter.reset(identifier: "A")
            let statusA = await limiter.getStatus(identifier: "A")
            let statusB = await limiter.getStatus(identifier: "B")
            XCTAssertEqual(statusA.remaining, 1, "\(scope)")
            XCTAssertEqual(statusB.remaining, scope == .global ? 1 : 0, "\(scope)")
            let restored = try await limiter.allowRequest(identifier: "A")
            let preserved = try await limiter.allowRequest(identifier: "B")
            XCTAssertEqual([restored, preserved], [true, false], "\(scope)")
        }
    }

    func testDistributedKeyedResetIsVisibleAcrossLimiterInstances() async throws {
        for scope in Self.scopes {
            let store = InMemoryRateLimitStore()
            let first = distributed(store, scope: scope)
            let second = distributed(store, scope: scope)
            _ = try await first.allowRequest(identifier: "A")
            _ = try await first.allowRequest(identifier: "B")
            try await second.reset(identifier: "A")
            let statusA = await first.getStatus(identifier: "A")
            let statusB = await first.getStatus(identifier: "B")
            XCTAssertEqual(statusA.remaining, 1, "\(scope)")
            XCTAssertEqual(statusB.remaining, scope == .global ? 1 : 0, "\(scope)")
            let restored = try await first.allowRequest(identifier: "A")
            let preserved = try await second.allowRequest(identifier: "B")
            XCTAssertEqual([restored, preserved], [true, false], "\(scope)")
        }
    }

    func testDistributedUnknownKeyResetPreservesOtherIdentifiers() async throws {
        for scope: RateLimitScope in [.perUser, .perIP, .perCommand] {
            let store = InMemoryRateLimitStore()
            let limiter = distributed(store, scope: scope)
            _ = try await limiter.allowRequest(identifier: "A")
            try await limiter.reset(identifier: "unknown")
            let existing = try await limiter.allowRequest(identifier: "A")
            let unknown = try await limiter.allowRequest(identifier: "unknown")
            XCTAssertEqual([existing, unknown], [false, true], "\(scope)")
        }
    }

    func testDistributedGlobalResetAllRestoresSharedCounter() async throws {
        let store = InMemoryRateLimitStore()
        let first = distributed(store, scope: .global)
        let second = distributed(store, scope: .global)
        _ = try await first.allowRequest(identifier: "A")
        try await second.reset()
        let restored = try await first.allowRequest(identifier: "B")
        let exhausted = try await second.allowRequest(identifier: "C")
        XCTAssertEqual([restored, exhausted], [true, false])
    }

    func testExplicitPriorityAdmissionStatusAndResetShareTheSameBudget() async throws {
        for scope in Self.scopes {
            let limiter = makePriorityLimiter(scope: scope, limits: [.low: 1, .medium: 1, .high: 1, .critical: 1])
            for priority in Priority.allCases {
                _ = try await limiter.allowRequest(identifier: "A", priority: priority)
                _ = try await limiter.allowRequest(identifier: "B", priority: priority)
            }
            for priority in Priority.allCases {
                try await limiter.reset(identifier: "A", priority: priority)
                for checkedPriority in Priority.allCases {
                    let status = await limiter.getStatus(identifier: "A", priority: checkedPriority)
                    XCTAssertEqual(status.remaining, checkedPriority == priority ? 1 : 0, "\(scope), \(priority), \(checkedPriority)")
                    XCTAssertEqual(status.limit, 1)
                }
                let statusB = await limiter.getStatus(identifier: "B", priority: priority)
                XCTAssertEqual(statusB.remaining, scope == .global ? 1 : 0)
                let restored = try await limiter.allowRequest(identifier: "A", priority: priority)
                let preserved = try await limiter.allowRequest(identifier: "B", priority: priority)
                XCTAssertEqual([restored, preserved], [true, false])
            }
            try await limiter.reset(priority: .high)
            for priority in Priority.allCases {
                let status = await limiter.getStatus(identifier: "A", priority: priority)
                let restored = try await limiter.allowRequest(identifier: "A", priority: priority)
                XCTAssertEqual(status.remaining, 1)
                XCTAssertTrue(restored, "Nil identifier resets every priority, \(scope), \(priority)")
            }
        }
    }

    func testMissingPriorityRejectsAndDefaultPriorityRemainsMedium() async throws {
        for scope in Self.scopes {
            let limiter = makePriorityLimiter(scope: scope, limits: [.medium: 1])
            let unknown = try await limiter.allowRequest(identifier: "A", priority: .high)
            let status = await limiter.getStatus(identifier: "A", priority: .high)
            try await limiter.reset(identifier: "A", priority: .high)
            let implicitMedium = try await limiter.allowRequest(identifier: "A")
            let explicitMedium = try await limiter.allowRequest(identifier: "A", priority: .medium)
            XCTAssertEqual([unknown, implicitMedium, explicitMedium], [false, true, false])
            XCTAssertEqual(status.limit, 0)
            XCTAssertEqual(status.remaining, 0)
            try await limiter.reset(identifier: "A")
            let restored = try await limiter.allowRequest(identifier: "A", priority: .medium)
            XCTAssertTrue(restored)
        }
    }

    func testPriorityParameterDoesNotPartitionOtherStrategiesOrChangeTheirCostPolicy() async throws {
        for scope in Self.scopes {
            let strategies: [(RateLimitStrategy, Bool)] = [
                (.tokenBucket(capacity: 1, refillRate: 0), true),
                (.adaptive(baseRate: 1, loadFactor: { 1 }), true),
                (.fixedWindow(windowSize: Self.window, maxRequests: 1), false),
                (.slidingWindow(windowSize: Self.window, maxRequests: 1), false),
                (.leakyBucket(capacity: 1, leakRate: Self.window), false),
                (.distributed(store: InMemoryRateLimitStore(), windowSize: Self.window, maxRequests: 1), false)
            ]
            for (strategy, honorsCost) in strategies {
                let limiter = RateLimiter(strategy: strategy, scope: scope, now: { Date(timeIntervalSince1970: 1_000) })
                let first = try await limiter.allowRequest(identifier: "A", cost: 0.5, priority: .high)
                let second = try await limiter.allowRequest(identifier: "A", cost: 0.5, priority: .low)
                let third = try await limiter.allowRequest(identifier: "A", cost: 0.5, priority: .critical)
                XCTAssertEqual([first, second, third], honorsCost ? [true, true, false] : [true, false, false])
                let status = await limiter.getStatus(identifier: "A", priority: .high)
                XCTAssertEqual(status.remaining, 0)
                try await limiter.reset(identifier: "A", priority: .critical)
                let restored = try await limiter.allowRequest(identifier: "A", priority: .low)
                XCTAssertTrue(restored)
            }
        }
    }

    func testDistributedResetAllReachesRemoteKeysAndPreservesOtherScopes() async throws {
        for scope: RateLimitScope in [.perUser, .perIP, .perCommand] {
            let store = InMemoryRateLimitStore()
            let administrator = distributed(store, scope: scope)
            let remote = distributed(store, scope: scope)
            let identifiers = ["", "A", "pipelinekit:rate-limit:v1:global", "A:medium"]
            for identifier in identifiers { _ = try await remote.allowRequest(identifier: identifier) }
            var otherScopes: [RateLimiter] = []
            for otherScope in Self.scopes where otherScope != scope {
                let other = distributed(store, scope: otherScope)
                _ = try await other.allowRequest(identifier: "A")
                otherScopes.append(other)
            }
            let unrelatedKeys = ["application:cache:A", "pipelinekit:rate-limit:v1:userish:A"]
            for key in unrelatedKeys { _ = try await store.incrementAndGet(key: key, windowSize: Self.window) }

            try await administrator.reset()

            for identifier in identifiers {
                let status = await remote.getStatus(identifier: identifier)
                let restored = try await remote.allowRequest(identifier: identifier)
                XCTAssertEqual(status.remaining, 1, "\(scope), \(identifier)")
                XCTAssertTrue(restored)
            }
            for other in otherScopes {
                let preserved = try await other.allowRequest(identifier: "A")
                XCTAssertFalse(preserved)
            }
            for key in unrelatedKeys {
                let count = try await store.getCount(key: key, windowSize: Self.window)
                XCTAssertEqual(count, 1)
            }
        }
    }

    func testDistributedResetAllRequiresCapabilityOnlyForNonGlobalScopes() async throws {
        for scope in Self.scopes {
            let store = KeyOnlyRateStore()
            let limiter = distributed(store, scope: scope)
            _ = try await limiter.allowRequest(identifier: "A")
            do {
                try await limiter.reset()
                XCTAssertEqual(scope, .global)
            } catch RateLimitResetError.resetAllUnsupported {
                XCTAssertNotEqual(scope, .global)
            }
            let admitted = try await limiter.allowRequest(identifier: "A")
            XCTAssertEqual(admitted, scope == .global)
            try await limiter.reset(identifier: "A")
            let restored = try await limiter.allowRequest(identifier: "A")
            XCTAssertTrue(restored, "Key reset remains available without reset-all capability")
        }
    }

    func testDistributedKeyAndResetAllFailuresPreserveOriginalErrorAndCounters() async throws {
        for resetAll in [false, true] {
            let failure = ResetStoreFailure()
            let store = FailingResetRateStore(failure: failure)
            let limiter = distributed(store, scope: .perUser)
            _ = try await limiter.allowRequest(identifier: "A")
            do {
                try await limiter.reset(identifier: resetAll ? nil : "A")
                XCTFail("Store reset failure must be propagated")
            } catch {
                XCTAssertTrue((error as? ResetStoreFailure) === failure)
            }
            let preserved = try await limiter.allowRequest(identifier: "A")
            XCTAssertFalse(preserved)
        }
    }

    private func makePriorityLimiter(scope: RateLimitScope, limits: [Priority: Int]) -> RateLimiter {
        RateLimiter(
            strategy: .priorityBased(limits: limits.mapValues { .init(maxRequests: $0, windowSize: Self.window) }),
            scope: scope,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func enhanced(_ limiter: RateLimiter, priority: Priority) -> EnhancedRateLimitingMiddleware {
        EnhancedRateLimitingMiddleware(
            limiter: limiter,
            identifierExtractor: { _, _ in "A" },
            priorityExtractor: { _, _ in priority }
        )
    }

    private func admitted(_ middleware: EnhancedRateLimitingMiddleware) async throws -> Bool {
        do {
            _ = try await middleware.execute(RatePolicyCommand(), context: CommandContext()) { _, _ in 7 }
            return true
        } catch PipelineError.rateLimitExceeded {
            return false
        }
    }

    private func distributed(_ store: any DistributedRateLimitStore, scope: RateLimitScope) -> RateLimiter {
        RateLimiter(strategy: .distributed(store: store, windowSize: Self.window, maxRequests: 1), scope: scope)
    }
}

private struct RatePolicyCommand: Command {
    typealias Result = Int
}

private struct KeyOnlyRateStore: DistributedRateLimitStore {
    private let backend = InMemoryRateLimitStore()

    func incrementAndGet(key: String, windowSize: TimeInterval) async throws -> Int {
        try await backend.incrementAndGet(key: key, windowSize: windowSize)
    }
    func getCount(key: String, windowSize: TimeInterval) async throws -> Int {
        try await backend.getCount(key: key, windowSize: windowSize)
    }
    func reset(key: String) async throws { try await backend.reset(key: key) }
}

private final class ResetStoreFailure: Error, Sendable {}

private struct FailingResetRateStore: ResettableDistributedRateLimitStore {
    private let backend = InMemoryRateLimitStore()
    let failure: ResetStoreFailure

    func incrementAndGet(key: String, windowSize: TimeInterval) async throws -> Int {
        try await backend.incrementAndGet(key: key, windowSize: windowSize)
    }
    func getCount(key: String, windowSize: TimeInterval) async throws -> Int {
        try await backend.getCount(key: key, windowSize: windowSize)
    }
    func reset(key: String) async throws { throw failure }
    func resetAll(keyPrefix: String) async throws { throw failure }
}
