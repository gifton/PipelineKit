import Foundation
import Synchronization
import XCTest
import PipelineKit
import PipelineKitCore
import PipelineKitResilience
@testable import _ResilienceCore

final class TimeoutPolicyContractTests: XCTestCase {
    func testSequentialGraceRecoveriesRecordOnlyTheirOwnOutcome() async throws {
        let metrics = TimeoutPolicyMetrics()
        let middleware = TimeoutMiddleware(configuration: .init(
            defaultTimeout: 60, gracePeriod: 60, metricsCollector: metrics
        ))

        for iteration in 0..<3 {
            let fast = try await middleware.execute(
                TimeoutPolicyCommand(timeout: 60), context: CommandContext()
            ) { _, _ in "fast" }
            XCTAssertEqual(fast, "fast")

            let probe = TimeoutPolicyInvocation()
            let events = TimeoutPolicyEvents()
            let task = startInvocation(middleware, probe: probe, events: events)
            let enteredGrace = await eventually { await events.graceCount == 1 }
            XCTAssertTrue(enteredGrace)
            await probe.settlement.release()
            if !enteredGrace { task.cancel() }
            let result = try await task.value
            XCTAssertEqual(result, "settled")

            let snapshot = await metrics.snapshot()
            XCTAssertEqual(snapshot.recoveries, Double(iteration + 1))
            XCTAssertEqual(snapshot.graceDurations.count, iteration + 1)
            XCTAssertEqual(snapshot.nearTimeouts, 0, "Grace recovery is distinct from near-timeout success")
            XCTAssertEqual(snapshot.timeouts, 0)
        }
    }

    func testConcurrentGraceRecoveriesRemainIndependentWhenSettledInReverseOrder() async throws {
        let metrics = TimeoutPolicyMetrics()
        let middleware = TimeoutMiddleware(configuration: .init(
            defaultTimeout: 60, gracePeriod: 60, metricsCollector: metrics
        ))
        let firstProbe = TimeoutPolicyInvocation()
        let firstEvents = TimeoutPolicyEvents()
        let first = startInvocation(middleware, probe: firstProbe, events: firstEvents)
        let firstGrace = await eventually { await firstEvents.graceCount == 1 }
        XCTAssertTrue(firstGrace)

        let secondProbe = TimeoutPolicyInvocation()
        let secondEvents = TimeoutPolicyEvents()
        let second = startInvocation(middleware, probe: secondProbe, events: secondEvents)
        let secondGrace = await eventually { await secondEvents.graceCount == 1 }
        XCTAssertTrue(secondGrace)

        let fastResult: Result<String, any Error>
        do {
            fastResult = .success(try await middleware.execute(
                TimeoutPolicyCommand(timeout: 60), context: CommandContext()
            ) { _, _ in "fast while both invocations are in grace" })
        } catch {
            fastResult = .failure(error)
        }
        let beforeSettlement = await metrics.snapshot()
        XCTAssertEqual(beforeSettlement.recoveries, 0)

        await secondProbe.settlement.release()
        if !secondGrace { second.cancel() }
        let secondResult = await second.result
        let afterSecond = await metrics.snapshot()
        XCTAssertEqual(afterSecond.recoveries, 1)
        XCTAssertEqual(afterSecond.graceDurations.count, 1)
        XCTAssertFalse(firstProbe.completed)

        await firstProbe.settlement.release()
        if !firstGrace { first.cancel() }
        let firstResult = await first.result
        XCTAssertEqual(try fastResult.get(), "fast while both invocations are in grace")
        XCTAssertEqual(try secondResult.get(), "settled")
        XCTAssertEqual(try firstResult.get(), "settled")

        let final = await metrics.snapshot()
        XCTAssertEqual(final.recoveries, 2)
        XCTAssertEqual(final.graceDurations.count, 2)
        XCTAssertEqual(final.nearTimeouts, 0)
        XCTAssertEqual(final.timeouts, 0)
    }

    func testSuspendedGraceEventDoesNotDelayCancellationAndRemainsOwned() async {
        let callbackSettlement = TimeoutPolicyLatch()
        let events = TimeoutPolicyEvents(callbackSettlement: callbackSettlement)
        let probe = TimeoutPolicyInvocation()
        let metrics = TimeoutPolicyMetrics()
        let middleware = TimeoutMiddleware(configuration: .init(
            defaultTimeout: 0.001, gracePeriod: 0.001, metricsCollector: metrics
        ))
        let task = startInvocation(middleware, probe: probe, events: events)

        let callbackEntered = await eventually { await events.graceCount == 1 }
        XCTAssertTrue(callbackEntered)
        let cancelledWhileCallbackSuspended = await eventually { probe.cancelled }
        XCTAssertTrue(cancelledWhileCallbackSuspended,
                      "Grace expiry must request cancellation while the diagnostic callback is suspended")
        XCTAssertFalse(probe.completed)

        if cancelledWhileCallbackSuspended {
            await probe.settlement.release()
            let handlerSettled = await eventually { probe.settled }
            XCTAssertTrue(handlerSettled)
            XCTAssertFalse(probe.completed, "Execution still owns the suspended diagnostic callback")
        }

        await callbackSettlement.release()
        let cancellationObserved = await eventually { probe.cancelled }
        XCTAssertTrue(cancellationObserved)
        await probe.settlement.release()
        if !cancellationObserved { task.cancel() }
        let result = await task.result
        assertTimeout(result)
        let snapshot = await metrics.snapshot()
        XCTAssertEqual(snapshot.timeouts, 1)
        XCTAssertEqual(snapshot.recoveries, 0)
    }

    func testTimeoutRetainsHandlerUntilSettlementForEveryFinalHandlerOutcome() async {
        for grace in [0.0, 0.001] {
            for outcome in TimeoutPolicyHandlerOutcome.allCases {
                let metrics = TimeoutPolicyMetrics()
                let callbacks = TimeoutPolicyCallbacks()
                let middleware = TimeoutMiddleware(configuration: .init(
                    defaultTimeout: 0.001,
                    gracePeriod: grace,
                    timeoutHandler: { _, context in await callbacks.record(context) },
                    metricsCollector: metrics
                ))
                let probe = TimeoutPolicyInvocation()
                let events = TimeoutPolicyEvents()
                let context = CommandContext()
                let task = startInvocation(
                    middleware, probe: probe, events: events, outcome: outcome, context: context
                )
                let cancellationObserved = await eventually { probe.cancelled }
                XCTAssertTrue(cancellationObserved, "grace=\(grace), outcome=\(outcome)")
                XCTAssertFalse(probe.completed)
                let beforeSettlement = await callbacks.contexts
                XCTAssertTrue(beforeSettlement.isEmpty)

                await probe.settlement.release()
                if !cancellationObserved { task.cancel() }
                assertTimeout(await task.result, duration: 0.001)
                XCTAssertTrue(probe.settled)
                let contexts = await callbacks.contexts
                XCTAssertEqual(contexts.count, 1)
                XCTAssertEqual(contexts.first?.gracePeriodUsed, grace > 0)
                XCTAssertEqual(contexts.first?.reason, grace > 0 ? .gracePeriodExpired : .executionTimeout)
                if let timeoutContext = contexts.first {
                    XCTAssertEqual(timeoutContext.timeoutDuration, 0.001, accuracy: 0.000001)
                    XCTAssertEqual(timeoutContext.gracePeriod, grace, accuracy: 0.000001)
                }
                if case .timeout(let duration, let configuredGrace)? = context.getCancellationReason() {
                    XCTAssertEqual(duration, 0.001, accuracy: 0.000001)
                    XCTAssertEqual(configuredGrace ?? -1, grace, accuracy: 0.000001)
                } else {
                    XCTFail("The outer deadline must record its own cancellation reason")
                }
                let timeoutEvents = await events.timeoutCount
                XCTAssertEqual(timeoutEvents, 1)
                let snapshot = await metrics.snapshot()
                XCTAssertEqual(snapshot.timeouts, 1)
                XCTAssertEqual(snapshot.timeoutDurations.count, 1)
                XCTAssertEqual(snapshot.recoveries, 0)
            }
        }
    }

    func testCancelledTimerPreservesSettledHandlerOutcomeInInitialAndGracePhases() async {
        for duringGrace in [false, true] {
            for outcome in TimeoutPolicyHandlerOutcome.nonTimeoutCases {
                let probe = TimeoutPolicyInvocation()
                let timer = TimeoutPolicyCancelledTimer(cancellationCall: duringGrace ? 2 : 1)
                let task = Task {
                    defer { probe.markCompleted() }
                    let result = try await withTimeoutAndGrace(
                        timeout: 60,
                        gracePeriod: 30,
                        operation: { try await probe.run(outcome: outcome) },
                        sleep: { try await timer.sleep($0) }
                    )
                    return result.value
                }

                let entered = await eventually { probe.entered }
                XCTAssertTrue(entered)
                let timerCancelled = await eventually { timer.cancelled }
                XCTAssertTrue(timerCancelled)
                if duringGrace {
                    // Only the consumed cancelled-timer result cancels this
                    // operation: the invocation task itself is not cancelled.
                    let cancellationConsumed = await eventually { probe.cancelled }
                    XCTAssertTrue(cancellationConsumed)
                }
                XCTAssertFalse(probe.completed)
                await probe.settlement.release()
                if !entered || !timerCancelled { task.cancel() }
                assertOutcome(await task.result, matches: outcome)
            }
        }
    }

    func testGraceNotificationIsCancelledAndJoinedWhenHandlerSettles() async {
        for outcome in TimeoutPolicyHandlerOutcome.nonTimeoutCases {
            let notificationSleep = ManualAdmissionClock()
            let events = TimeoutPolicyEvents(cancellationSleeper: notificationSleep)
            let probe = TimeoutPolicyInvocation()
            let middleware = TimeoutMiddleware(configuration: .init(defaultTimeout: 60, gracePeriod: 60))
            let task = startInvocation(middleware, probe: probe, events: events, outcome: outcome)

            let notificationSuspended = await eventually { notificationSleep.sleepingCount == 1 }
            XCTAssertTrue(notificationSuspended)
            await probe.settlement.release()
            let completed = await eventually { probe.completed }
            XCTAssertTrue(completed, "A settled handler must cancel its outstanding grace notification")
            if !completed {
                task.cancel()
                notificationSleep.advance(by: .seconds(60))
            }
            assertOutcome(await task.result, matches: outcome)
            let notificationCancelled = await events.notificationCancelled
            XCTAssertTrue(notificationCancelled)
            XCTAssertEqual(notificationSleep.sleepingCount, 0)
            XCTAssertEqual(notificationSleep.completedCount, notificationSleep.callCount)
        }
    }

    func testHandlerOutcomesRemainTypedBeforeAndDuringGraceWithCallerCancellation() async {
        for duringGrace in [false, true] {
            for callerCancels in [false, true] {
                for outcome in TimeoutPolicyHandlerOutcome.allCases {
                    let metrics = TimeoutPolicyMetrics()
                    let callbacks = TimeoutPolicyCallbacks()
                    let middleware = TimeoutMiddleware(configuration: .init(
                        defaultTimeout: 60,
                        gracePeriod: 60,
                        timeoutHandler: { _, context in await callbacks.record(context) },
                        metricsCollector: metrics
                    ))
                    let probe = TimeoutPolicyInvocation()
                    let events = TimeoutPolicyEvents()
                    let context = CommandContext()
                    let task = startInvocation(
                        middleware,
                        probe: probe,
                        events: events,
                        outcome: outcome,
                        timeout: duringGrace ? 0.001 : 60,
                        context: context
                    )
                    let entered = await eventually { probe.entered }
                    XCTAssertTrue(entered)
                    if duringGrace {
                        let graceEntered = await eventually { await events.graceCount == 1 }
                        XCTAssertTrue(graceEntered)
                    }
                    if callerCancels {
                        task.cancel()
                        let cancellationObserved = await eventually { probe.cancelled }
                        XCTAssertTrue(cancellationObserved)
                    }
                    XCTAssertFalse(probe.completed)
                    await probe.settlement.release()
                    assertOutcome(await task.result, matches: outcome)

                    let contexts = await callbacks.contexts
                    XCTAssertTrue(contexts.isEmpty, "Handler outcomes do not invoke timeout policy callbacks")
                    XCTAssertNil(context.getCancellationReason(), "Handler outcomes must not record an outer timeout reason")
                    let timeoutEvents = await events.timeoutCount
                    XCTAssertEqual(timeoutEvents, 0)
                    let snapshot = await metrics.snapshot()
                    XCTAssertEqual(snapshot.timeouts, 0)
                    XCTAssertTrue(snapshot.timeoutDurations.isEmpty)
                    XCTAssertEqual(snapshot.nearTimeouts, 0)
                    XCTAssertEqual(snapshot.recoveries, duringGrace && outcome == .success ? 1 : 0)
                    XCTAssertEqual(snapshot.graceDurations.count, duringGrace && outcome == .success ? 1 : 0)
                }
            }
        }
    }

    private func startInvocation(
        _ middleware: TimeoutMiddleware,
        probe: TimeoutPolicyInvocation,
        events: TimeoutPolicyEvents,
        outcome: TimeoutPolicyHandlerOutcome = .success,
        timeout: TimeInterval = 0.001,
        context: CommandContext = CommandContext()
    ) -> Task<String, any Error> {
        context.eventEmitter = events
        return Task {
            defer { probe.markCompleted() }
            return try await middleware.execute(TimeoutPolicyCommand(timeout: timeout), context: context) { _, _ in
                try await probe.run(outcome: outcome)
            }
        }
    }

    private func assertOutcome(
        _ result: Result<String, any Error>,
        matches outcome: TimeoutPolicyHandlerOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (outcome, result) {
        case (.success, .success(let value)):
            XCTAssertEqual(value, "settled", file: file, line: line)
        case (.foreignError, .failure(let error)):
            XCTAssertEqual(error as? TimeoutPolicyFailure, .expected, file: file, line: line)
        case (.nativeCancellation, .failure(let error)):
            XCTAssertTrue(error is CancellationError, "Expected native cancellation, got \(error)", file: file, line: line)
        case (.typedCancellation, .failure(let error)):
            guard case PipelineError.cancelled(let context) = error else {
                return XCTFail("Expected typed handler cancellation, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(context, "handler cancellation", file: file, line: line)
        case (.timeoutExceeded, .failure(let error)):
            guard case TimeoutError.exceeded(let duration) = error else {
                return XCTFail("Expected the handler's TimeoutError.exceeded, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(duration, -17.25, accuracy: 0.000001, file: file, line: line)
        case (.timeoutGraceExpired, .failure(let error)):
            guard case let TimeoutError.gracePeriodExpired(timeout, grace, total) = error else {
                return XCTFail("Expected the handler's TimeoutError.gracePeriodExpired, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(timeout, 23.5, accuracy: 0.000001, file: file, line: line)
            XCTAssertEqual(grace, 4.25, accuracy: 0.000001, file: file, line: line)
            XCTAssertEqual(total, 29.75, accuracy: 0.000001, file: file, line: line)
        case (.timeoutNoResult, .failure(let error)):
            guard case TimeoutError.noResult = error else {
                return XCTFail("Expected the handler's TimeoutError.noResult, got \(error)", file: file, line: line)
            }
        default:
            XCTFail("Expected handler outcome \(outcome), got \(result)", file: file, line: line)
        }
    }

    private func assertTimeout(
        _ result: Result<String, any Error>,
        duration expectedDuration: TimeInterval? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success: XCTFail("Expected timeout", file: file, line: line)
        case .failure(let error):
            guard case PipelineError.timeout(let duration, _) = error else {
                return XCTFail("Expected typed timeout, got \(error)", file: file, line: line)
            }
            if let expectedDuration {
                XCTAssertEqual(duration, expectedDuration, accuracy: 0.000001, file: file, line: line)
            }
        }
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }
}

private struct TimeoutPolicyCommand: Command, TimeoutConfigurable {
    typealias Result = String
    let timeout: TimeInterval
}

private enum TimeoutPolicyFailure: Error, Equatable { case expected }

private enum TimeoutPolicyHandlerOutcome: CaseIterable, Sendable {
    case success, foreignError, nativeCancellation, typedCancellation
    case timeoutExceeded, timeoutGraceExpired, timeoutNoResult

    static let nonTimeoutCases: [Self] = [.success, .foreignError, .nativeCancellation, .typedCancellation]
}

private actor TimeoutPolicyLatch {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class TimeoutPolicyInvocation: Sendable {
    private struct State {
        var entered = false
        var cancelled = false
        var settled = false
        var completed = false
    }
    private let state = Mutex(State())
    let settlement = TimeoutPolicyLatch()

    var entered: Bool { state.withLock { $0.entered } }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    var settled: Bool { state.withLock { $0.settled } }
    var completed: Bool { state.withLock { $0.completed } }
    func markEntered() { state.withLock { $0.entered = true } }
    func markCancelled() { state.withLock { $0.cancelled = true } }
    func markSettled() { state.withLock { $0.settled = true } }
    func markCompleted() { state.withLock { $0.completed = true } }

    func run(outcome: TimeoutPolicyHandlerOutcome) async throws -> String {
        try await withTaskCancellationHandler {
            markEntered()
            await settlement.wait()
            defer { markSettled() }
            switch outcome {
            case .success: return "settled"
            case .foreignError: throw TimeoutPolicyFailure.expected
            case .nativeCancellation: throw CancellationError()
            case .typedCancellation: throw PipelineError.cancelled(context: "handler cancellation")
            case .timeoutExceeded:
                return try await withTimeout(-17.25) { "inner operation must not start" }
            case .timeoutGraceExpired:
                throw TimeoutError.gracePeriodExpired(timeout: 23.5, gracePeriod: 4.25, totalDuration: 29.75)
            case .timeoutNoResult:
                throw TimeoutError.noResult
            }
        } onCancel: {
            self.markCancelled()
        }
    }
}

private final class TimeoutPolicyCancelledTimer: Sendable {
    private struct State {
        var calls = 0
        var cancelled = false
    }
    private let state = Mutex(State())
    private let cancellationCall: Int

    init(cancellationCall: Int) { self.cancellationCall = cancellationCall }
    var cancelled: Bool { state.withLock { $0.cancelled } }

    func sleep(_ duration: TimeInterval) async throws {
        let call = state.withLock { $0.calls += 1; return $0.calls }
        if call < cancellationCall { return }
        withUnsafeCurrentTask { $0?.cancel() }
        state.withLock { $0.cancelled = true }
        try Task.checkCancellation()
    }
}

private actor TimeoutPolicyEvents: EventEmitter {
    private(set) var graceCount = 0
    private(set) var timeoutCount = 0
    private(set) var notificationCancelled = false
    private let callbackSettlement: TimeoutPolicyLatch?
    private let cancellationSleeper: ManualAdmissionClock?

    init(
        callbackSettlement: TimeoutPolicyLatch? = nil,
        cancellationSleeper: ManualAdmissionClock? = nil
    ) {
        self.callbackSettlement = callbackSettlement
        self.cancellationSleeper = cancellationSleeper
    }

    func emit(_ event: PipelineEvent) async {
        if event.name == PipelineEvent.Name.middlewareTimeout {
            timeoutCount += 1
        }
        if event.name == "middleware.timeout_grace_period" {
            graceCount += 1
            await callbackSettlement?.wait()
            if let cancellationSleeper {
                try? await cancellationSleeper.sleep(for: .seconds(60))
                notificationCancelled = Task.isCancelled
            }
        }
    }
}

private actor TimeoutPolicyCallbacks {
    private(set) var contexts: [TimeoutContext] = []
    func record(_ context: TimeoutContext) { contexts.append(context) }
}

private actor TimeoutPolicyMetrics: MetricsCollector {
    struct Snapshot: Sendable {
        var recoveries: Double = 0
        var nearTimeouts: Double = 0
        var timeouts: Double = 0
        var graceDurations: [TimeInterval] = []
        var timeoutDurations: [TimeInterval] = []
    }
    private var values = Snapshot()

    func recordCounter(_ name: String, value: Double, tags: [String: String]) {
        switch name {
        case "pipeline.timeout.grace_recovery": values.recoveries += value
        case "pipeline.timeout.near_timeout": values.nearTimeouts += value
        case "pipeline.timeout.exceeded": values.timeouts += value
        default: break
        }
    }

    func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) {
        if name == "pipeline.timeout.grace_duration" { values.graceDurations.append(duration) }
        if name == "pipeline.timeout.duration" { values.timeoutDurations.append(duration) }
    }

    func recordGauge(_ name: String, value: Double, tags: [String: String]) {}
    func recordHistogram(_ name: String, value: Double, tags: [String: String]) {}
    func snapshot() -> Snapshot { values }
}
