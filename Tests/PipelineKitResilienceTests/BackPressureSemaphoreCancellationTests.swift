import XCTest
// `@testable import` of the internal Foundation target to name `BackPressureSemaphore`
// directly, following the precedent in `SemaphoreEvolutionTests`.
@testable import _ResilienceFoundation
import PipelineKit

/// Regression tests for `BackPressureSemaphore` cancellation races and lifecycle.
///
/// Mirrors `SimpleSemaphoreCancellationTests.testCancelledWaiterNeverReceivesToken`
/// (PR #73): both semaphores share the same waiter-queue + `SemaphoreToken` design
/// and therefore had the same lost-wakeup bug.
final class BackPressureSemaphoreCancellationTests: XCTestCase {
    func testCancelledWaiterNeverReceivesToken() async throws {
        // Regression test for a lost-wakeup deadlock: cancelling a parked
        // waiter races the token release. `onCancel` spawns a task to run
        // `cancelWaiter` while `SemaphoreToken`'s release handler spawns a task
        // to run `release()`; if `release()` reached the actor first, it popped
        // the cancelled waiter from the heap and resumed it with a token, so
        // `acquire()` returned success from a cancelled task. The token could
        // then be stranded (here: in the completed Task's result storage, which
        // lives until the Task handle goes away), trapping the permit and
        // hanging every subsequent acquire — with a fully idle cooperative pool.
        //
        // Iterate to exercise both orders of the raced unstructured tasks.
        for iteration in 0..<200 {
            let semaphore = BackPressureSemaphore(maxConcurrency: 1)
            let token1 = try await semaphore.acquire()

            let waiter = Task {
                try await semaphore.acquire()
            }

            // Deterministically wait until the waiter is parked in the queue.
            while await semaphore.getStats().queuedOperations == 0 {
                await Task.yield()
            }

            // Race cancellation against release.
            waiter.cancel()
            token1.release()

            do {
                let stray = try await waiter.value
                // Pre-fix failure mode: release the stray token so this test
                // fails loudly instead of deadlocking the suite.
                stray.release()
                XCTFail("Cancelled waiter received a token (iteration \(iteration))")
                return
            } catch is CancellationError {
                // Expected: a cancelled acquire() must throw.
            }

            // The permit must be conserved: pre-fix, the bad interleaving
            // trapped it in `waiter`'s result storage and this acquire
            // deadlocked forever.
            let token2 = try await semaphore.acquire()
            token2.release()
        }
    }

    func testCleanupTaskDiesWithSemaphore() async throws {
        // Regression test for a lifecycle leak: the cleanup task was started as
        // `Task { [weak self] in await self?.runCleanupLoop() }`. The weak
        // capture is upgraded to a strong reference for the duration of the
        // `runCleanupLoop()` call — which is an infinite 1s-timer loop — so the
        // task retained the actor forever, `deinit` (the only implicit cancel
        // path) could never run, and every semaphore that ever ran acquire()
        // leaked itself plus a once-per-second background task past suite
        // teardown.
        weak var weakSemaphore: BackPressureSemaphore?
        do {
            let semaphore = BackPressureSemaphore(maxConcurrency: 1)
            weakSemaphore = semaphore
            // The slow-path machinery is irrelevant here; any acquire() starts
            // the cleanup task.
            let token = try await semaphore.acquire()
            token.release()
            // Give the spawned cleanup task time to actually enter its loop
            // before we drop the last reference. If the last reference drops
            // before the task ever runs, its weak capture resolves to nil and
            // the leak is masked (the task exits without retaining anything).
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        // The token's release handler runs in a detached task holding a weak
        // reference, so deallocation may trail the scope exit briefly. Poll
        // with a generous deadline; pre-fix this never becomes nil.
        let deadline = Date().addingTimeInterval(5)
        while weakSemaphore != nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(
            weakSemaphore,
            "Semaphore must deallocate once unreferenced; a live reference means the cleanup task retains the actor and its 1s timer loop outlives the semaphore"
        )
    }
}
