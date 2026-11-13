import XCTest
import PipelineKit
import PipelineKitTestSupport

final class TimeoutTesterContractTests: XCTestCase {
    func testOperationErrorsDoNotCountAsOwnedDeadline() async {
        let tester = TimeoutTester()
        let errors: [any Error & Sendable] = [
            CancellationError(),
            PipelineError.cancelled(context: "operation cancellation"),
            PipelineError.timeout(duration: 99, context: nil)
        ]
        for error in errors {
            // The deadline must be far beyond any scheduling stall: the helper races
            // the throwing operation against a sleep, and with a 1s deadline a stall
            // past it could let the sleep win.
            let timedOut = await tester.expectTimeout(within: 30) { () -> Int in throw error }
            XCTAssertFalse(timedOut, "Operation error must not be reported as the helper's deadline: \(error)")
        }
    }

    func testOwnedDeadlineThrowsTimeoutAndSettlesOperationCancellation() async {
        let settled = TestSynchronizer()
        do {
            _ = try await TimeoutTester().withTimeout(0.02) { () -> Int in
                do {
                    try await Task.sleep(for: .seconds(30))
                    return 1
                } catch {
                    await settled.signal("operation settled")
                    throw error
                }
            }
            XCTFail("Expected the helper's deadline")
        } catch let error as PipelineError {
            guard case .timeout(let duration, _) = error else {
                return XCTFail("Expected timeout, received \(error)")
            }
            XCTAssertEqual(duration, 0.02, accuracy: 0.000001)
        } catch {
            XCTFail("Expected PipelineError.timeout, received \(error)")
        }
        let didSettle = await settled.isSignaled("operation settled")
        XCTAssertTrue(didSettle, "Structured return must wait for the losing operation")
    }

    func testOwnedDeadlineIsRecognized() async {
        let timedOut = await TimeoutTester().expectTimeout(within: 0.02) { () -> Int in
            try await Task.sleep(for: .seconds(30))
            return 1
        }
        XCTAssertTrue(timedOut)
    }

    func testThrowingOperationDoesNotWaitForLosingTimer() async {
        struct ExpectedFailure: Error {}
        let start = ContinuousClock.now
        do {
            // The losing timer is 30s and the bound 10s: returning under the bound
            // proves the helper did not wait for the timer, and neither number is
            // within reach of a scheduling stall (they were 2s and 1s).
            _ = try await TimeoutTester().withTimeout(30) { () -> Int in throw ExpectedFailure() }
            XCTFail("Expected operation error")
        } catch {
            XCTAssertTrue(error is ExpectedFailure)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(10))
    }

    func testCancelledCallerDoesNotCountAsOwnedDeadline() async {
        let operationStarted = TestSynchronizer()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TimeoutTester().expectTimeout(within: 0) {
                await operationStarted.signal("started")
                return 1
            }
        }
        let timedOut = await caller.value
        let started = await operationStarted.isSignaled("started")
        XCTAssertFalse(timedOut)
        XCTAssertFalse(started)
    }

    // The test runner must have an external watchdog: this deliberately exercises
    // an operation that ignores cancellation until its explicit settlement gate opens.
    func testDeadlineJoinsOperationThatTemporarilyIgnoresCancellation() async throws {
        let observations = TestSynchronizer()
        let settlement = TimeoutSettlementGate()
        let caller = Task {
            let result: Bool
            do {
                _ = try await TimeoutTester().withTimeout(0.02) { () -> Int in
                    do { try await Task.sleep(for: .seconds(30)) } catch {
                        await observations.signal("cancellation observed")
                        await settlement.wait()
                    }
                    return 1
                }
                result = false
            } catch let error as PipelineError {
                if case .timeout = error { result = true } else { result = false }
            } catch {
                result = false
            }
            await observations.signal("caller returned")
            return result
        }
        try await observations.waitForSignal("cancellation observed")
        let returnedBeforeSettlement = await observations.isSignaled("caller returned")
        XCTAssertFalse(returnedBeforeSettlement)
        await settlement.open()
        let timedOut = await caller.value
        XCTAssertTrue(timedOut)
    }

    func testLegacyCheckpointWaitReturnsWhenCancelledWithoutSignaling() async {
        let synchronizer = TestSynchronizer()
        let returned = expectation(description: "cancelled wait returned")
        let waiter = Task {
            await synchronizer.wait(for: "never signaled")
            returned.fulfill()
        }
        waiter.cancel()
        // Hang detector, not a latency bound.
        await fulfillment(of: [returned], timeout: 10)
        let signaled = await synchronizer.isSignaled("never signaled")
        XCTAssertFalse(signaled)
        // Settle the fixture even when the assertion fails against the old helper.
        await synchronizer.signal("never signaled")
        await waiter.value
    }
}

private actor TimeoutSettlementGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
