import Foundation
import Synchronization
import XCTest
@testable import _RateLimiting

final class RateLimiterCleanupTests: XCTestCase {
    func testSuspendedSweepPreservesNewIdentityBudgetsAcrossAnotherAdmissionSweep() async throws {
        for algorithm in CleanupAlgorithm.allCases {
            let clock = CleanupClock()
            let gate = CleanupReadGate()
            let limiter = makeLimiter(algorithm, clock: clock, gate: gate)
            _ = try await limiter.allowRequest(identifier: "existing")
            clock.set(1_299)
            _ = try await limiter.allowRequest(identifier: "existing", cost: 0)
            clock.set(1_300)

            let sweep = Task { try await limiter.allowRequest(identifier: "sweep") }
            await gate.waitUntilRead()
            // Before the fix, this admission starts and completes a second sweep.
            let firstNew = try await limiter.allowRequest(identifier: "new")
            let firstOther = try await limiter.allowRequest(identifier: "other")
            await gate.release()
            _ = try await sweep.value

            let repeatedNew = try await limiter.allowRequest(identifier: "new")
            let repeatedOther = try await limiter.allowRequest(identifier: "other")
            XCTAssertEqual([firstNew, firstOther, repeatedNew, repeatedOther], [true, true, false, false], "\(algorithm)")
        }
    }

    func testActivityAfterExpiredReadKeepsTheExistingBudget() async throws {
        for algorithm in CleanupAlgorithm.allCases {
            let clock = CleanupClock()
            let gate = CleanupReadGate()
            let limiter = makeLimiter(algorithm, clock: clock, gate: gate)
            _ = try await limiter.allowRequest(identifier: "existing")
            clock.set(1_301)

            let sweep = Task { try await limiter.allowRequest(identifier: "sweep") }
            await gate.waitUntilRead()
            let touched = try await limiter.allowRequest(identifier: "existing", cost: 0)
            await gate.release()
            _ = try await sweep.value

            let repeated = try await limiter.allowRequest(identifier: "existing")
            XCTAssertEqual(touched, algorithm == .token, "\(algorithm)")
            XCTAssertFalse(repeated, "\(algorithm)")
        }
    }

    func testResetReplacementIsNotOverwrittenBySuspendedSweep() async throws {
        for algorithm in CleanupAlgorithm.allCases {
            let clock = CleanupClock()
            let gate = CleanupReadGate()
            let limiter = makeLimiter(algorithm, capacity: 2, clock: clock, gate: gate)
            _ = try await limiter.allowRequest(identifier: "existing")
            _ = try await limiter.allowRequest(identifier: "existing")
            clock.set(1_301)

            let sweep = Task { try await limiter.allowRequest(identifier: "sweep") }
            await gate.waitUntilRead()
            try await limiter.reset(identifier: "existing")
            let replacement = try await limiter.allowRequest(identifier: "existing")
            await gate.release()
            _ = try await sweep.value

            let remaining = try await limiter.allowRequest(identifier: "existing")
            let exhausted = try await limiter.allowRequest(identifier: "existing")
            XCTAssertEqual([replacement, remaining, exhausted], [true, true, false], "\(algorithm)")
        }
    }

    func testResetAllIsNotUndoneBySuspendedSweep() async throws {
        for algorithm in CleanupAlgorithm.allCases {
            let clock = CleanupClock()
            let gate = CleanupReadGate()
            let limiter = makeLimiter(algorithm, clock: clock, gate: gate)
            _ = try await limiter.allowRequest(identifier: "existing")
            clock.set(1_299)
            _ = try await limiter.allowRequest(identifier: "existing", cost: 0)
            clock.set(1_300)

            let sweep = Task { try await limiter.allowRequest(identifier: "sweep") }
            await gate.waitUntilRead()
            try await limiter.reset()
            await gate.release()
            _ = try await sweep.value

            let afterReset = try await limiter.allowRequest(identifier: "existing")
            let repeated = try await limiter.allowRequest(identifier: "existing")
            XCTAssertEqual([afterReset, repeated], [true, false], "\(algorithm)")
        }
    }

    func testCancelledLongSweepDoesNotSuppressLaterCleanup() async throws {
        for algorithm in CleanupAlgorithm.allCases {
            let clock = CleanupClock()
            let gate = CleanupReadGate()
            let limiter = makeLimiter(algorithm, clock: clock, gate: gate)
            _ = try await limiter.allowRequest(identifier: "existing")
            clock.set(1_300)
            let sweep = Task { try await limiter.allowRequest(identifier: "sweep") }
            await gate.waitUntilRead()
            // A sweep that crosses another interval still owns its in-progress marker.
            clock.set(1_601)
            let new = try await limiter.allowRequest(identifier: "new")
            sweep.cancel()
            await gate.release()
            _ = try await sweep.value
            let repeated = try await limiter.allowRequest(identifier: "new")
            XCTAssertEqual([new, repeated], [true, false], "\(algorithm)")

            clock.set(1_902)
            _ = try await limiter.allowRequest(identifier: "later-sweep")
            let expired = try await limiter.allowRequest(identifier: "new")
            let exhausted = try await limiter.allowRequest(identifier: "new")
            XCTAssertEqual([expired, exhausted], [true, false], "\(algorithm)")
        }
    }

    func testIdleExpiryBoundaryAndRepeatedSweepsPreserveRecentActivity() async throws {
        for algorithm in CleanupAlgorithm.allCases {
            for offset: TimeInterval in [300, 300.125] {
                let clock = CleanupClock()
                let limiter = makeLimiter(algorithm, clock: clock)
                _ = try await limiter.allowRequest(identifier: "idle")
                _ = try await limiter.allowRequest(identifier: "recent")
                clock.set(1_299)
                _ = try await limiter.allowRequest(identifier: "recent", cost: 0)
                clock.set(1_000 + offset)
                _ = try await limiter.allowRequest(identifier: "sweep")
                let idle = try await limiter.allowRequest(identifier: "idle")
                let recent = try await limiter.allowRequest(identifier: "recent")
                // Token cleanup expires at 300; sliding cleanup retains the exact cutoff.
                XCTAssertEqual(idle, algorithm == .token || offset > 300, "\(algorithm), \(offset)")
                XCTAssertFalse(recent, "\(algorithm), \(offset)")

                clock.set(1_599)
                _ = try await limiter.allowRequest(identifier: "recent", cost: 0)
                clock.set(1_601)
                _ = try await limiter.allowRequest(identifier: "next-sweep")
                let nextRecent = try await limiter.allowRequest(identifier: "recent")
                XCTAssertFalse(nextRecent, "\(algorithm), \(offset)")
                clock.set(1_902)
                _ = try await limiter.allowRequest(identifier: "final-sweep")
                let expired = try await limiter.allowRequest(identifier: "recent")
                let exhausted = try await limiter.allowRequest(identifier: "recent")
                XCTAssertEqual([expired, exhausted], [true, false], "\(algorithm), \(offset)")
            }
        }
    }

    private func makeLimiter(
        _ algorithm: CleanupAlgorithm,
        capacity: Int = 1,
        clock: CleanupClock,
        gate: CleanupReadGate? = nil
    ) -> RateLimiter {
        let strategy: RateLimitStrategy = switch algorithm {
        case .token: .tokenBucket(capacity: Double(capacity), refillRate: 0)
        case .sliding: .slidingWindow(windowSize: 10_000, maxRequests: capacity)
        }
        guard let gate else {
            return RateLimiter(strategy: strategy, scope: .perUser, now: { clock.now() })
        }
        return RateLimiter(
            strategy: strategy,
            scope: .perUser,
            now: { clock.now() },
            tokenLastAccess: { bucket in
                let access = await bucket.getLastAccess()
                await gate.holdFirstRead()
                return access
            },
            windowHasRecentRequests: { window, interval in
                let recent = await window.hasRecentRequests(within: interval)
                await gate.holdFirstRead()
                return recent
            }
        )
    }
}

private enum CleanupAlgorithm: CaseIterable {
    case token, sliding
}

private final class CleanupClock: Sendable {
    private let instant = Mutex(Date(timeIntervalSince1970: 1_000))

    func now() -> Date { instant.withLock { $0 } }
    func set(_ seconds: TimeInterval) {
        instant.withLock { $0 = Date(timeIntervalSince1970: seconds) }
    }
}

private actor CleanupReadGate {
    private var claimed = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func holdFirstRead() async {
        guard !claimed else { return }
        claimed = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            for waiter in readWaiters { waiter.resume() }
            readWaiters.removeAll()
        }
    }

    func waitUntilRead() async {
        if claimed { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
