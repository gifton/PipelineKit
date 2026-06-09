import XCTest
// `@testable import` of the internal Foundation target is required to reach
// `AsyncSemaphore.waiterCount()`, which is `internal`, and to name the semaphore
// types directly. Precedent: other tests in this target (e.g.
// HealthCheckMiddlewareTests) `@testable import _CircuitBreaker`. The test target
// is built with `-enable-testing`, and `_ResilienceFoundation` is a transitive
// dependency via `PipelineKitResilience` (the declared dependency), so it is in
// the build graph and built with testing enabled.
@testable import _ResilienceFoundation
import PipelineKit
import PipelineKitTestSupport

/// Tests for the evolution of the resilience semaphores:
/// - C2: `AsyncSemaphore` cancellation race / orphaned-continuation fix.
/// - P3: migration of both semaphores from O(n) waiter arrays to the O(log n)
///   `PriorityHeap`, preserving FIFO (AsyncSemaphore) and priority-then-FIFO
///   (BackPressureSemaphore) serve order.
final class SemaphoreEvolutionTests: XCTestCase {
    // MARK: - Helpers

    /// Records ordered string labels in a Sendable, actor-isolated buffer.
    private actor Recorder {
        private var items: [String] = []
        func add(_ item: String) { items.append(item) }
        func snapshot() -> [String] { items }
    }

    /// Polls `condition` until it returns true or `timeout` elapses.
    /// - Returns: true if the condition became satisfied within the timeout.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.01,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return await condition()
    }

    // MARK: - AsyncSemaphore: cancellation race (C2)

    /// Exhaust the semaphore, start a `wait()` task under contention, cancel it
    /// immediately, and assert it unblocks promptly with the waiter queue draining
    /// back to zero (no orphaned continuation).
    func testAsyncSemaphoreCancelUnderContentionNoOrphan() async throws {
        let semaphore = AsyncSemaphore(value: 1)

        // Exhaust the single resource so the next waiter must suspend.
        try await semaphore.wait()
        let drained = await semaphore.availableResourcesCount()
        XCTAssertEqual(drained, 0, "Resource should be exhausted before contention")

        // Start a waiter and cancel it as close to the suspension point as possible
        // to exercise the TOCTOU window between checkCancellation() and the
        // continuation body running.
        let waiterTask = Task {
            do {
                try await semaphore.wait()
            } catch {
                // Expected on cancellation.
            }
        }
        waiterTask.cancel()
        _ = await waiterTask.value

        // The waiter must drain promptly; if the continuation were orphaned, the
        // count would stay at 1 forever.
        let drainedQueue = await waitUntil { await semaphore.waiterCount() == 0 }
        XCTAssertTrue(drainedQueue, "Cancelled waiter must be removed (no orphan)")

        let waiters = await semaphore.waiterCount()
        XCTAssertEqual(waiters, 0, "Waiter queue should be empty after cancellation")

        // Resources are not fabricated by cancellation; still 0 (held by us).
        let afterCancel = await semaphore.availableResourcesCount()
        XCTAssertEqual(afterCancel, 0, "Cancellation must not create phantom resources")

        // The semaphore remains functional: release, then re-acquire.
        await semaphore.signal()
        let restored = await semaphore.availableResourcesCount()
        XCTAssertEqual(restored, 1, "Signal should restore the held resource")
        try await semaphore.wait()
        let reacquired = await semaphore.availableResourcesCount()
        XCTAssertEqual(reacquired, 0, "Resource should be re-acquirable")
    }

    /// Many racing waiters, each cancelled immediately. All must unblock and the
    /// waiter queue must return to zero with no hangs.
    func testAsyncSemaphoreManyRacingCancellations() async throws {
        let semaphore = AsyncSemaphore(value: 0) // every waiter suspends
        let count = 50

        var tasks: [Task<Void, Never>] = []
        tasks.reserveCapacity(count)
        for _ in 0..<count {
            let task = Task {
                do {
                    try await semaphore.wait()
                } catch {
                    // Expected on cancellation.
                }
            }
            // Cancel immediately to race the suspension.
            task.cancel()
            tasks.append(task)
        }

        for task in tasks {
            _ = await task.value
        }

        let drained = await waitUntil { await semaphore.waiterCount() == 0 }
        XCTAssertTrue(drained, "All racing cancelled waiters must drain (no orphans)")
        let waiters = await semaphore.waiterCount()
        XCTAssertEqual(waiters, 0, "Waiter queue should be empty")

        // Semaphore still usable.
        let acquired = await semaphore.acquire(timeout: 0.2)
        // value started at 0; nothing released it, so a fresh acquire with a short
        // timeout should fail (it must not hang and must not erroneously succeed).
        XCTAssertFalse(acquired, "No resource was released; timed acquire should fail cleanly")
    }

    // MARK: - AsyncSemaphore: FIFO ordering preserved after migration

    /// Multiple waiters enqueued in a known order must be served FIFO by `signal()`.
    func testAsyncSemaphoreFIFOOrderPreserved() async throws {
        let semaphore = AsyncSemaphore(value: 0) // force all to queue
        let recorder = Recorder()
        let waiterCount = 5

        var tasks: [Task<Void, Never>] = []
        for i in 0..<waiterCount {
            let task = Task {
                do {
                    try await semaphore.wait()
                    await recorder.add("w\(i)")
                } catch {
                    XCTFail("Waiter w\(i) should not be cancelled")
                }
            }
            tasks.append(task)
            // Gap between enqueues guarantees a deterministic sequence order, which
            // is what the heap's `seq` key preserves.
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }

        // All five should be queued now.
        let allQueued = await waitUntil { await semaphore.waiterCount() == waiterCount }
        XCTAssertTrue(allQueued, "All waiters should be enqueued before signaling")

        // Release one at a time so each recorded label corresponds to exactly one
        // FIFO wakeup before the next signal.
        for _ in 0..<waiterCount {
            await semaphore.signal()
            // Let the woken waiter record before the next signal.
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        for task in tasks {
            _ = await task.value
        }

        let order = await recorder.snapshot()
        XCTAssertEqual(
            order,
            (0..<waiterCount).map { "w\($0)" },
            "FIFO order must be preserved by the heap-backed waiter queue"
        )
        let remaining = await semaphore.waiterCount()
        XCTAssertEqual(remaining, 0, "No waiters should remain")
    }

    // MARK: - BackPressureSemaphore: priority ordering

    /// Higher-priority waiters must be served before lower-priority ones regardless
    /// of enqueue order.
    func testBackPressurePriorityOrdering() async throws {
        let semaphore = BackPressureSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 100,
            strategy: .suspend
        )
        let recorder = Recorder()

        // Hold the only permit so subsequent acquisitions must queue.
        let holder = try await semaphore.acquire(priority: .normal)

        // Enqueue in an order that does NOT match priority order, to prove the heap
        // reorders by priority. Each is launched and given a small gap so it lands
        // in the queue before the next.
        let enqueue: [(String, BackPressureSemaphore.QueuePriority)] = [
            ("low", .low),
            ("critical", .critical),
            ("high", .high),
            ("normal", .normal)
        ]

        var tasks: [Task<Void, Never>] = []
        for (label, priority) in enqueue {
            let task = Task {
                do {
                    let token = try await semaphore.acquire(priority: priority)
                    await recorder.add(label)
                    // Release so the next-highest-priority waiter can proceed.
                    token.release()
                } catch {
                    XCTFail("Waiter \(label) should not error")
                }
            }
            tasks.append(task)
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms gap
        }

        // All four should be queued.
        let allQueued = await waitUntil {
            await semaphore.getStats().queuedOperations == 4
        }
        XCTAssertTrue(allQueued, "All four waiters should be queued behind the holder")

        // Release the holder; the chain of token releases drives the rest.
        holder.release()

        for task in tasks {
            _ = await task.value
        }

        let order = await recorder.snapshot()
        XCTAssertEqual(
            order,
            ["critical", "high", "normal", "low"],
            "Waiters must be served strictly by descending priority"
        )
    }

    // MARK: - BackPressureSemaphore: cancellation removes the correct waiter

    /// Cancelling one queued waiter must remove exactly that waiter; the others
    /// must still complete.
    func testBackPressureCancellationRemovesCorrectWaiter() async throws {
        let semaphore = BackPressureSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 100,
            strategy: .suspend
        )
        let recorder = Recorder()

        // Hold the only permit.
        let holder = try await semaphore.acquire(priority: .normal)

        // Three same-priority waiters → FIFO among them. Keep handles so we can
        // cancel the middle one.
        func makeWaiter(_ label: String) -> Task<Void, Never> {
            Task {
                do {
                    let token = try await semaphore.acquire(priority: .normal)
                    await recorder.add(label)
                    token.release()
                } catch {
                    // Cancelled waiter lands here; do not record.
                }
            }
        }

        let a = makeWaiter("a")
        try await Task.sleep(nanoseconds: 20_000_000)
        let b = makeWaiter("b")
        try await Task.sleep(nanoseconds: 20_000_000)
        let c = makeWaiter("c")
        try await Task.sleep(nanoseconds: 20_000_000)

        let allQueued = await waitUntil {
            await semaphore.getStats().queuedOperations == 3
        }
        XCTAssertTrue(allQueued, "Three waiters should be queued")

        // Cancel the middle waiter.
        b.cancel()
        _ = await b.value

        // Queue should shrink to exactly two.
        let shrank = await waitUntil {
            await semaphore.getStats().queuedOperations == 2
        }
        XCTAssertTrue(shrank, "Cancelling one waiter should leave exactly two queued")

        // Release the holder; remaining waiters drain via token release chaining.
        holder.release()

        _ = await a.value
        _ = await c.value

        let order = await recorder.snapshot()
        XCTAssertEqual(
            order,
            ["a", "c"],
            "Only the non-cancelled waiters should complete, in FIFO order"
        )
        XCTAssertFalse(order.contains("b"), "Cancelled waiter must not complete")
    }

    // MARK: - BackPressureSemaphore: shutdown drains all waiters

    /// `shutdown()` must fail every queued waiter and reset the queue to empty.
    func testBackPressureShutdownDrainsAllWaiters() async throws {
        let semaphore = BackPressureSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 100,
            strategy: .suspend
        )
        let failures = TestCounter()
        let successes = TestCounter()

        // Hold the only permit so the rest must queue.
        let holder = try await semaphore.acquire(priority: .normal)

        let count = 5
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<count {
            let task = Task {
                do {
                    let token = try await semaphore.acquire(priority: .normal)
                    await successes.increment()
                    token.release()
                } catch {
                    await failures.increment()
                }
            }
            tasks.append(task)
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        let allQueued = await waitUntil {
            await semaphore.getStats().queuedOperations == count
        }
        XCTAssertTrue(allQueued, "All five waiters should be queued before shutdown")

        // Shut down: every queued waiter should be resumed with an error.
        await semaphore.shutdown()

        for task in tasks {
            _ = await task.value
        }

        let failed = await failures.get()
        let succeeded = await successes.get()
        XCTAssertEqual(failed, count, "Every queued waiter should fail on shutdown")
        XCTAssertEqual(succeeded, 0, "No queued waiter should acquire after shutdown")

        let queued = await semaphore.getStats().queuedOperations
        XCTAssertEqual(queued, 0, "Shutdown should reset the waiter queue to empty")

        // Keep the holder alive until the end so the queued waiters could only have
        // been resumed by shutdown (not by the holder releasing early).
        _ = holder
    }
}
