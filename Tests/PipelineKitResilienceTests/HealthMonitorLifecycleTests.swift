import Foundation
import Synchronization
import XCTest
@testable import _CircuitBreaker

@MainActor
final class HealthMonitorLifecycleTests: XCTestCase {
    func testEmptyConfigurationReleasesCapturedResources() async {
        let released = expectation(description: "Empty monitor releases its configuration")
        var middleware: HealthCheckMiddleware? = makeEmptyMiddleware(released: released)
        _ = await middleware?.getHealthStatus()

        middleware = nil

        await fulfillment(of: [released], timeout: 2)
    }

    func testEmptyConfigurationDoesNotCreateAScheduledTask() async {
        let scheduled = HealthLifecycleCounter()
        let middleware = HealthCheckMiddleware(
            configuration: .init(),
            now: { Date() },
            makeMonitoringTask: { operation in
                scheduled.increment()
                return Task { await operation() }
            }
        )

        await middleware.stopMonitoring()

        XCTAssertEqual(scheduled.value, 0)
    }

    func testConfiguredMonitorReleasesCapturedResourcesAfterAcknowledgedCheck() async {
        let recorded = expectation(description: "First periodic result was recorded")
        let released = expectation(description: "Configured monitor releases its health check")
        var middleware: HealthCheckMiddleware? = makeMiddleware(recorded: recorded, released: released)
        await fulfillment(of: [recorded], timeout: 2)
        withExtendedLifetime(middleware) {}

        middleware = nil

        await fulfillment(of: [released], timeout: 2)
    }

    func testMiddlewareCopiesRetainSharedResourcesUntilLastCopyIsReleased() async {
        let recorded = expectation(description: "Shared monitor recorded its first result")
        let released = expectation(description: "Last middleware copy releases the monitor")
        let witness = HealthWeakLifetimeWitness()
        var original: HealthCheckMiddleware? = makeMiddleware(
            recorded: recorded, released: released, weakWitness: witness
        )
        var copy = original
        await fulfillment(of: [recorded], timeout: 2)

        original = nil
        let status = await copy?.getHealthStatus(for: "service")
        XCTAssertEqual(status?.state, .healthy)
        XCTAssertNotNil(witness.value)

        copy = nil

        await fulfillment(of: [released], timeout: 2)
        XCTAssertNil(witness.value)
    }

    func testReleasingLastCopyCancelsInFlightCooperativeHealthCheck() async {
        let entered = expectation(description: "Periodic health check entered")
        let cancelled = expectation(description: "Owner release cancels the active check")
        let settled = expectation(description: "Cancelled health check settled")
        let released = expectation(description: "Settled monitor releases the health check")
        let gate = HealthLifecycleCheckGate(entered: entered, cancelled: cancelled)
        var middleware: HealthCheckMiddleware? = makeHeldMiddleware(
            gate: gate, settled: settled, released: released
        )
        await fulfillment(of: [entered], timeout: 2)
        withExtendedLifetime(middleware) {}

        middleware = nil

        await fulfillment(of: [cancelled], timeout: 2)
        // Release the fixture even when the cancellation regression is present.
        gate.release()
        await fulfillment(of: [settled, released], timeout: 2)
    }

    func testStopDuringSleepPreventsFurtherPeriodicChecksAndAllowsManualChecks() async {
        let sleeping = expectation(description: "Periodic scheduler entered sleep")
        let cancelled = expectation(description: "Stop cancels scheduler sleep")
        let sleeper = HealthLifecycleCheckGate(entered: sleeping, cancelled: cancelled)
        let checks = HealthLifecycleCounter()
        let middleware = HealthCheckMiddleware(
            configuration: .init(healthChecks: [
                "service": HealthClosureProbe {
                    checks.increment()
                    return .healthy()
                }
            ]),
            now: { Date() },
            sleep: { _ in await sleeper.wait() }
        )
        await fulfillment(of: [sleeping], timeout: 2)
        XCTAssertEqual(checks.value, 1)

        await middleware.stopMonitoring()

        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(checks.value, 1)
        let manual = await middleware.checkHealth(for: "service")
        XCTAssertEqual(manual.status, .healthy)
        XCTAssertEqual(checks.value, 2)
        await middleware.stopMonitoring()
        XCTAssertEqual(checks.value, 2)
    }

    func testConcurrentStopCallsJoinCheckSettlementAndStopEveryMiddlewareCopy() async {
        let entered = expectation(description: "First periodic check entered")
        let cancelled = expectation(description: "Concurrent stops cancel the active check")
        let stopped = expectation(description: "Both stops returned")
        stopped.expectedFulfillmentCount = 2
        let completedStops = HealthLifecycleCounter()
        let gate = HealthLifecycleCheckGate(
            entered: entered, cancelled: cancelled, releaseOnCancellation: false
        )
        let checks = HealthLifecycleCounter()
        let probe = HealthClosureProbe {
            checks.increment()
            await gate.wait()
            return .healthy()
        }
        let middleware = HealthCheckMiddleware(configuration: .init(
            healthChecks: ["a": probe, "b": probe]
        ))
        let copy = middleware
        await fulfillment(of: [entered], timeout: 2)

        let first = Task {
            await middleware.stopMonitoring()
            completedStops.increment()
            stopped.fulfill()
        }
        let second = Task {
            await copy.stopMonitoring()
            completedStops.increment()
            stopped.fulfill()
        }
        await fulfillment(of: [cancelled], timeout: 2)
        let prematureStop = await XCTWaiter.fulfillment(of: [stopped], timeout: 0.05)
        XCTAssertEqual(prematureStop, .timedOut)
        XCTAssertEqual(completedStops.value, 0)

        gate.release()
        await first.value
        await second.value
        await copy.stopMonitoring()

        XCTAssertEqual(checks.value, 1, "Stopping the batch must prevent its second check")
        XCTAssertEqual(completedStops.value, 2)
    }

    func testStopBeforeInitialTaskRunsJoinsItWithoutStartingACheck() async {
        let scheduled = expectation(description: "Initial scheduler task is installed")
        let cancelled = expectation(description: "Stop cancels the installed initial task")
        let stopped = expectation(description: "Initial task stop returned")
        let startup = HealthLifecycleCheckGate(
            entered: scheduled, cancelled: cancelled, releaseOnCancellation: false
        )
        let checks = HealthLifecycleCounter()
        let middleware = HealthCheckMiddleware(
            configuration: .init(healthChecks: [
                "service": HealthClosureProbe {
                    checks.increment()
                    return .healthy()
                }
            ]),
            now: { Date() },
            makeMonitoringTask: { operation in
                Task {
                    await startup.wait()
                    await operation()
                }
            }
        )
        await fulfillment(of: [scheduled], timeout: 2)

        let stopping = Task { await middleware.stopMonitoring(); stopped.fulfill() }
        await fulfillment(of: [cancelled], timeout: 2)
        let prematureStop = await XCTWaiter.fulfillment(of: [stopped], timeout: 0.05)
        XCTAssertEqual(prematureStop, .timedOut)
        startup.release()
        await stopping.value

        XCTAssertEqual(checks.value, 0)
    }

    func testStopCancelsAndJoinsPeriodicStateChangeCallback() async {
        let entered = expectation(description: "Periodic state-change callback entered")
        let cancelled = expectation(description: "Stop cancels the periodic callback")
        let stopped = expectation(description: "Callback stop returned")
        let callback = HealthLifecycleCheckGate(
            entered: entered, cancelled: cancelled, releaseOnCancellation: false
        )
        let middleware = HealthCheckMiddleware(configuration: .init(
            healthChecks: ["service": HealthClosureProbe { .healthy() }],
            stateChangeHandler: { _, _, _ in await callback.wait() }
        ))
        await fulfillment(of: [entered], timeout: 2)

        let stopping = Task { await middleware.stopMonitoring(); stopped.fulfill() }
        await fulfillment(of: [cancelled], timeout: 2)
        let prematureStop = await XCTWaiter.fulfillment(of: [stopped], timeout: 0.05)
        XCTAssertEqual(prematureStop, .timedOut)
        callback.release()
        await stopping.value
    }

    func testCancelledPeriodicCheckDoesNotRecordAResultOrStartANotification() async {
        let timeouts: [TimeInterval?] = [nil, 60]
        for timeout in timeouts {
            let entered = expectation(description: "Periodic check entered before stop")
            let cancelled = expectation(description: "Stop cancelled the periodic check")
            let gate = HealthLifecycleCheckGate(
                entered: entered, cancelled: cancelled, releaseOnCancellation: false
            )
            let notifications = HealthLifecycleCounter()
            let middleware = HealthCheckMiddleware(configuration: .init(
                healthChecks: [
                    "service": HealthClosureProbe(timeout: timeout) {
                        await gate.wait()
                        return .healthy()
                    }
                ],
                stateChangeHandler: { _, _, _ in notifications.increment() }
            ))
            await fulfillment(of: [entered], timeout: 2)

            let stopping = Task { await middleware.stopMonitoring() }
            await fulfillment(of: [cancelled], timeout: 2)
            gate.release()
            await stopping.value

            let status = await middleware.getHealthStatus(for: "service")
            XCTAssertEqual(status.state, .unknown)
            XCTAssertNil(status.lastCheck)
            XCTAssertEqual(notifications.value, 0)
        }
    }

    func testPeriodicCallbacksDoNotBlockOtherConfiguredChecks() async {
        let checked = expectation(description: "Both configured checks ran")
        checked.expectedFulfillmentCount = 2
        let entered = expectation(description: "First periodic callback entered")
        let cancelled = expectation(description: "Stop cancels the active periodic callback")
        let callback = HealthLifecycleCheckGate(entered: entered, cancelled: cancelled)
        let callbacks = HealthLifecycleCounter()
        let probe = HealthClosureProbe {
            checked.fulfill()
            return .healthy()
        }
        let middleware = HealthCheckMiddleware(configuration: .init(
            checkInterval: 3_600,
            healthChecks: ["a": probe, "b": probe],
            stateChangeHandler: { _, _, _ in
                if callbacks.incrementAndGet() == 1 { await callback.wait() }
            }
        ))

        await fulfillment(of: [entered, checked], timeout: 2)
        await middleware.stopMonitoring()
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(callbacks.value, 2)
    }

    func testHealthCheckCanStopItselfWhileExternalStopStillJoinsSettlement() async {
        let timeouts: [TimeInterval?] = [nil, 60]
        for timeout in timeouts {
            let returned = expectation(description: "Health check self-stop returned")
            let entered = expectation(description: "Health check is settling after self-stop")
            let cancelled = expectation(description: "Self-stop cancelled its check")
            let stopped = expectation(description: "External stop returned")
            let gate = HealthLifecycleCheckGate(
                entered: entered, cancelled: cancelled, releaseOnCancellation: false
            )
            let mailbox = HealthLifecycleMiddlewareMailbox()
            let middleware = HealthCheckMiddleware(configuration: .init(
                healthChecks: [
                    "service": HealthClosureProbe(timeout: timeout) {
                        let owner = await mailbox.take()
                        await owner.stopMonitoring()
                        returned.fulfill()
                        await gate.wait()
                        return .healthy()
                    }
                ]
            ))
            await mailbox.put(middleware)
            await fulfillment(of: [returned, entered, cancelled], timeout: 2)

            let stopping = Task { await middleware.stopMonitoring(); stopped.fulfill() }
            let prematureStop = await XCTWaiter.fulfillment(of: [stopped], timeout: 0.05)
            XCTAssertEqual(prematureStop, .timedOut)
            gate.release()
            await stopping.value
        }
    }

    func testPeriodicStateChangeCallbackCanStopItselfWhileExternalStopJoinsSettlement() async {
        let returned = expectation(description: "Periodic callback self-stop returned")
        let entered = expectation(description: "Periodic callback is settling after self-stop")
        let cancelled = expectation(description: "Self-stop cancelled its callback")
        let stopped = expectation(description: "External callback stop returned")
        let gate = HealthLifecycleCheckGate(
            entered: entered, cancelled: cancelled, releaseOnCancellation: false
        )
        let mailbox = HealthLifecycleMiddlewareMailbox()
        let middleware = HealthCheckMiddleware(configuration: .init(
            healthChecks: ["service": HealthClosureProbe { .healthy() }],
            stateChangeHandler: { _, _, _ in
                let owner = await mailbox.take()
                await owner.stopMonitoring()
                returned.fulfill()
                await gate.wait()
            }
        ))
        await mailbox.put(middleware)
        await fulfillment(of: [returned, entered, cancelled], timeout: 2)

        let stopping = Task { await middleware.stopMonitoring(); stopped.fulfill() }
        let prematureStop = await XCTWaiter.fulfillment(of: [stopped], timeout: 0.05)
        XCTAssertEqual(prematureStop, .timedOut)
        gate.release()
        await stopping.value
    }

    func testStopFromAnUnrelatedMonitorStillJoinsTheTargetCheck() async {
        let entered = expectation(description: "Target monitor check entered")
        let cancelled = expectation(description: "Other monitor cancelled the target")
        let returned = expectation(description: "Other monitor returned from target stop")
        let gate = HealthLifecycleCheckGate(
            entered: entered, cancelled: cancelled, releaseOnCancellation: false
        )
        let target = HealthCheckMiddleware(configuration: .init(
            healthChecks: [
                "target": HealthClosureProbe {
                    await gate.wait()
                    return .healthy()
                }
            ]
        ))
        await fulfillment(of: [entered], timeout: 2)
        let other = HealthCheckMiddleware(configuration: .init(
            healthChecks: [
                "other": HealthClosureProbe {
                    await target.stopMonitoring()
                    returned.fulfill()
                    return .healthy()
                }
            ]
        ))
        await fulfillment(of: [cancelled], timeout: 2)
        let prematureStop = await XCTWaiter.fulfillment(of: [returned], timeout: 0.05)
        XCTAssertEqual(prematureStop, .timedOut)

        gate.release()
        await other.stopMonitoring()
        await target.stopMonitoring()
    }

    func testManualCheckNotificationsRemainIndependentOfPeriodicStop() async {
        let entered = expectation(description: "Manual check notification entered")
        let settled = expectation(description: "Manual check notification settled")
        let cancelled = expectation(description: "Manual callback must not be cancelled by periodic stop")
        cancelled.isInverted = true
        let gate = HealthLifecycleCheckGate(entered: entered, cancelled: cancelled)
        let middleware = HealthCheckMiddleware(
            configuration: .init(
                healthChecks: ["service": HealthClosureProbe { .healthy() }],
                stateChangeHandler: { _, _, _ in
                    await gate.wait()
                    settled.fulfill()
                }
            ),
            now: { Date() },
            startPeriodicHealthChecks: false
        )

        let result = await middleware.checkHealth(for: "service")
        XCTAssertEqual(result.status, .healthy)
        await fulfillment(of: [entered], timeout: 2)
        await middleware.stopMonitoring()
        await fulfillment(of: [cancelled], timeout: 0.05)

        gate.release()
        await fulfillment(of: [settled], timeout: 2)
    }

    private func makeEmptyMiddleware(released: XCTestExpectation) -> HealthCheckMiddleware {
        let witness = HealthLifetimeWitness(released: released)
        return HealthCheckMiddleware(configuration: .init(
            stateChangeHandler: { _, _, _ in witness.recordUse() }
        ))
    }

    private func makeMiddleware(
        recorded: XCTestExpectation,
        released: XCTestExpectation,
        weakWitness: HealthWeakLifetimeWitness? = nil
    ) -> HealthCheckMiddleware {
        let witness = HealthLifetimeWitness(released: released)
        weakWitness?.value = witness
        return HealthCheckMiddleware(configuration: .init(
            checkInterval: 3_600,
            healthChecks: ["service": HealthLifecycleProbe(witness: witness)],
            stateChangeHandler: { _, _, state in
                if state == .healthy { recorded.fulfill() }
            }
        ))
    }

    private func makeHeldMiddleware(
        gate: HealthLifecycleCheckGate,
        settled: XCTestExpectation,
        released: XCTestExpectation
    ) -> HealthCheckMiddleware {
        HealthCheckMiddleware(configuration: .init(
            checkInterval: 3_600,
            healthChecks: [
                "service": HealthLifecycleProbe(
                    witness: HealthLifetimeWitness(released: released), gate: gate, settled: settled
                )
            ]
        ))
    }
}

private final class HealthLifetimeWitness: Sendable {
    private let uses = Mutex(0)
    private let released: XCTestExpectation

    init(released: XCTestExpectation) { self.released = released }

    func recordUse() { uses.withLock { $0 += 1 } }

    deinit { released.fulfill() }
}

private final class HealthWeakLifetimeWitness {
    weak var value: HealthLifetimeWitness?
}

private struct HealthLifecycleProbe: HealthCheck {
    let name = "lifecycle"
    let timeout: TimeInterval? = nil
    let witness: HealthLifetimeWitness
    var gate: HealthLifecycleCheckGate?
    var settled: XCTestExpectation?

    func check() async -> HealthCheckResult {
        if let gate { await gate.wait() }
        witness.recordUse()
        settled?.fulfill()
        return .healthy()
    }
}

private struct HealthClosureProbe: HealthCheck {
    let name = "closure"
    var timeout: TimeInterval?
    let operation: @Sendable () async -> HealthCheckResult

    init(timeout: TimeInterval? = nil, operation: @escaping @Sendable () async -> HealthCheckResult) {
        self.timeout = timeout
        self.operation = operation
    }

    func check() async -> HealthCheckResult { await operation() }
}

private final class HealthLifecycleCounter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
    func incrementAndGet() -> Int {
        storage.withLock {
            $0 += 1
            return $0
        }
    }
}

private actor HealthLifecycleMiddlewareMailbox {
    private var value: HealthCheckMiddleware?
    private var waiter: CheckedContinuation<HealthCheckMiddleware, Never>?

    func put(_ middleware: HealthCheckMiddleware) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: middleware)
        } else {
            value = middleware
        }
    }

    func take() async -> HealthCheckMiddleware {
        if let value {
            self.value = nil
            return value
        }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private final class HealthLifecycleCheckGate: Sendable {
    private struct State {
        var released = false
        var cancelled = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())
    private let entered: XCTestExpectation
    private let cancelled: XCTestExpectation
    private let releaseOnCancellation: Bool

    init(entered: XCTestExpectation, cancelled: XCTestExpectation, releaseOnCancellation: Bool = true) {
        self.entered = entered
        self.cancelled = cancelled
        self.releaseOnCancellation = releaseOnCancellation
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resume = state.withLock { state in
                    if state.released { return true }
                    state.continuation = continuation
                    return false
                }
                entered.fulfill()
                if resume { continuation.resume() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func release() {
        let continuation = state.withLock { state in
            state.released = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func cancel() {
        let firstCancellation = state.withLock { state in
            if state.cancelled { return false }
            state.cancelled = true
            return true
        }
        if firstCancellation { cancelled.fulfill() }
        if releaseOnCancellation { release() }
    }
}
