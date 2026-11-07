import Foundation
import Synchronization
import XCTest
@testable import _RateLimiting

final class RateLimiterEvictionContractTests: XCTestCase {
    func testEligibleSlidingFixedLeakyCandidateCannotRetireNewAdmission() async throws {
        for (strategy, _) in eligiblePolicies {
            let clock = EvictionClock()
            let gate = EligibleCleanupGate()
            let limiter = RateLimiter(strategy: strategy, scope: .perUser, now: { clock.now() }, cleanupObservation: { await gate.hold(eligible: $0) })
            _ = try await limiter.allowRequest(identifier: "budget")
            clock.set(601)
            let sweep = Task { try await limiter.allowRequest(identifier: "sweep") }
            let eligible = await gate.waitUntilRead()
            let admitted = try await limiter.allowRequest(identifier: "budget")
            await gate.release()
            _ = try await sweep.value
            let repeated = try await limiter.allowRequest(identifier: "budget")
            XCTAssertTrue(eligible, "\(strategy) must reach the deletion guard")
            XCTAssertEqual([admitted, repeated], [true, false], "\(strategy)")
        }
    }

    func testEligibleSlidingFixedLeakyCandidateCannotRetireStatusObservedEntry() async throws {
        for (strategy, storage) in eligiblePolicies {
            let clock = EvictionClock()
            let gate = EligibleCleanupGate()
            let limiter = RateLimiter(strategy: strategy, scope: .perUser, now: { clock.now() }, cleanupObservation: { await gate.hold(eligible: $0) })
            _ = try await limiter.allowRequest(identifier: "budget")
            clock.set(601)
            let sweep = Task { try await limiter.allowRequest(identifier: "sweep") }
            let eligible = await gate.waitUntilRead()
            let status = try await limiter.getStatus(identifier: "budget")
            await gate.release()
            _ = try await sweep.value
            let entries = await limiter.evictionEntryCount(storage)
            XCTAssertTrue(eligible, "\(strategy) must reach the deletion guard")
            XCTAssertEqual(status.remaining, 1)
            XCTAssertEqual(entries, 2, "\(strategy): status revision must retain the observed entry")
        }
    }

    func testEligibleSlidingFixedLeakyCandidateCannotRetireResetReplacement() async throws {
        for (strategy, _) in eligiblePolicies {
            for resetAll in [false, true] {
                let clock = EvictionClock()
                let gate = EligibleCleanupGate()
                let limiter = RateLimiter(strategy: strategy, scope: .perUser, now: { clock.now() }, cleanupObservation: { await gate.hold(eligible: $0) })
                _ = try await limiter.allowRequest(identifier: "budget")
                clock.set(601)
                let sweep = Task { try await limiter.allowRequest(identifier: "sweep") }
                let eligible = await gate.waitUntilRead()
                try await limiter.reset(identifier: resetAll ? nil : "budget")
                let replacement = try await limiter.allowRequest(identifier: "budget")
                await gate.release()
                _ = try await sweep.value
                let repeated = try await limiter.allowRequest(identifier: "budget")
                XCTAssertTrue(eligible, "\(strategy) must reach the deletion guard")
                XCTAssertEqual([replacement, repeated], [true, false], "\(strategy), resetAll=\(resetAll)")
            }
        }
    }

    private var eligiblePolicies: [(RateLimitStrategy, String)] {
        [
            (.slidingWindow(windowSize: 600, maxRequests: 1), "slidingWindows"),
            (.fixedWindow(windowSize: 600, maxRequests: 1), "fixedWindows"),
            (.leakyBucket(capacity: 1, leakRate: 600), "leakyBuckets")
        ]
    }

    func testCleanupCannotRenewConfiguredBudgetBeforeItsPolicyAllows() async throws {
        let samples: [(TimeInterval, Bool, Bool)] = [
            (299, false, false), (300, false, false), (301, false, false),
            (599, false, false), (600, false, true), (601, true, true)
        ]
        for (seconds, slidingAllowed, tokenAllowed) in samples {
            let policies: [(RateLimitStrategy, Bool)] = [
                (.slidingWindow(windowSize: 600, maxRequests: 1), slidingAllowed),
                (.tokenBucket(capacity: 1, refillRate: 1.0 / 600), tokenAllowed),
                (.tokenBucket(capacity: 1, refillRate: 0), false)
            ]
            for (strategy, expected) in policies {
                let clock = EvictionClock()
                let limiter = RateLimiter(strategy: strategy, scope: .perUser, now: { clock.now() })
                let first = try await limiter.allowRequest(identifier: "budget")
                XCTAssertTrue(first)
                clock.set(seconds)
                _ = try await limiter.allowRequest(identifier: "sweep")
                let actual = try await limiter.allowRequest(identifier: "budget")
                XCTAssertEqual(actual, expected, "\(strategy) at \(seconds)")
            }
        }
    }

    func testLeakyIdleCycleStartsAtNewAdmissionWithOrWithoutReclamation() async throws {
        for sweep in [false, true] {
            let clock = EvictionClock()
            let limiter = RateLimiter(strategy: .leakyBucket(capacity: 1, leakRate: 10), scope: .perUser, now: { clock.now() })
            // In the retained path the initial admission runs the sweep before
            // creating this bucket, so the admission at 316 cannot sweep again.
            if !sweep { clock.set(300) }
            _ = try await limiter.allowRequest(identifier: "budget")
            clock.set(315)
            if sweep { _ = try await limiter.allowRequest(identifier: "sweep") }
            let beforeReadmission = await limiter.evictionEntryCount("leakyBuckets")
            XCTAssertEqual(beforeReadmission, 1)
            clock.set(316)
            let added = try await limiter.allowRequest(identifier: "budget")
            let afterReadmission = await limiter.evictionEntryCount("leakyBuckets")
            XCTAssertEqual(afterReadmission, sweep ? 2 : 1)
            clock.set(320)
            let early = try await limiter.allowRequest(identifier: "budget")
            clock.set(326)
            let due = try await limiter.allowRequest(identifier: "budget")
            XCTAssertEqual([added, early, due], [true, false, true])
        }
    }

    func testLeakyShortIdleExampleAndBusyFractionalPhase() async throws {
        let clock = EvictionClock()
        let bucket = LeakyBucket(capacity: 1, leakRate: 10, now: { clock.now() })
        _ = await bucket.tryAdd()
        clock.set(15)
        let drained = await bucket.getCurrentLevel()
        XCTAssertEqual(drained, 0)
        clock.set(16)
        let admitted = await bucket.tryAdd()
        clock.set(20)
        let early = await bucket.tryAdd()
        clock.set(26)
        let due = await bucket.tryAdd()
        XCTAssertEqual([admitted, early, due], [true, false, true])

        let busyClock = EvictionClock()
        let busy = LeakyBucket(capacity: 3, leakRate: 10, now: { busyClock.now() })
        for _ in 0..<3 { _ = await busy.tryAdd() }
        busyClock.set(15)
        let firstLeak = await busy.getCurrentLevel()
        _ = await busy.tryAdd()
        busyClock.set(20)
        let secondLeak = await busy.getCurrentLevel()
        XCTAssertEqual([firstLeak, secondLeak], [2, 2])
    }

    func testNeutralEntriesAreActuallyReclaimedAndActiveEntriesRetained() async throws {
        let cases: [(RateLimitStrategy, String, TimeInterval, Int)] = [
            (.tokenBucket(capacity: 1, refillRate: 1.0 / 600), "buckets", 300, 2),
            (.tokenBucket(capacity: 1, refillRate: 1.0 / 600), "buckets", 600, 1),
            (.tokenBucket(capacity: 1, refillRate: 0), "buckets", 600, 2),
            (.slidingWindow(windowSize: 600, maxRequests: 1), "slidingWindows", 600, 2),
            (.slidingWindow(windowSize: 600, maxRequests: 1), "slidingWindows", 601, 1),
            (.fixedWindow(windowSize: 600, maxRequests: 1), "fixedWindows", 300, 2),
            (.fixedWindow(windowSize: 600, maxRequests: 1), "fixedWindows", 600, 1),
            (.leakyBucket(capacity: 1, leakRate: 600), "leakyBuckets", 300, 2),
            (.leakyBucket(capacity: 1, leakRate: 600), "leakyBuckets", 600, 1)
        ]
        for (strategy, storage, seconds, expected) in cases {
            let clock = EvictionClock()
            let limiter = RateLimiter(strategy: strategy, scope: .perUser, now: { clock.now() })
            _ = try await limiter.allowRequest(identifier: "budget")
            clock.set(seconds)
            _ = try await limiter.allowRequest(identifier: "sweep")
            let entries = await limiter.evictionEntryCount(storage)
            XCTAssertEqual(entries, expected, "\(strategy) at \(seconds)")
        }
    }

    func testAdaptiveCleanupRetainsOriginalCapacityAcrossLoadChanges() async throws {
        let clock = EvictionClock()
        let load = Mutex(1.0)
        let limiter = RateLimiter(strategy: .adaptive(baseRate: 1, loadFactor: { load.withLock { $0 } }), scope: .perUser, now: { clock.now() })
        _ = try await limiter.allowRequest(identifier: "budget")
        clock.set(301)
        load.withLock { $0 = 0 }
        _ = try await limiter.allowRequest(identifier: "sweep")
        let first = try await limiter.allowRequest(identifier: "budget")
        let second = try await limiter.allowRequest(identifier: "budget")
        XCTAssertEqual([first, second], [true, false])
        try await limiter.reset(identifier: "budget")
        let resetFirst = try await limiter.allowRequest(identifier: "budget")
        let resetSecond = try await limiter.allowRequest(identifier: "budget")
        XCTAssertEqual([resetFirst, resetSecond], [true, true])
    }

    func testZeroCapacityAndZeroRefillNeverGainQuotaFromCleanup() async throws {
        for strategy: RateLimitStrategy in [.tokenBucket(capacity: 0, refillRate: 1), .leakyBucket(capacity: 0, leakRate: 1), .fixedWindow(windowSize: 1, maxRequests: 0), .slidingWindow(windowSize: 1, maxRequests: 0)] {
            let clock = EvictionClock()
            let limiter = RateLimiter(strategy: strategy, scope: .perUser, now: { clock.now() })
            let first = try await limiter.allowRequest(identifier: "budget")
            clock.set(601)
            _ = try await limiter.allowRequest(identifier: "sweep")
            let later = try await limiter.allowRequest(identifier: "budget")
            XCTAssertEqual([first, later], [false, false])
        }
    }

    func testRollbackAfterReclamationCannotReopenPriorBudget() async throws {
        let policies: [RateLimitStrategy] = [.fixedWindow(windowSize: 600, maxRequests: 1), .slidingWindow(windowSize: 600, maxRequests: 1), .tokenBucket(capacity: 1, refillRate: 1.0 / 600), .leakyBucket(capacity: 1, leakRate: 600)]
        for strategy in policies {
            let clock = EvictionClock()
            let limiter = RateLimiter(strategy: strategy, scope: .perUser, now: { clock.now() })
            _ = try await limiter.allowRequest(identifier: "budget")
            clock.set(601)
            _ = try await limiter.allowRequest(identifier: "sweep")
            let renewed = try await limiter.allowRequest(identifier: "budget")
            clock.set(1)
            let rolledBack = try await limiter.allowRequest(identifier: "budget")
            clock.set(601)
            let forwardAgain = try await limiter.allowRequest(identifier: "budget")
            XCTAssertEqual([renewed, rolledBack, forwardAgain], [true, false, false], "\(strategy)")
        }
    }

    func testAdmissionAfterNeutralReadKeepsConsumedBudget() async throws {
        let clock = EvictionClock()
        let gate = EvictionReadGate()
        let limiter = RateLimiter(strategy: .tokenBucket(capacity: 1, refillRate: 0), scope: .perUser, now: { clock.now() }, tokenLastAccess: { bucket in
            let date = await bucket.getLastAccess()
            await gate.hold()
            return date
        })
        _ = try await limiter.allowRequest(identifier: "budget", cost: 0)
        clock.set(301)
        let sweep = Task { try await limiter.allowRequest(identifier: "sweep") }
        await gate.waitUntilRead()
        let consumed = try await limiter.allowRequest(identifier: "budget")
        await gate.release()
        _ = try await sweep.value
        let repeated = try await limiter.allowRequest(identifier: "budget")
        XCTAssertEqual([consumed, repeated], [true, false])
    }

    func testStatusAfterNeutralReadRetainsObservedEntryUntilLaterSweep() async throws {
        for token in [true, false] {
            let clock = EvictionClock()
            let gate = EvictionReadGate()
            let limiter = RateLimiter(strategy: token ? .tokenBucket(capacity: 1, refillRate: 0) : .slidingWindow(windowSize: 600, maxRequests: 1), scope: .perUser, now: { clock.now() }, tokenLastAccess: { bucket in
                let date = await bucket.getLastAccess()
                await gate.hold()
                return date
            }, windowHasRecentRequests: { window, interval in
                let recent = await window.hasRecentRequests(within: interval)
                await gate.hold()
                return recent
            })
            _ = try await limiter.allowRequest(identifier: "budget", cost: 0)
            clock.set(601)
            let sweep = Task { try await limiter.allowRequest(identifier: "sweep") }
            await gate.waitUntilRead()
            let status = try await limiter.getStatus(identifier: "budget")
            await gate.release()
            _ = try await sweep.value
            let entries = await limiter.evictionEntryCount(token ? "buckets" : "slidingWindows")
            XCTAssertEqual(status.remaining, 1)
            XCTAssertEqual(entries, 2)
        }
    }

    func testResetAfterNeutralReadCannotRetireReplacementBudget() async throws {
        for resetAll in [false, true] {
            let clock = EvictionClock()
            let gate = EvictionReadGate()
            let limiter = RateLimiter(strategy: .tokenBucket(capacity: 1, refillRate: 0), scope: .perUser, now: { clock.now() }, tokenLastAccess: { bucket in
                let date = await bucket.getLastAccess()
                await gate.hold()
                return date
            })
            _ = try await limiter.allowRequest(identifier: "budget", cost: 0)
            clock.set(301)
            let sweep = Task { try await limiter.allowRequest(identifier: "sweep") }
            await gate.waitUntilRead()
            try await limiter.reset(identifier: resetAll ? nil : "budget")
            let replacement = try await limiter.allowRequest(identifier: "budget")
            await gate.release()
            _ = try await sweep.value
            let repeated = try await limiter.allowRequest(identifier: "budget")
            XCTAssertEqual([replacement, repeated], [true, false])
        }
    }

    func testExtremeClockSpanDoesNotRefillZeroRateOrPoisonFractionalBudget() async throws {
        for rate in [0.0, 1.0e-309] {
            let clock = EvictionClock()
            clock.set(-1.0e308)
            let limiter = RateLimiter(strategy: .tokenBucket(capacity: 1, refillRate: rate), scope: .perUser, now: { clock.now() })
            _ = try await limiter.allowRequest(identifier: "budget")
            clock.set(1.0e308)
            // Even the nonzero rate generates only 0.2 tokens over this span.
            let later = try await limiter.allowRequest(identifier: "budget")
            XCTAssertFalse(later, "rate \(rate)")
            if rate > 0 {
                let fractional = try await limiter.allowRequest(identifier: "budget", cost: 0.19)
                let exhausted = try await limiter.allowRequest(identifier: "budget", cost: 0.02)
                XCTAssertEqual([fractional, exhausted], [true, false])
            }
        }
    }
}

private extension RateLimiter {
    // Reflection is test-only reclamation evidence; quota assertions above use
    // the public API and literal configured-policy expectations.
    func evictionEntryCount(_ storage: String) -> Int {
        let dictionary = Mirror(reflecting: self).children.first { $0.label == storage }!.value
        return Mirror(reflecting: dictionary).children.count
    }
}

private final class EvictionClock: Sendable {
    private let instant = Mutex(Date(timeIntervalSince1970: 0))
    func now() -> Date { instant.withLock { $0 } }
    func set(_ seconds: TimeInterval) { instant.withLock { $0 = Date(timeIntervalSince1970: seconds) } }
}

private actor EvictionReadGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func hold() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
    }
    func waitUntilRead() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor EligibleCleanupGate {
    private var observation: Bool?
    private var observers: [CheckedContinuation<Bool, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold(eligible: Bool) async {
        guard observation == nil else { return }
        observation = eligible
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            for observer in observers { observer.resume(returning: eligible) }
            observers.removeAll()
        }
    }

    func waitUntilRead() async -> Bool {
        if let observation { return observation }
        return await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
