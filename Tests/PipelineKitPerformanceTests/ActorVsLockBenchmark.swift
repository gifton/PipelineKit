import XCTest
import Foundation
#if canImport(os)
import os
#endif

/// Microbenchmark isolating the per-operation overhead of an `actor` vs a
/// lock-protected `final class` for a trivial *synchronous* state mutation under
/// heavy concurrency. This mirrors the shape of `CircuitBreaker.State.allowRequest`
/// (increment + threshold compare, no I/O) and is the gate for whether converting
/// that internal actor to a lock is worth it.
///
/// Run in RELEASE (debug actor/lock costs are not representative):
///   swift test -c release --filter ActorVsLockBenchmark
///
/// Decision gate: if the actor/lock wall-clock ratio is >= 1.5 (lock >= 1.5x
/// faster under contention), proceed to convert `CircuitBreaker.State`; otherwise
/// keep the actor (the executor overhead is not worth losing compile-time
/// isolation).
final class ActorVsLockBenchmark: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if targetEnvironment(simulator)
        throw XCTSkip("Performance measurements are not meaningful on emulated simulator runners")
        #endif
    }

    private static let totalOps = 200_000
    private static let concurrency = 64
    private static let perTask = totalOps / concurrency

    /// Trivial synchronous state machine behind an actor.
    private actor ActorCounter {
        private var count = 0
        private let threshold = 5
        func tick() -> Bool {
            count += 1
            return count < threshold
        }
    }

    /// The same trivial state machine behind an unfair lock.
    private final class LockCounter: @unchecked Sendable {
        #if canImport(os)
        private let lock = OSAllocatedUnfairLock()
        #else
        private let lock = NSLock()
        #endif
        private var count = 0
        private let threshold = 5
        func tick() -> Bool {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count < threshold
        }
    }

    func testActorThroughputUnderContention() {
        let counter = ActorCounter()
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            let done = expectation(description: "actor")
            done.expectedFulfillmentCount = Self.concurrency
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<Self.concurrency {
                        group.addTask {
                            for _ in 0..<Self.perTask { _ = await counter.tick() }
                            done.fulfill()
                        }
                    }
                }
            }
            wait(for: [done], timeout: 120)
        }
    }

    func testLockThroughputUnderContention() {
        let counter = LockCounter()
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            let done = expectation(description: "lock")
            done.expectedFulfillmentCount = Self.concurrency
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<Self.concurrency {
                        group.addTask {
                            for _ in 0..<Self.perTask { _ = counter.tick() }
                            done.fulfill()
                        }
                    }
                }
            }
            wait(for: [done], timeout: 120)
        }
    }
}
