import XCTest
// `@testable import` of the internal Foundation target to reach the internal
// `AsyncSemaphore.waiterCount()`, following the precedent in `SemaphoreEvolutionTests`.
@testable import _ResilienceFoundation
import PipelineKit

/// Regression tests for the `AsyncSemaphore` cancellation contract:
/// a cancelled `wait()` must never return normally, and a signal consumed by a
/// cancelled waiter must be forwarded, not dropped.
///
/// Mirrors the race fixed in `SimpleSemaphore` (PR #73) and
/// `BackPressureSemaphore` (PR #74): `onCancel` only *spawns* a task to run
/// `handleCancellationForWaiter`, so a concurrent `signal()` can reach the
/// actor first, pop the already-cancelled waiter from the heap, and resume it
/// with `.signaled`. No token is involved, so nothing deadlocks — but `wait()`
/// then returns success from a cancelled task, and the caller (which pairs
/// every successful `wait()` with a later `signal()`, e.g. `ObjectPool`)
/// proceeds as if it owns a resource it should have relinquished.
final class AsyncSemaphoreContractTests: XCTestCase {
    func testCancelledWaiterDoesNotSwallowSignal() async throws {
        // Iterate to exercise both orders of the raced work: the spawned
        // cancellation task vs. the direct signal() call.
        for iteration in 0..<200 {
            let semaphore = AsyncSemaphore(value: 0)

            let waiter = Task {
                try await semaphore.wait()
            }

            // Deterministically wait until the waiter is parked in the queue.
            while await semaphore.waiterCount() == 0 {
                await Task.yield()
            }

            // Race cancellation against signal.
            waiter.cancel()
            await semaphore.signal()

            do {
                try await waiter.value
                XCTFail("wait() returned normally in a cancelled task (iteration \(iteration))")
                return
            } catch {
                // Expected: a cancelled wait() must throw
                // (PipelineError.cancelled, matching the other cancel paths).
            }

            // Signal conservation: exactly one resource must exist afterwards,
            // in EITHER order of the race. If cancellation won, the waiter was
            // resumed as cancelled and the (awaited) signal restored a
            // resource. If signal won, the cancelled waiter must forward the
            // consumed signal before throwing — synchronously on the actor,
            // so it is visible by the time `waiter.value` rethrows. Pre-fix,
            // the signal-won order swallowed the wakeup (count 0): the
            // resource vanished into a task that will never signal it back.
            let resources = await semaphore.availableResourcesCount()
            XCTAssertEqual(
                resources, 1,
                "Signal lost or duplicated after cancel/signal race (iteration \(iteration))"
            )
        }
    }

    func testCancelledTimeoutWaiterDoesNotSwallowSignal() async throws {
        // Same race through acquire(timeout:), which documents "false if the
        // task was cancelled". Pre-fix, a signal() that beat the spawned
        // cancellation task resumed the cancelled waiter with .signaled and
        // acquire returned true from a cancelled task.
        for iteration in 0..<200 {
            let semaphore = AsyncSemaphore(value: 0)

            // Timeout far beyond the race window so it cannot interfere.
            let waiter = Task {
                await semaphore.acquire(timeout: 5.0)
            }

            while await semaphore.waiterCount() == 0 {
                await Task.yield()
            }

            waiter.cancel()
            await semaphore.signal()

            let acquired = await waiter.value
            XCTAssertFalse(
                acquired,
                "acquire(timeout:) returned true in a cancelled task (iteration \(iteration))"
            )
            if acquired { return }

            let resources = await semaphore.availableResourcesCount()
            XCTAssertEqual(
                resources, 1,
                "Signal lost or duplicated after cancel/signal race (iteration \(iteration))"
            )
        }
    }
}
