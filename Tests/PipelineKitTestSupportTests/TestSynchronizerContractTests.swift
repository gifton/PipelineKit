import XCTest
@testable import PipelineKitTestSupport

final class TestSynchronizerContractTests: XCTestCase {
    func testAlreadyCancelledWaitThrowsWithoutRegistering() async {
        let synchronizer = TestSynchronizer()
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await synchronizer.waitForSignal("cancelled")
                return false
            } catch {
                return error is CancellationError
            }
        }
        let cancelled = await waiter.value
        let registered = await synchronizer.waiterCount(for: "cancelled")
        XCTAssertTrue(cancelled)
        XCTAssertEqual(registered, 0)
    }

    func testCancellationRemovesOnlyItsOwnWaiter() async {
        let synchronizer = TestSynchronizer()
        let cancelled = Task {
            do {
                try await synchronizer.waitForSignal("shared")
                return false
            } catch {
                return error is CancellationError
            }
        }
        let survivor = Task { try await synchronizer.waitForSignal("shared") }
        await waitForRegistration(2, checkpoint: "shared", on: synchronizer)
        cancelled.cancel()
        let wasCancelled = await cancelled.value
        XCTAssertTrue(wasCancelled)
        let remaining = await synchronizer.waiterCount(for: "shared")
        XCTAssertEqual(remaining, 1)
        await synchronizer.signal("shared")
        do { try await survivor.value } catch { XCTFail("Unrelated waiter cancelled: \(error)") }
        let registered = await synchronizer.waiterCount(for: "shared")
        XCTAssertEqual(registered, 0)
    }

    func testResetCancelsWaitersAndClearsSignals() async {
        let synchronizer = TestSynchronizer()
        await synchronizer.signal("old signal")
        let waiter = Task {
            do {
                try await synchronizer.waitForSignal("pending")
                return false
            } catch {
                return error is CancellationError
            }
        }
        await waitForRegistration(1, checkpoint: "pending", on: synchronizer)
        await synchronizer.reset()
        let cancelled = await waiter.value
        let signaled = await synchronizer.isSignaled("old signal")
        let registered = await synchronizer.waiterCount(for: "pending")
        XCTAssertTrue(cancelled)
        XCTAssertFalse(signaled)
        XCTAssertEqual(registered, 0)
    }

    func testSignalBeforeAndAfterRegistrationSucceeds() async throws {
        let synchronizer = TestSynchronizer()
        await synchronizer.signal("ready")
        try await synchronizer.waitForSignal("ready")
        let waiter = Task { try await synchronizer.waitForSignal("later") }
        await waitForRegistration(1, checkpoint: "later", on: synchronizer)
        await synchronizer.signal("later")
        try await waiter.value
    }

    private func waitForRegistration(_ count: Int, checkpoint: String, on synchronizer: TestSynchronizer) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await synchronizer.waiterCount(for: checkpoint) != count && ContinuousClock.now < deadline {
            await Task.yield()
        }
        let registered = await synchronizer.waiterCount(for: checkpoint)
        XCTAssertEqual(registered, count, "Fixture did not register expected waiters")
    }
}
