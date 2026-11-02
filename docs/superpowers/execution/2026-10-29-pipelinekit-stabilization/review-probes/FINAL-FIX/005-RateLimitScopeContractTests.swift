import Foundation
import PipelineKitResilience
import XCTest
import Synchronization
@testable import _RateLimiting

final class RateLimitScopeContractTests: XCTestCase {
    private static let nonRefillingInterval: TimeInterval = 1_000_000_000_000
    private static let globalKey = "pipelinekit:rate-limit:v1:global"

    func testScopeByStrategyMatrix() async throws {
        for strategy in StrategyCase.allCases {
            for scope in ScopeCase.allCases {
                let limiter = makeLimiter(strategy, scope: scope.scope)
                let first = try await limiter.allowRequest(identifier: "A")
                let distinct = try await limiter.allowRequest(identifier: "B")
                let repeatA = try await limiter.allowRequest(identifier: "A")
                let repeatB = try await limiter.allowRequest(identifier: "B")
                XCTAssertEqual(
                    [first, distinct, repeatA, repeatB],
                    scope == .global ? [true, false, false, false] : [true, true, false, false],
                    "\(strategy), \(scope)"
                )
            }
        }
    }

    func testGlobalStatusUsesSameEffectiveKey() async throws {
        for strategy in StrategyCase.allCases {
            let limiter = makeLimiter(strategy, scope: .global)
            let initial = await limiter.getStatus(identifier: "B")
            XCTAssertEqual(initial.remaining, 1, "\(strategy)")
            let admitted = try await limiter.allowRequest(identifier: "A")
            XCTAssertTrue(admitted, "\(strategy)")
            let statusA = await limiter.getStatus(identifier: "A")
            let statusB = await limiter.getStatus(identifier: "B")
            XCTAssertEqual(statusA.remaining, 0, "\(strategy)")
            XCTAssertEqual(statusB.remaining, 0, "\(strategy)")
            XCTAssertEqual(statusB.limit, 1, "\(strategy)")
        }
    }

    func testNonGlobalStatusUsesIndependentBudgets() async throws {
        for strategy in StrategyCase.allCases {
            for scope in ScopeCase.nonGlobal {
                let limiter = makeLimiter(strategy, scope: scope.scope)
                let admitted = try await limiter.allowRequest(identifier: "A")
                XCTAssertTrue(admitted, "\(strategy), \(scope)")
                let statusA = await limiter.getStatus(identifier: "A")
                let statusB = await limiter.getStatus(identifier: "B")
                XCTAssertEqual(statusA.remaining, 0, "\(strategy), \(scope)")
                XCTAssertEqual(statusB.remaining, 1, "\(strategy), \(scope)")
            }
        }
    }

    func testGlobalResetUsesSameEffectiveKeyForSupportedLocalStrategies() async throws {
        for strategy in StrategyCase.resettableByIdentifier {
            let limiter = makeLimiter(strategy, scope: .global)
            let first = try await limiter.allowRequest(identifier: "A")
            XCTAssertTrue(first, "\(strategy)")
            await limiter.reset(identifier: "B")
            let status = await limiter.getStatus(identifier: "A")
            XCTAssertEqual(status.remaining, 1, "\(strategy)")
            let next = try await limiter.allowRequest(identifier: "C")
            let repeated = try await limiter.allowRequest(identifier: "A")
            XCTAssertTrue(next, "\(strategy)")
            XCTAssertFalse(repeated, "\(strategy)")
        }
    }

    func testNonGlobalResetPreservesOtherIdentifiers() async throws {
        for strategy in StrategyCase.resettableByIdentifier {
            for scope in ScopeCase.nonGlobal {
                let limiter = makeLimiter(strategy, scope: scope.scope)
                let firstA = try await limiter.allowRequest(identifier: "A")
                let firstB = try await limiter.allowRequest(identifier: "B")
                XCTAssertTrue(firstA, "\(strategy), \(scope)")
                XCTAssertTrue(firstB, "\(strategy), \(scope)")
                await limiter.reset(identifier: "A")
                let nextA = try await limiter.allowRequest(identifier: "A")
                let nextB = try await limiter.allowRequest(identifier: "B")
                XCTAssertTrue(nextA, "\(strategy), \(scope)")
                XCTAssertFalse(nextB, "\(strategy), \(scope)")
            }
        }
    }

    func testResetAllRestoresAllLocalStrategies() async throws {
        for strategy in StrategyCase.allCases where strategy != .distributed {
            for scope in ScopeCase.allCases {
                let limiter = makeLimiter(strategy, scope: scope.scope)
                _ = try await limiter.allowRequest(identifier: "A")
                _ = try await limiter.allowRequest(identifier: "B")
                await limiter.reset()
                let nextA = try await limiter.allowRequest(identifier: "A")
                let nextB = try await limiter.allowRequest(identifier: "B")
                XCTAssertEqual([nextA, nextB], scope == .global ? [true, false] : [true, true], "\(strategy), \(scope)")
            }
        }
    }

    func testGlobalDistributedInstancesShareStoreIdentity() async throws {
        let store = RecordingRateLimitStore()
        let first = makeLimiter(.distributed, scope: .global, store: store)
        let second = makeLimiter(.distributed, scope: .global, store: store)
        let firstAdmission = try await first.allowRequest(identifier: "A")
        let secondAdmission = try await second.allowRequest(identifier: "B")
        let secondStatus = await second.getStatus(identifier: "unseen")
        let keys = await store.recordedKeys()
        XCTAssertTrue(firstAdmission)
        XCTAssertFalse(secondAdmission)
        XCTAssertEqual(secondStatus.remaining, 0)
        XCTAssertEqual(keys.increments, [Self.globalKey, Self.globalKey])
        XCTAssertEqual(keys.reads, [Self.globalKey])
    }

    func testDistributedScopeNamespacesRejectSuppliedKeyCollisions() async throws {
        let store = RecordingRateLimitStore()
        let global = makeLimiter(.distributed, scope: .global, store: store)
        let globalAdmission = try await global.allowRequest(identifier: "ignored")
        XCTAssertTrue(globalAdmission)
        for scope in ScopeCase.nonGlobal {
            let limiter = makeLimiter(.distributed, scope: scope.scope, store: store)
            for supplied in ["", "A", Self.globalKey, "pipelinekit:rate-limit:v1:user:A", "A:medium"] {
                let first = try await limiter.allowRequest(identifier: supplied)
                let repeated = try await limiter.allowRequest(identifier: supplied)
                let status = await limiter.getStatus(identifier: supplied)
                XCTAssertTrue(first, "\(scope), \(supplied)")
                XCTAssertFalse(repeated, "\(scope), \(supplied)")
                XCTAssertEqual(status.remaining, 0, "\(scope), \(supplied)")
            }
        }
        let keys = await store.recordedKeys()
        let expected: [String] = [
            "pipelinekit:rate-limit:v1:user:",
            "pipelinekit:rate-limit:v1:user:A",
            "pipelinekit:rate-limit:v1:user:pipelinekit:rate-limit:v1:global",
            "pipelinekit:rate-limit:v1:user:pipelinekit:rate-limit:v1:user:A",
            "pipelinekit:rate-limit:v1:user:A:medium",
            "pipelinekit:rate-limit:v1:ip:",
            "pipelinekit:rate-limit:v1:ip:A",
            "pipelinekit:rate-limit:v1:ip:pipelinekit:rate-limit:v1:global",
            "pipelinekit:rate-limit:v1:ip:pipelinekit:rate-limit:v1:user:A",
            "pipelinekit:rate-limit:v1:ip:A:medium",
            "pipelinekit:rate-limit:v1:command:",
            "pipelinekit:rate-limit:v1:command:A",
            "pipelinekit:rate-limit:v1:command:pipelinekit:rate-limit:v1:global",
            "pipelinekit:rate-limit:v1:command:pipelinekit:rate-limit:v1:user:A",
            "pipelinekit:rate-limit:v1:command:A:medium"
        ]
        XCTAssertEqual(keys.reads, expected)
        XCTAssertEqual(keys.increments, [Self.globalKey] + expected.flatMap { [$0, $0] })
    }

    func testPublicInitializerGlobalStrategyMatrix() async throws {
        for strategy in StrategyCase.allCases {
            let start = Date()
            let limiter = RateLimiter(strategy: configuration(strategy), scope: .global)
            let first = try await limiter.allowRequest(identifier: "A")
            let distinct = try await limiter.allowRequest(identifier: "B")
            let repeated = try await limiter.allowRequest(identifier: "A")
            // An elapsed bound detects invalid fixture timing, not task ordering.
            XCTAssertLessThan(Date().timeIntervalSince(start), 10, "Adaptive must not refill one token")
            XCTAssertEqual([first, distinct, repeated], [true, false, false], "\(strategy)")
        }
    }

    func testScopeByStrategyNearWindowBoundaryMatrix() async throws {
        for strategy in StrategyCase.allCases {
            for scope in ScopeCase.allCases {
                for offset: TimeInterval in [9.875, 10, 10.125] {
                    let clock = ManualRateClock()
                    let store = RecordingRateLimitStore(now: { clock.now() })
                    let limiter = makeLimiter(strategy, scope: scope.scope, store: store, clock: clock, interval: 10)
                    let first = try await limiter.allowRequest(identifier: "A")
                    XCTAssertTrue(first, "\(strategy), \(scope), \(offset)")
                    clock.set(1_000 + offset)
                    let statusA = await limiter.getStatus(identifier: "A")
                    let statusB = await limiter.getStatus(identifier: "B")
                    // SlidingWindow includes a request exactly at its cutoff; other strategies renew at 10.
                    let renewed = strategy == .slidingWindow ? offset > 10 : offset >= 10
                    // Token/adaptive status reads tokens without refilling; admission performs refill.
                    let remaining = strategy == .tokenBucket || strategy == .adaptive ? 0 : (renewed ? 1 : 0)
                    XCTAssertEqual(statusA.remaining, remaining, "\(strategy), \(scope), \(offset)")
                    XCTAssertEqual(statusB.remaining, scope == .global ? remaining : 1, "\(strategy), \(scope), \(offset)")
                    if scope == .global {
                        XCTAssertEqual(statusA.resetAt, statusB.resetAt, "\(strategy), \(offset)")
                    }
                    let nextB = try await limiter.allowRequest(identifier: "B")
                    let repeatA = try await limiter.allowRequest(identifier: "A")
                    let repeatB = try await limiter.allowRequest(identifier: "B")
                    XCTAssertEqual(
                        [nextB, repeatA, repeatB],
                        scope == .global ? [renewed, false, false] : [true, renewed, false],
                        "\(strategy), \(scope), \(offset)"
                    )
                }
            }
        }
    }

    func testGlobalBudgetSurvivesCleanupWhenRecentlyAccessed() async throws {
        for strategy: StrategyCase in [.tokenBucket, .slidingWindow, .adaptive] {
            let clock = ManualRateClock()
            let limiter = makeLimiter(strategy, scope: .global, clock: clock)
            _ = try await limiter.allowRequest(identifier: "A")
            clock.set(1_299)
            // Adaptive refills at 0.1 token/second: consume the full token at 1299.
            // Retaining it admits no unit request at 1300 (only 0.1 token refilled);
            // recreating it during cleanup would incorrectly admit that request.
            // The nonrefilling token bucket and sliding window use a zero-cost touch.
            let touched = try await limiter.allowRequest(identifier: "A", cost: strategy == .adaptive ? 1 : 0)
            XCTAssertTrue(touched, "\(strategy)")
            clock.set(1_300)
            let status = await limiter.getStatus(identifier: "B")
            let afterCleanup = try await limiter.allowRequest(identifier: "B")
            XCTAssertEqual(status.remaining, 0, "\(strategy)")
            XCTAssertFalse(afterCleanup, "\(strategy)")
        }
    }

    func testClockDrivesLocalAlgorithmResetAndStatus() async {
        let clock = ManualRateClock()
        let fixed = FixedWindow(windowSize: 10, now: { clock.now() })
        let leaky = LeakyBucket(capacity: 1, leakRate: 10, now: { clock.now() })
        let token = TokenBucket(capacity: 1, refillRate: 0.1, now: { clock.now() })
        let sliding = SlidingWindow(now: { clock.now() })
        _ = await fixed.recordRequest()
        _ = await leaky.tryAdd()
        _ = await token.consume(tokens: 1)
        await sliding.recordRequest()
        clock.set(1_009.875)
        let untilReset = await fixed.timeUntilReset()
        let untilLeak = await leaky.timeUntilNextLeak()
        let recentlyUsed = await sliding.hasRecentRequests(within: 10)
        XCTAssertEqual(untilReset, 0.125, accuracy: 0.000_001)
        XCTAssertEqual(untilLeak, 0.125, accuracy: 0.000_001)
        XCTAssertTrue(recentlyUsed)
        clock.set(1_010.125)
        await fixed.reset()
        await leaky.reset()
        await token.refill(rate: 0.1)
        let fixedCount = await fixed.getCurrentCount()
        let fixedNext = await fixed.timeUntilReset()
        let leakyLevel = await leaky.getCurrentLevel()
        let tokens = await token.getTokens()
        let access = await token.getLastAccess()
        let stale = await sliding.hasRecentRequests(within: 10)
        XCTAssertEqual(fixedCount, 0)
        XCTAssertEqual(fixedNext, 9.875, accuracy: 0.000_001)
        XCTAssertEqual(leakyLevel, 0)
        XCTAssertEqual(tokens, 1, accuracy: 0.000_001)
        XCTAssertEqual(access, clock.now())
        XCTAssertFalse(stale)
        _ = await leaky.tryAdd()
        let leakAfterReset = await leaky.timeUntilNextLeak()
        XCTAssertEqual(leakAfterReset, 10, accuracy: 0.000_001)
    }

    func testDistributedLogicalBudgetsUseSeparateStoreNamespaces() async throws {
        let backend = RecordingRateLimitStore()
        let uploads = NamespacedRateLimitStore(namespace: "uploads", backend: backend)
        let searches = NamespacedRateLimitStore(namespace: "searches", backend: backend)
        let uploadA = makeLimiter(.distributed, scope: .global, store: uploads)
        let uploadB = makeLimiter(.distributed, scope: .global, store: uploads)
        let search = makeLimiter(.distributed, scope: .global, store: searches)
        let firstUpload = try await uploadA.allowRequest(identifier: "A")
        let secondUpload = try await uploadB.allowRequest(identifier: "B")
        let firstSearch = try await search.allowRequest(identifier: "B")
        let secondSearch = try await search.allowRequest(identifier: "A")
        XCTAssertEqual([firstUpload, secondUpload, firstSearch, secondSearch], [true, false, true, false])
        let keys = await backend.recordedKeys()
        XCTAssertEqual(keys.increments, [
            "7:uploadspipelinekit:rate-limit:v1:global", "7:uploadspipelinekit:rate-limit:v1:global",
            "8:searchespipelinekit:rate-limit:v1:global", "8:searchespipelinekit:rate-limit:v1:global"
        ])
    }

    func testIdentityNormalizationPreservesCostAndMediumPriorityPolicy() async throws {
        for strategy in StrategyCase.allCases {
            let limiter = makeLimiter(strategy, scope: .global)
            let first = try await limiter.allowRequest(identifier: "A", cost: 0.5)
            let second = try await limiter.allowRequest(identifier: "B", cost: 0.5)
            let third = try await limiter.allowRequest(identifier: "A", cost: 0.5)
            let honorsCost = strategy == .tokenBucket || strategy == .adaptive
            XCTAssertEqual([first, second, third], [true, honorsCost, false], "\(strategy)")
        }
        let noMedium = RateLimiter(strategy: .priorityBased(limits: [.high: .init(maxRequests: 100, windowSize: 10)]), scope: .global)
        let admitted = try await noMedium.allowRequest(identifier: "A")
        let status = await noMedium.getStatus(identifier: "B")
        XCTAssertFalse(admitted)
        XCTAssertEqual(status.remaining, 0)
        XCTAssertEqual(status.limit, 0)
    }

    private func makeLimiter(
        _ strategy: StrategyCase,
        scope: RateLimitScope,
        store: any DistributedRateLimitStore = RecordingRateLimitStore(),
        clock: ManualRateClock = ManualRateClock(),
        interval: TimeInterval = nonRefillingInterval
    ) -> RateLimiter {
        RateLimiter(strategy: configuration(strategy, store: store, interval: interval), scope: scope, now: { clock.now() })
    }

    private func configuration(
        _ strategy: StrategyCase,
        store: any DistributedRateLimitStore = RecordingRateLimitStore(),
        interval: TimeInterval = nonRefillingInterval
    ) -> RateLimitStrategy {
        switch strategy {
        case .tokenBucket: .tokenBucket(capacity: 1, refillRate: interval == 10 ? 0.1 : 0)
        case .slidingWindow: .slidingWindow(windowSize: interval, maxRequests: 1)
        case .fixedWindow: .fixedWindow(windowSize: interval, maxRequests: 1)
        case .leakyBucket: .leakyBucket(capacity: 1, leakRate: interval)
        case .adaptive: .adaptive(baseRate: 1, loadFactor: { 1 })
        case .distributed: .distributed(store: store, windowSize: interval, maxRequests: 1)
        case .priorityBased: .priorityBased(limits: [.medium: .init(maxRequests: 1, windowSize: interval)])
        }
    }
}

private enum StrategyCase: CaseIterable {
    case tokenBucket, slidingWindow, fixedWindow, leakyBucket, adaptive, distributed, priorityBased

    static let resettableByIdentifier: [Self] = [.tokenBucket, .slidingWindow, .fixedWindow, .leakyBucket, .adaptive]
}

private enum ScopeCase: CaseIterable {
    case global, perUser, perIP, perCommand

    static let nonGlobal: [Self] = [.perUser, .perIP, .perCommand]

    var scope: RateLimitScope {
        switch self {
        case .global: .global
        case .perUser: .perUser
        case .perIP: .perIP
        case .perCommand: .perCommand
        }
    }
}

private final class ManualRateClock: Sendable {
    private let instant = Mutex(Date(timeIntervalSince1970: 1_000))

    func now() -> Date { instant.withLock { $0 } }
    func set(_ secondsSinceEpoch: TimeInterval) {
        instant.withLock { $0 = Date(timeIntervalSince1970: secondsSinceEpoch) }
    }
}

private actor RecordingRateLimitStore: DistributedRateLimitStore {
    private struct Counter {
        let window: TimeInterval
        var count: Int
    }
    private let now: @Sendable () -> Date
    private var counts: [String: Counter] = [:]
    private var incrementKeys: [String] = []
    private var readKeys: [String] = []

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func incrementAndGet(key: String, windowSize: TimeInterval) -> Int {
        incrementKeys.append(key)
        let window = floor(now().timeIntervalSince1970 / windowSize) * windowSize
        let count = counts[key].map { $0.window == window ? $0.count + 1 : 1 } ?? 1
        counts[key] = Counter(window: window, count: count)
        return count
    }

    func getCount(key: String, windowSize: TimeInterval) -> Int {
        readKeys.append(key)
        let window = floor(now().timeIntervalSince1970 / windowSize) * windowSize
        return counts[key].map { $0.window == window ? $0.count : 0 } ?? 0
    }

    func reset(key: String) { counts.removeValue(forKey: key) }

    func recordedKeys() -> (increments: [String], reads: [String]) { (incrementKeys, readKeys) }
}

private struct NamespacedRateLimitStore: DistributedRateLimitStore {
    let namespace: String
    let backend: RecordingRateLimitStore

    func incrementAndGet(key: String, windowSize: TimeInterval) async throws -> Int {
        await backend.incrementAndGet(key: "\(namespace.utf8.count):\(namespace)\(key)", windowSize: windowSize)
    }

    func getCount(key: String, windowSize: TimeInterval) async throws -> Int {
        await backend.getCount(key: "\(namespace.utf8.count):\(namespace)\(key)", windowSize: windowSize)
    }

    func reset(key: String) async throws {
        await backend.reset(key: "\(namespace.utf8.count):\(namespace)\(key)")
    }
}
