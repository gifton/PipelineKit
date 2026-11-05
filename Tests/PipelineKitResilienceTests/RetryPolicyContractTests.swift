import Foundation
import Synchronization
import XCTest
import PipelineKitCore
import PipelineKitResilience

private struct RetryPolicyCommand: Command { typealias Result = Int }

private final class RetryPolicyFailure: Error, Sendable {}

private final class RetryPolicyCounter: Sendable {
    private let value = Mutex(0)

    @discardableResult
    func increment() -> Int {
        value.withLock { $0 += 1; return $0 }
    }

    var count: Int { value.withLock { $0 } }
}

private final class RetryPolicyClock: Sendable {
    private struct State {
        var instant: Duration = .zero
        var sleeps: [Duration] = []
    }

    private let state = Mutex(State())

    func now() -> Duration { state.withLock { $0.instant } }

    func advance(by duration: Duration) {
        precondition(duration >= .zero)
        state.withLock { $0.instant += duration }
    }

    func recordSleep(_ duration: Duration) {
        state.withLock {
            $0.sleeps.append(duration)
            $0.instant += duration
        }
    }

    var sleeps: [Duration] { state.withLock { $0.sleeps } }
}

private final class ControlledRetryEmitter: EventEmitter, Sendable {
    private let events = Mutex<[String]>([])
    private let onEvent: @Sendable (String) -> Void

    init(onEvent: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onEvent = onEvent
    }

    func emit(_ event: PipelineEvent) async {
        events.withLock { $0.append(event.name) }
        onEvent(event.name)
    }

    func count(_ name: String) -> Int {
        events.withLock { $0.filter { $0 == name }.count }
    }
}

private actor RetryPolicyGate {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

private final class ConsumerHTTPFailure: Error, Sendable {
    let status: Int?
    init(status: Int?) { self.status = status }
}

private final class BudgetConsumingRetryEmitter: EventEmitter, Sendable {
    let target: String
    let budget: Duration
    private let emitted = Mutex<[String]>([])

    init(target: String, budget: Duration) {
        self.target = target
        self.budget = budget
    }

    func emit(_ event: PipelineEvent) async {
        emitted.withLock { $0.append(event.name) }
        if event.name == target {
            // Consume the tested budget during this public callback. The sleep
            // models elapsed callback work; it does not order concurrent tasks.
            try? await ContinuousClock().sleep(for: budget)
        }
    }

    func count(_ event: String) -> Int {
        emitted.withLock { $0.filter { $0 == event }.count }
    }
}

final class RetryPolicyContractTests: XCTestCase {
    private var smallBudgetCases: [(budget: TimeInterval, threshold: Int128)] {
        [
            (Double.leastNonzeroMagnitude, 1),
            (Double.leastNormalMagnitude.nextDown, 1),
            (Double.leastNormalMagnitude, 1),
            (2.5e-19, 1),
            ((1e-18).nextDown, 1),
            (1e-18, 2),
            (1.25e-18, 2),
            (1.5e-18, 2),
            (2e-18, 3),
            (2.25e-18, 3)
        ]
    }

    private func observeSettlement(
        _ middleware: RetryMiddleware,
        context: CommandContext = CommandContext(),
        next: @escaping MiddlewareNext<RetryPolicyCommand>
    ) async -> Result<Int, any Error> {
        let completed = expectation(description: "retry settles within its budget observation window")
        let execution = Task { () -> Result<Int, any Error> in
            defer { completed.fulfill() }
            do {
                return .success(try await middleware.execute(RetryPolicyCommand(), context: context, next: next))
            } catch {
                return .failure(error)
            }
        }
        await fulfillment(of: [completed], timeout: 1)
        execution.cancel()
        return await execution.value
    }

    private func assertOriginalFailure(
        _ result: Result<Int, any Error>,
        _ failure: RetryPolicyFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let value):
            XCTFail("Expected original failure, got success \(value)", file: file, line: line)
        case .failure(let error):
            XCTAssertTrue((error as? RetryPolicyFailure) === failure,
                          "Budget exhaustion must preserve the original failure: \(error)",
                          file: file,
                          line: line)
        }
    }

    func testOverallBudgetBoundsLongBackoff() async {
        let failure = RetryPolicyFailure()
        let calls = RetryPolicyCounter()
        let middleware = RetryMiddleware(configuration: .init(
            maxAttempts: 2,
            strategy: .fixed(delay: 30),
            errorEvaluator: { _ in true },
            emitEvents: false,
            maxRetryTime: 0.05
        ))

        let result = await observeSettlement(middleware) { _, _ in
            calls.increment()
            throw failure
        }

        assertOriginalFailure(result, failure)
        XCTAssertEqual(calls.count, 1)
    }

    func testBudgetExpirationDuringDelayEventPreventsBackoff() async {
        let failure = RetryPolicyFailure()
        let calls = RetryPolicyCounter()
        let emitter = BudgetConsumingRetryEmitter(target: PipelineEvent.Name.middlewareRetryDelay, budget: .milliseconds(100))
        let context = CommandContext()
        context.eventEmitter = emitter
        let middleware = RetryMiddleware(configuration: .init(
            maxAttempts: 2,
            strategy: .fixed(delay: 30),
            errorEvaluator: { _ in true },
            maxRetryTime: 0.05
        ))

        let result = await observeSettlement(middleware, context: context) { _, _ in
            calls.increment()
            throw failure
        }

        assertOriginalFailure(result, failure)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(emitter.count(PipelineEvent.Name.middlewareRetryDelay), 1)
        XCTAssertEqual(emitter.count(PipelineEvent.Name.middlewareRetry), 0)
    }

    func testBudgetExpirationDuringAttemptEventPreventsRetryAdmission() async {
        let failure = RetryPolicyFailure()
        let calls = RetryPolicyCounter()
        let emitter = BudgetConsumingRetryEmitter(target: PipelineEvent.Name.middlewareRetry, budget: .milliseconds(100))
        let context = CommandContext()
        context.eventEmitter = emitter
        let middleware = RetryMiddleware(configuration: .init(
            maxAttempts: 2,
            strategy: .fixed(delay: 0),
            errorEvaluator: { _ in true },
            maxRetryTime: 0.05
        ))

        let result = await observeSettlement(middleware, context: context) { _, _ in
            let attempt = calls.increment()
            if attempt == 1 { throw failure }
            return 7
        }

        assertOriginalFailure(result, failure)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(emitter.count(PipelineEvent.Name.middlewareRetry), 1)
    }

    func testAdmittedFailureAfterBudgetDoesNotStartBackoff() async {
        let failure = RetryPolicyFailure()
        let calls = RetryPolicyCounter()
        let evaluations = RetryPolicyCounter()
        let middleware = RetryMiddleware(configuration: .init(
            maxAttempts: 2,
            strategy: .fixed(delay: 30),
            errorEvaluator: { _ in evaluations.increment(); return true },
            emitEvents: false,
            maxRetryTime: 0.05
        ))

        let result = await observeSettlement(middleware) { _, _ in
            calls.increment()
            try await ContinuousClock().sleep(for: .milliseconds(100))
            throw failure
        }

        assertOriginalFailure(result, failure)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(evaluations.count, 0)
    }

    func testAdmittedSuccessAfterBudgetIsReturned() async {
        let calls = RetryPolicyCounter()
        let middleware = RetryMiddleware(configuration: .init(
            strategy: .fixed(delay: 0),
            emitEvents: false,
            maxRetryTime: 0.05
        ))

        let result = await observeSettlement(middleware) { _, _ in
            calls.increment()
            try await ContinuousClock().sleep(for: .milliseconds(100))
            return 7
        }

        switch result {
        case .success(let value): XCTAssertEqual(value, 7)
        case .failure(let error): XCTFail("Admitted success must settle: \(error)")
        }
        XCTAssertEqual(calls.count, 1)
    }

    func testZeroBudgetDoesNotAdmitInitialAttempt() async {
        let calls = RetryPolicyCounter()
        let middleware = RetryMiddleware(configuration: .init(emitEvents: false, maxRetryTime: 0))
        let result = await observeSettlement(middleware) { _, _ in
            calls.increment()
            return 7
        }

        switch result {
        case .failure(let error):
            guard case RetryError.maxRetryTimeExceeded = error else {
                XCTFail("Expected budget exhaustion before initial admission: \(error)")
                return
            }
        case .success(let value): XCTFail("Expected budget exhaustion before initial admission, got \(value)")
        }
        XCTAssertEqual(calls.count, 0)
    }

    func testNilBudgetPreservesMaximumRetryCountAndLastError() async {
        let calls = RetryPolicyCounter()
        let first = RetryPolicyFailure()
        let last = RetryPolicyFailure()
        let middleware = RetryMiddleware(configuration: .init(
            maxAttempts: 2,
            strategy: .fixed(delay: 0),
            errorEvaluator: { _ in true },
            emitEvents: false,
            maxRetryTime: nil
        ))

        let result = await observeSettlement(middleware) { _, _ in
            let attempt = calls.increment()
            throw attempt == 3 ? last : first
        }

        assertOriginalFailure(result, last)
        XCTAssertEqual(calls.count, 3)
    }

    func testExactBudgetBoundaryPreventsAnotherAttempt() async {
        let cases: [(Duration, Int)] = [
            (.seconds(5) - .nanoseconds(1), 2),
            (.seconds(5), 1),
            (.seconds(5) + .nanoseconds(1), 1)
        ]
        for (elapsed, expectedCalls) in cases {
            let clock = RetryPolicyClock()
            let calls = RetryPolicyCounter()
            let evaluations = RetryPolicyCounter()
            let failure = RetryPolicyFailure()
            let middleware = RetryMiddleware(
                configuration: .init(
                    maxAttempts: 2,
                    strategy: .fixed(delay: 0),
                    errorEvaluator: { _ in evaluations.increment(); return true },
                    emitEvents: false,
                    maxRetryTime: 5
                ),
                now: { clock.now() },
                sleep: { clock.recordSleep($0) }
            )

            let result = await observeSettlement(middleware) { _, _ in
                if calls.increment() == 1 {
                    clock.advance(by: elapsed)
                    throw failure
                }
                return 7
            }

            if expectedCalls == 2 {
                XCTAssertEqual(try? result.get(), 7)
                XCTAssertEqual(evaluations.count, 1)
            } else {
                assertOriginalFailure(result, failure)
                XCTAssertEqual(evaluations.count, 0)
                XCTAssertTrue(clock.sleeps.isEmpty)
            }
            XCTAssertEqual(calls.count, expectedCalls, "elapsed=\(elapsed)")
        }
    }

    func testBackoffIsClampedAtExactRemainingBudget() async {
        let cases: [(TimeInterval, Duration, Int)] = [
            (1, .seconds(1), 2),
            (5, .seconds(5), 1),
            (8, .seconds(5), 1)
        ]
        for (delay, expectedSleep, expectedCalls) in cases {
            let clock = RetryPolicyClock()
            let calls = RetryPolicyCounter()
            let failure = RetryPolicyFailure()
            let middleware = RetryMiddleware(
                configuration: .init(
                    maxAttempts: 2,
                    strategy: .fixed(delay: delay),
                    errorEvaluator: { _ in true },
                    emitEvents: false,
                    maxRetryTime: 5
                ),
                now: { clock.now() },
                sleep: { clock.recordSleep($0) }
            )

            let result = await observeSettlement(middleware) { _, _ in
                if calls.increment() == 1 { throw failure }
                return 7
            }

            XCTAssertEqual(clock.sleeps, [expectedSleep], "delay=\(delay)")
            XCTAssertEqual(calls.count, expectedCalls)
            if expectedCalls == 1 { assertOriginalFailure(result, failure) } else { XCTAssertEqual(try? result.get(), 7) }
        }
    }

    func testEveryBackoffStrategyHonorsTheSameBudget() async {
        let strategies: [RetryMiddleware.BackoffStrategy] = [
            .fixed(delay: 30), .linear(baseDelay: 30, maxDelay: 60),
            .exponential(baseDelay: 30, maxDelay: 60),
            .exponentialJitter(baseDelay: 30, maxDelay: 60), .custom { _ in 30 }
        ]
        for strategy in strategies {
            let clock = RetryPolicyClock()
            let calls = RetryPolicyCounter()
            let failure = RetryPolicyFailure()
            let middleware = RetryMiddleware(
                configuration: .init(
                    maxAttempts: 2,
                    strategy: strategy,
                    errorEvaluator: { _ in true },
                    emitEvents: false,
                    maxRetryTime: 5
                ),
                now: { clock.now() },
                sleep: { clock.recordSleep($0) }
            )

            let result = await observeSettlement(middleware) { _, _ in
                calls.increment()
                throw failure
            }

            assertOriginalFailure(result, failure)
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(clock.sleeps, [.seconds(5)])
        }
    }

    func testExpiryDuringEachCallbackStopsFurtherRetryWork() async {
        let cases: [(phase: String, backoffs: Int, delayEvents: Int, attemptEvents: Int, sleeps: Int)] = [
            ("evaluator", 0, 0, 0, 0), ("backoff", 1, 0, 0, 0),
            ("delayEvent", 1, 1, 0, 0), ("attemptEvent", 1, 1, 1, 1),
            ("sleep", 1, 1, 0, 1)
        ]
        for entry in cases {
            let clock = RetryPolicyClock()
            let calls = RetryPolicyCounter()
            let evaluations = RetryPolicyCounter()
            let backoffs = RetryPolicyCounter()
            let failure = RetryPolicyFailure()
            let emitter = ControlledRetryEmitter { name in
                if (entry.phase == "delayEvent" && name == PipelineEvent.Name.middlewareRetryDelay)
                    || (entry.phase == "attemptEvent" && name == PipelineEvent.Name.middlewareRetry) {
                    clock.advance(by: .seconds(5))
                }
            }
            let context = CommandContext()
            context.eventEmitter = emitter
            let middleware = RetryMiddleware(
                configuration: .init(
                    maxAttempts: 2,
                    strategy: .custom { _ in
                        backoffs.increment()
                        if entry.phase == "backoff" { clock.advance(by: .seconds(5)) }
                        return entry.phase == "sleep" ? 1 : 0
                    },
                    errorEvaluator: { _ in
                        evaluations.increment()
                        if entry.phase == "evaluator" { clock.advance(by: .seconds(5)) }
                        return true
                    },
                    maxRetryTime: 5
                ),
                now: { clock.now() },
                sleep: {
                    clock.recordSleep($0)
                    if entry.phase == "sleep" { clock.advance(by: .seconds(5)) }
                }
            )

            let result = await observeSettlement(middleware, context: context) { _, _ in
                if calls.increment() == 1 { throw failure }
                return 7
            }

            assertOriginalFailure(result, failure)
            XCTAssertEqual(calls.count, 1, entry.phase)
            XCTAssertEqual(evaluations.count, 1, entry.phase)
            XCTAssertEqual(backoffs.count, entry.backoffs, entry.phase)
            XCTAssertEqual(emitter.count(PipelineEvent.Name.middlewareRetryDelay), entry.delayEvents, entry.phase)
            XCTAssertEqual(emitter.count(PipelineEvent.Name.middlewareRetry), entry.attemptEvents, entry.phase)
            XCTAssertEqual(clock.sleeps.count, entry.sleeps, entry.phase)
            XCTAssertEqual(emitter.count("middleware.retry_max_time_exceeded"), 1, entry.phase)
        }
    }

    func testBudgetExhaustionPreservesMostRecentFailure() async {
        let clock = RetryPolicyClock()
        let calls = RetryPolicyCounter()
        let first = RetryPolicyFailure()
        let last = RetryPolicyFailure()
        let middleware = RetryMiddleware(
            configuration: .init(
                maxAttempts: 3,
                strategy: .fixed(delay: 2),
                errorEvaluator: { _ in true },
                emitEvents: false,
                maxRetryTime: 3
            ),
            now: { clock.now() },
            sleep: { clock.recordSleep($0) }
        )

        let result = await observeSettlement(middleware) { _, _ in
            throw calls.increment() == 1 ? first : last
        }

        assertOriginalFailure(result, last)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(clock.sleeps, [.seconds(2), .seconds(1)])
    }

    func testBudgetExpirationWaitsForAdmittedWorkToSettle() async {
        for fails in [false, true] {
            let clock = RetryPolicyClock()
            let gate = RetryPolicyGate()
            let terminalCount = RetryPolicyCounter()
            let evaluations = RetryPolicyCounter()
            let failure = RetryPolicyFailure()
            let entered = expectation(description: "handler admitted")
            let completed = expectation(description: "admitted handler settled")
            let middleware = RetryMiddleware(
                configuration: .init(
                    maxAttempts: 2,
                    strategy: .fixed(delay: 30),
                    errorEvaluator: { _ in evaluations.increment(); return true },
                    emitEvents: false,
                    maxRetryTime: 5
                ),
                now: { clock.now() },
                sleep: { clock.recordSleep($0) }
            )
            let execution = Task { () -> Result<Int, any Error> in
                defer { terminalCount.increment(); completed.fulfill() }
                do {
                    return .success(try await middleware.execute(RetryPolicyCommand(), context: CommandContext()) { _, _ in
                        entered.fulfill()
                        await gate.wait()
                        if fails { throw failure }
                        return 7
                    })
                } catch { return .failure(error) }
            }

            await fulfillment(of: [entered], timeout: 1)
            clock.advance(by: .seconds(6))
            XCTAssertEqual(terminalCount.count, 0)
            await gate.release()
            await fulfillment(of: [completed], timeout: 1)
            execution.cancel()
            let result = await execution.value

            if fails { assertOriginalFailure(result, failure) } else { XCTAssertEqual(try? result.get(), 7) }
            XCTAssertEqual(terminalCount.count, 1)
            XCTAssertEqual(evaluations.count, 0)
            XCTAssertTrue(clock.sleeps.isEmpty)
        }
    }

    func testUpperRangeBudgetsAndBackoffsRemainRepresentable() async {
        let delays: [(TimeInterval, Int64)] = [
            (10_000_000_000, 10_000_000_000),
            (NumericDuration.maximumSeconds, 18_446_744_073)
        ]
        let budgets: [TimeInterval?] = [nil, 30_000_000_000, Double.greatestFiniteMagnitude]
        for (delay, wholeSeconds) in delays {
            for budget in budgets {
                let clock = RetryPolicyClock()
                let calls = RetryPolicyCounter()
                let failure = RetryPolicyFailure()
                let middleware = RetryMiddleware(
                    configuration: .init(
                        maxAttempts: 1,
                        strategy: .fixed(delay: delay),
                        errorEvaluator: { _ in true },
                        emitEvents: false,
                        maxRetryTime: budget
                    ),
                    now: { clock.now() },
                    sleep: { clock.recordSleep($0) }
                )

                let result = await observeSettlement(middleware) { _, _ in
                    if calls.increment() == 1 { throw failure }
                    return 7
                }

                XCTAssertEqual(try? result.get(), 7)
                XCTAssertEqual(calls.count, 2)
                XCTAssertEqual(clock.sleeps.count, 1)
                XCTAssertEqual(clock.sleeps.first?.components.seconds, wholeSeconds)
            }
        }
    }

    func testLargeBudgetBoundaryPreservesNanosecondPrecision() async {
        let budgets: [(TimeInterval, Duration)] = [
            (33_554_432, .seconds(33_554_432)),
            (Double(Int64.max).nextDown, .seconds(Int64.max - 1023)),
            (9_223_372_036_854_775_808, .seconds(UInt64(1) << 63)),
            (170_141_183_460_469_211_136, .seconds(Int128(170_141_183_460_469_211_136)))
        ]
        let boundaries: [(Duration, Int)] = [(.nanoseconds(-1), 2), (.zero, 1), (.nanoseconds(1), 1)]
        for (budget, exactBudget) in budgets {
            for (offset, expectedCalls) in boundaries {
                let clock = RetryPolicyClock()
                let calls = RetryPolicyCounter()
                let evaluations = RetryPolicyCounter()
                let failure = RetryPolicyFailure()
                let middleware = RetryMiddleware(
                    configuration: .init(
                        maxAttempts: 1,
                        strategy: .fixed(delay: 0),
                        errorEvaluator: { _ in evaluations.increment(); return true },
                        emitEvents: false,
                        maxRetryTime: budget
                    ),
                    now: { clock.now() },
                    sleep: { clock.recordSleep($0) }
                )

                let result = await observeSettlement(middleware) { _, _ in
                    if calls.increment() == 1 {
                        clock.advance(by: exactBudget + offset)
                        throw failure
                    }
                    return 7
                }

                let label = "budget=\(budget), offset=\(offset)"
                XCTAssertEqual(calls.count, expectedCalls, label)
                if expectedCalls == 2 {
                    XCTAssertEqual(try? result.get(), 7, label)
                    XCTAssertEqual(evaluations.count, 1, label)
                    XCTAssertEqual(clock.sleeps, [.zero], label)
                } else {
                    assertOriginalFailure(result, failure)
                    XCTAssertEqual(evaluations.count, 0, label)
                    XCTAssertTrue(clock.sleeps.isEmpty, label)
                }
            }
        }
    }

    func testSmallPositiveBudgetsAdmitAtZeroElapsed() async {
        let cases = [(0.0, false)] + smallBudgetCases.map { ($0.budget, true) }
        for (budget, isPositive) in cases {
            let clock = RetryPolicyClock()
            let calls = RetryPolicyCounter()
            let middleware = RetryMiddleware(
                configuration: .init(
                    maxAttempts: 0,
                    strategy: .fixed(delay: 0),
                    emitEvents: false,
                    maxRetryTime: budget
                ),
                now: { clock.now() },
                sleep: { clock.recordSleep($0) }
            )

            let result = await observeSettlement(middleware) { _, _ in
                calls.increment()
                return 7
            }

            if !isPositive {
                XCTAssertEqual(calls.count, 0)
                switch result {
                case .failure(let error):
                    guard case RetryError.maxRetryTimeExceeded = error else {
                        XCTFail("Expected zero-budget rejection, got \(error)")
                        continue
                    }
                case .success: XCTFail("Zero budget must reject initial admission")
                }
            } else {
                XCTAssertEqual(try? result.get(), 7, "budget=\(budget)")
                XCTAssertEqual(calls.count, 1, "budget=\(budget)")
            }
            XCTAssertTrue(clock.sleeps.isEmpty)
        }
    }

    func testFractionalAttosecondBudgetsExpireAtCeilingThreshold() async {
        for (budget, threshold) in smallBudgetCases {
            for offset: Int128 in [-1, 0, 1] {
                let clock = RetryPolicyClock()
                let calls = RetryPolicyCounter()
                let evaluations = RetryPolicyCounter()
                let failure = RetryPolicyFailure()
                let elapsed = Duration(attoseconds: threshold + offset)
                let middleware = RetryMiddleware(
                    configuration: .init(
                        maxAttempts: 1,
                        strategy: .fixed(delay: 0),
                        errorEvaluator: { _ in evaluations.increment(); return true },
                        emitEvents: false,
                        maxRetryTime: budget
                    ),
                    now: { clock.now() },
                    sleep: { clock.recordSleep($0) }
                )

                let result = await observeSettlement(middleware) { _, _ in
                    if calls.increment() == 1 {
                        clock.advance(by: elapsed)
                        throw failure
                    }
                    return 7
                }

                let label = "budget=\(budget), elapsed attoseconds=\(threshold + offset)"
                if offset < 0 {
                    XCTAssertEqual(try? result.get(), 7, label)
                    XCTAssertEqual(calls.count, 2, label)
                    XCTAssertEqual(evaluations.count, 1, label)
                    XCTAssertEqual(clock.sleeps, [.zero], label)
                } else {
                    assertOriginalFailure(result, failure)
                    XCTAssertEqual(calls.count, 1, label)
                    XCTAssertEqual(evaluations.count, 0, label)
                    XCTAssertTrue(clock.sleeps.isEmpty, label)
                }
            }
        }
    }

    func testBudgetsAtAndAboveInt64SecondsRemainOpenBeforeExpiry() async {
        let budgets: [TimeInterval] = [
            Double(Int64.max), Double(Int64.max).nextUp, Double.greatestFiniteMagnitude
        ]
        let elapsedDurations: [Duration] = [
            .seconds(Int64.max) - .nanoseconds(1),
            .seconds(Int64.max),
            .seconds(Int64.max) + .nanoseconds(1)
        ]
        for budget in budgets {
            for elapsed in elapsedDurations {
                let clock = RetryPolicyClock()
                let calls = RetryPolicyCounter()
                let failure = RetryPolicyFailure()
                let middleware = RetryMiddleware(
                    configuration: .init(
                        maxAttempts: 1,
                        strategy: .fixed(delay: 0),
                        errorEvaluator: { _ in true },
                        emitEvents: false,
                        maxRetryTime: budget
                    ),
                    now: { clock.now() },
                    sleep: { clock.recordSleep($0) }
                )

                let result = await observeSettlement(middleware) { _, _ in
                    if calls.increment() == 1 {
                        clock.advance(by: elapsed)
                        throw failure
                    }
                    return 7
                }

                let label = "budget=\(budget), elapsed=\(elapsed)"
                XCTAssertEqual(try? result.get(), 7, label)
                XCTAssertEqual(calls.count, 2, label)
                XCTAssertEqual(clock.sleeps, [.zero], label)
            }
        }
    }

    func testBudgetsBeyondDurationRangeRemainOpenAtMaximumElapsed() async {
        let budgets: [TimeInterval] = [
            170_141_183_460_469_243_904, Double.greatestFiniteMagnitude
        ]
        let elapsedDurations: [Duration] = [
            Duration(attoseconds: Int128.max - 1_000_000_000),
            Duration(attoseconds: .max)
        ]
        for budget in budgets {
            for elapsed in elapsedDurations {
                let clock = RetryPolicyClock()
                let calls = RetryPolicyCounter()
                let failure = RetryPolicyFailure()
                let middleware = RetryMiddleware(
                    configuration: .init(
                        maxAttempts: 1,
                        strategy: .fixed(delay: 0),
                        errorEvaluator: { _ in true },
                        emitEvents: false,
                        maxRetryTime: budget
                    ),
                    now: { clock.now() },
                    sleep: { clock.recordSleep($0) }
                )

                let result = await observeSettlement(middleware) { _, _ in
                    if calls.increment() == 1 {
                        clock.advance(by: elapsed)
                        throw failure
                    }
                    return 7
                }

                XCTAssertEqual(try? result.get(), 7, "budget=\(budget)")
                XCTAssertEqual(calls.count, 2)
                XCTAssertEqual(clock.sleeps, [.zero])
            }
        }
    }

    func testLargeRemainingBudgetClampsBackoffWithoutRounding() async {
        let clock = RetryPolicyClock()
        let calls = RetryPolicyCounter()
        let failure = RetryPolicyFailure()
        let middleware = RetryMiddleware(
            configuration: .init(
                maxAttempts: 1,
                strategy: .fixed(delay: 67_108_864),
                errorEvaluator: { _ in true },
                emitEvents: false,
                maxRetryTime: 67_108_864
            ),
            now: { clock.now() },
            sleep: { clock.recordSleep($0) }
        )

        let result = await observeSettlement(middleware) { _, _ in
            if calls.increment() == 1 {
                clock.advance(by: .seconds(33_554_432) + .nanoseconds(1))
                throw failure
            }
            return 7
        }

        assertOriginalFailure(result, failure)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(clock.sleeps, [.seconds(33_554_432) - .nanoseconds(1)])
    }

    func testCancellationDuringBackoffSettlesTheSleeper() async {
        let clock = ManualAdmissionClock()
        let calls = RetryPolicyCounter()
        let failure = RetryPolicyFailure()
        let completed = expectation(description: "cancelled backoff settled")
        let middleware = RetryMiddleware(
            configuration: .init(
                maxAttempts: 2,
                strategy: .fixed(delay: 30),
                errorEvaluator: { _ in true },
                emitEvents: false,
                maxRetryTime: 5
            ),
            now: { clock.now() },
            sleep: { try await clock.sleep(for: $0) }
        )
        let execution = Task { () -> Result<Int, any Error> in
            defer { completed.fulfill() }
            do {
                return .success(try await middleware.execute(RetryPolicyCommand(), context: CommandContext()) { _, _ in
                    calls.increment()
                    throw failure
                })
            } catch { return .failure(error) }
        }

        let observationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while clock.sleepingCount == 0 && ContinuousClock.now < observationDeadline { await Task.yield() }
        XCTAssertEqual(clock.sleepingCount, 1)
        execution.cancel()
        await fulfillment(of: [completed], timeout: 1)
        let result = await execution.value

        switch result {
        case .failure(let error): XCTAssertEqual((error as? PipelineError)?.isCancellation, true)
        case .success: XCTFail("Expected cancellation during backoff")
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(clock.callCount, 1)
        XCTAssertEqual(clock.completedCount, 1)
        XCTAssertEqual(clock.sleepingCount, 0)
    }

    func testCancellationErrorsBypassEvaluatorEvenAtExpiry() async {
        let cases: [(any Error, String?)] = [
            (CancellationError(), nil), (PipelineError.cancelled(context: "original"), "original")
        ]
        for (failure, expectedContext) in cases {
            let clock = RetryPolicyClock()
            let evaluations = RetryPolicyCounter()
            let calls = RetryPolicyCounter()
            let context = CommandContext()
            context.markAsCancelled(reason: .timeout(duration: 9, gracePeriod: nil))
            let middleware = RetryMiddleware(
                configuration: .init(
                    maxAttempts: 2,
                    strategy: .fixed(delay: 0),
                    errorEvaluator: { _ in evaluations.increment(); return true },
                    emitEvents: false,
                    maxRetryTime: 5
                ),
                now: { clock.now() },
                sleep: { clock.recordSleep($0) }
            )

            let result = await observeSettlement(middleware, context: context) { _, _ in
                calls.increment()
                clock.advance(by: .seconds(5))
                throw failure
            }

            switch result {
            case .failure(let error):
                if case PipelineError.cancelled(let originalContext) = error {
                    XCTAssertEqual(originalContext, expectedContext)
                } else { XCTFail("Expected typed cancellation, got \(error)") }
            case .success: XCTFail("Cancellation must propagate")
            }
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(evaluations.count, 0)
            XCTAssertTrue(clock.sleeps.isEmpty)
            XCTAssertEqual(context.getCancellationReason(), .timeout(duration: 9, gracePeriod: nil))
        }
    }

    func testDiagnosticCancellationReasonDoesNotBlockRetry() async {
        let clock = RetryPolicyClock()
        let calls = RetryPolicyCounter()
        let failure = RetryPolicyFailure()
        let context = CommandContext()
        context.markAsCancelled(reason: .timeout(duration: 9, gracePeriod: nil))
        let middleware = RetryMiddleware(
            configuration: .init(
                maxAttempts: 1,
                strategy: .fixed(delay: 0),
                errorEvaluator: { _ in true },
                emitEvents: false,
                maxRetryTime: 5
            ),
            now: { clock.now() },
            sleep: { clock.recordSleep($0) }
        )

        let result = await observeSettlement(middleware, context: context) { _, _ in
            if calls.increment() == 1 { throw failure }
            return 7
        }

        XCTAssertEqual(try? result.get(), 7)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(context.getCancellationReason(), .timeout(duration: 9, gracePeriod: nil))
    }

    func testPreCancelledExecutionTakesPrecedenceOverZeroBudget() async {
        let calls = RetryPolicyCounter()
        let middleware = RetryMiddleware(configuration: .init(emitEvents: false, maxRetryTime: 0))
        let execution = Task { () -> Result<Int, any Error> in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                return .success(try await middleware.execute(RetryPolicyCommand(), context: CommandContext()) { _, _ in
                    calls.increment()
                    return 7
                })
            } catch { return .failure(error) }
        }

        switch await execution.value {
        case .failure(let error): XCTAssertEqual((error as? PipelineError)?.isCancellation, true)
        case .success: XCTFail("Expected cancellation before initial admission")
        }
        XCTAssertEqual(calls.count, 0)
    }

    func testHTTPStatusExtractionSupportsConsumerErrorTypes() async {
        let cases: [(Int?, Int)] = [(503, 2), (404, 1), (nil, 1)]
        for (status, expectedCalls) in cases {
            let calls = RetryPolicyCounter()
            let extractions = RetryPolicyCounter()
            let failure = ConsumerHTTPFailure(status: status)
            let middleware = RetryMiddleware.forHTTPStatusCodes([429, 503], statusCode: { error in
                extractions.increment()
                return (error as? ConsumerHTTPFailure)?.status
            })

            do {
                let result = try await middleware.execute(RetryPolicyCommand(), context: CommandContext()) { _, _ in
                    if calls.increment() == 1 { throw failure }
                    return 7
                }
                XCTAssertEqual(expectedCalls, 2)
                XCTAssertEqual(result, 7)
            } catch {
                XCTAssertEqual(expectedCalls, 1)
                XCTAssertTrue((error as? ConsumerHTTPFailure) === failure)
            }
            XCTAssertEqual(calls.count, expectedCalls)
            XCTAssertEqual(extractions.count, 1)
        }
    }

    func testHTTPStatusExtractionExcludesCancellation() async {
        let failures: [any Error] = [CancellationError(), PipelineError.cancelled(context: "original")]
        for failure in failures {
            let calls = RetryPolicyCounter()
            let extractions = RetryPolicyCounter()
            let middleware = RetryMiddleware.forHTTPStatusCodes([503], statusCode: { _ in
                extractions.increment()
                return 503
            })

            let result = await observeSettlement(middleware) { _, _ in
                calls.increment()
                throw failure
            }

            switch result {
            case .failure(let error): XCTAssertEqual((error as? PipelineError)?.isCancellation, true)
            case .success: XCTFail("Expected cancellation")
            }
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(extractions.count, 0)
        }
    }
}
