import Foundation
import XCTest
import PipelineKitCore
@testable import PipelineKitResilience

private struct PolicyCommand: Command { typealias Result = String }
private enum PolicyForeignError: Error { case unrelated }
private struct PolicyForeignWrapper: LocalizedError {
    var errorDescription: String? { "timeout" }
}
private actor PolicyCounter {
    private var value = 0
    func increment() -> Int { value += 1; return value }
    func count() -> Int { value }
}

final class ResilienceErrorPolicyTests: XCTestCase {
    func testTimeoutProducerByPolicyMatrix() async throws {
        let errors: [(String, any Error)] = [
            ("timeout", PipelineError.timeout(duration: 1, context: nil)),
            ("bulkhead", PipelineError.bulkheadTimeout(timeout: 1, queueTime: 1)),
            ("resilience", PipelineError.resilience(reason: .timeoutExceeded)),
            ("backpressure", PipelineError.backPressure(reason: .timeout(duration: 1))),
            ("URL", URLError(.timedOut))
        ]
        for (name, failure) in errors {
            await assertRetryAndBreaker(name: name, failure: failure, retry: true, breaker: true)
        }
        // Capture the error produced by the real timeout middleware.
        let timeout = TimeoutMiddleware(defaultTimeout: 0.01)
        do {
            _ = try await timeout.execute(PolicyCommand(), context: CommandContext()) { _, _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "late"
            }
            XCTFail("Expected actual timeout")
        } catch {
            guard case PipelineError.timeout = error else { XCTFail("Unexpected producer error: \(error)"); return }
            await assertRetryAndBreaker(name: "actual timeout", failure: error, retry: true, breaker: true)
        }
        // Wrapped pipeline timeout remains unknown; no recursive unwrap.
        let wrapped = PipelineError.wrapped(PipelineError.timeout(duration: 1, context: nil), context: nil)
        await assertRetryAndBreaker(name: "wrapped URL timeout", failure: wrapped, retry: false, breaker: false)
    }

    func testNestedTimeoutMiddlewarePolicies() async throws {
        let retry = RetryMiddleware(configuration: .init(maxAttempts: 2, strategy: .fixed(delay: 0), retryableErrors: [.timeout], emitEvents: false))
        let retryCount = PolicyCounter()
        let result = try await retry.execute(PolicyCommand(), context: CommandContext()) { command, _ in
            let attempt = await retryCount.increment()
            if attempt == 2 { return "success" }
            return try await TimeoutMiddleware(defaultTimeout: 0.01).execute(command, context: CommandContext()) { _, _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "late"
            }
        }
        XCTAssertEqual(result, "success")
        let attempts = await retryCount.count()
        XCTAssertEqual(attempts, 2)

        let breaker = CircuitBreakerMiddleware(configuration: .init(failureThreshold: 1, recoveryTimeout: 60, triggeredByErrors: [.timeout], emitEvents: false))
        let entries = PolicyCounter()
        do {
            _ = try await breaker.execute(PolicyCommand(), context: CommandContext()) { command, _ in
                _ = await entries.increment()
                return try await TimeoutMiddleware(defaultTimeout: 0.01).execute(command, context: CommandContext()) { _, _ in
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    return "late"
                }
            }
            XCTFail("Expected timeout")
        } catch {
            guard case PipelineError.timeout = error else { XCTFail("Unexpected error: \(error)"); return }
        }
        XCTAssertEqual(breaker.circuitState, "open")
        do {
            _ = try await breaker.execute(PolicyCommand(), context: CommandContext()) { _, _ in
                _ = await entries.increment(); return "entered"
            }
            XCTFail("Expected rejection")
        } catch {
            guard case PipelineError.circuitBreakerOpen(let resetTime) = error else { XCTFail("Unexpected error: \(error)"); return }
            XCTAssertNotNil(resetTime)
        }
        let count = await entries.count()
        XCTAssertEqual(count, 1)
    }

    func testNegativeAndOverridePolicies() async {
        await assertRetryAndBreaker(name: "native cancellation override", failure: CancellationError(), retry: false, breaker: false, override: true)
        await assertRetryAndBreaker(name: "cancellation", failure: CancellationError(), retry: false, breaker: false)
        await assertRetryAndBreaker(name: "validation", failure: PipelineError.validation(field: nil, reason: .custom("timeout")), retry: false, breaker: false)
        await assertRetryAndBreaker(name: "wrapped timeout text", failure: PipelineError.wrapped(PolicyForeignWrapper(), context: nil), retry: false, breaker: false)
        await assertRetryAndBreaker(name: "pipeline cancellation text", failure: PipelineError.cancelled(context: "timeout"), retry: false, breaker: false)
        await assertRetryAndBreaker(name: "pipeline cancellation unknown", failure: PipelineError.cancelled(context: nil), retry: false, breaker: false, defaultUnknown: true)
        await assertRetryAndBreaker(name: "foreign wrapper text", failure: PolicyForeignWrapper(), retry: true, breaker: true)
        await assertRetryAndBreaker(name: "foreign", failure: PolicyForeignError.unrelated, retry: false, breaker: false)
        await assertRetryAndBreaker(name: "default unknown", failure: PolicyForeignError.unrelated, retry: false, breaker: true, defaultUnknown: true)
        await assertRetryAndBreaker(name: "override", failure: PipelineError.timeout(duration: 1, context: nil), retry: false, breaker: false, override: false)
        await assertRetryAndBreaker(name: "override foreign", failure: PolicyForeignError.unrelated, retry: true, breaker: true, override: true)
    }

    func testActualBulkheadProducerErrorsReachPolicies() async throws {
        for partitioned in [false, true] {
            for timeout in [false, true] {
                let subject: BulkheadAdmissionSubject
                if partitioned {
                    subject = .partitioned(PartitionedBulkheadMiddleware(configuration: .init(
                        partitions: ["default": .init(capacity: 1, queueSize: timeout ? 1 : 0, queueTimeout: timeout ? 0.01 : nil)],
                        partitionExtractor: { _, _ in "default" }, allowBorrowing: false
                    )))
                } else {
                    subject = .ordinary(BulkheadMiddleware(configuration: .init(
                        maxConcurrency: 1, maxQueueSize: timeout ? 1 : 0,
                        queueTimeout: timeout ? 0.01 : nil, rejectionPolicy: timeout ? .queue : .failFast,
                        emitMetrics: false
                    )))
                }
                let ledger = BulkheadHandlerLedger()
                let holder = Task {
                    try await subject.execute("holder", CommandContext()) {
                        try await ledger.run("holder", fails: false)
                    }
                }
                while !(await ledger.entered("holder")) { await Task.yield() }
                var produced: (any Error)?
                do {
                    _ = try await subject.execute("rejected", CommandContext()) { XCTFail("Rejected work entered"); return "unexpected" }
                    XCTFail("Expected rejection or timeout")
                } catch { produced = error }
                await ledger.release("holder")
                _ = try await holder.value
                let snapshot = await subject.snapshot()
                XCTAssertEqual(snapshot.active, 0)
                XCTAssertEqual(snapshot.queued, 0)
                guard let produced else { continue }
                if timeout {
                    guard case PipelineError.bulkheadTimeout = produced else { XCTFail("Actual timeout producer emitted \(produced)"); continue }
                } else {
                    guard case PipelineError.bulkheadRejected = produced else { XCTFail("Actual rejection producer emitted \(produced)"); continue }
                }
                await assertRetryAndBreaker(name: "actual \(subject.name), timeout=\(timeout)", failure: produced, retry: timeout, breaker: timeout, defaultUnknown: true)
                let health = HealthCheckMiddleware(configuration: .init(failureThreshold: 1, minRequests: 1, emitMetrics: false))
                do {
                    _ = try await health.execute(PolicyCommand(), context: CommandContext()) { _, _ in throw produced }
                    XCTFail("Expected produced error")
                } catch { }
                let status = await health.getHealthStatus(for: "PolicyCommand")
                XCTAssertEqual(status.totalRequests, timeout ? 1 : 0)
                XCTAssertEqual(status.recentFailures, timeout ? 1 : 0)
            }
        }
    }

    func testCancellationBypassesEveryCustomPolicy() async {
        for failure: any Error in [CancellationError(), PipelineError.cancelled(context: "caller")] {
            let retryCalls = PolicyPredicateProbe()
            let retry = RetryMiddleware(configuration: .init(maxAttempts: 2, strategy: .fixed(delay: 0), errorEvaluator: { _ in retryCalls.record(); return true }, emitEvents: false))
            let retryAttempts = PolicyCounter()
            do {
                _ = try await retry.execute(PolicyCommand(), context: CommandContext()) { _, _ in
                    _ = await retryAttempts.increment()
                    throw failure
                }
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(isPolicyCancellation(error)) }
            let retryCount = await retryAttempts.count()
            XCTAssertEqual(retryCount, 1)
            XCTAssertEqual(retryCalls.count, 0)

            let resilientCalls = PolicyPredicateProbe()
            let resilient = ResilientMiddleware(name: "policy", retryPolicy: .init(maxAttempts: 3, delayStrategy: .immediate, shouldRetry: { _ in resilientCalls.record(); return true }))
            let resilientAttempts = PolicyCounter()
            do {
                _ = try await resilient.execute(PolicyCommand(), context: CommandContext()) { _, _ in
                    _ = await resilientAttempts.increment()
                    throw failure
                }
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(isPolicyCancellation(error)) }
            let resilientCount = await resilientAttempts.count()
            XCTAssertEqual(resilientCount, 1)
            XCTAssertEqual(resilientCalls.count, 0)

            let breakerCalls = PolicyPredicateProbe()
            let breaker = CircuitBreakerMiddleware(configuration: .init(failureThreshold: 1, emitEvents: false, errorEvaluator: { _ in breakerCalls.record(); return true }))
            do {
                _ = try await breaker.execute(PolicyCommand(), context: CommandContext()) { _, _ in throw failure }
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(isPolicyCancellation(error)) }
            XCTAssertEqual(breaker.circuitState, "closed")
            XCTAssertEqual(breakerCalls.count, 0)
        }
    }

    func testDomainAndAdmissionErrorsDoNotScoreHealthOrDefaultBreaker() async {
        for failure in excludedPolicyFailures {
            await assertRetryAndBreaker(name: String(reflecting: failure), failure: failure, retry: false, breaker: false, defaultUnknown: true)
            let health = HealthCheckMiddleware(configuration: .init(failureThreshold: 1, minRequests: 1, emitMetrics: false))
            do {
                _ = try await health.execute(PolicyCommand(), context: CommandContext()) { _, _ in throw failure }
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(String(reflecting: error), String(reflecting: failure)) }
            let status = await health.getHealthStatus(for: "PolicyCommand")
            XCTAssertEqual(status.totalRequests, 0, String(reflecting: failure))
            XCTAssertEqual(status.recentFailures, 0, String(reflecting: failure))
        }
    }

    func testIgnoredHealthFailuresDoNotBecomeSuccessesOrResetFailureRun() async {
        let health = HealthCheckMiddleware(configuration: .init(failureThreshold: 2, minRequests: 1, emitMetrics: false))
        let failures: [any Error] = [PolicyForeignError.unrelated, CancellationError(), PipelineError.cancelled(context: nil)] + excludedPolicyFailures + [PolicyForeignError.unrelated]
        for failure in failures {
            do {
                _ = try await health.execute(PolicyCommand(), context: CommandContext()) { _, _ in throw failure }
                XCTFail("Expected failure")
            } catch { }
        }
        let status = await health.getHealthStatus(for: "PolicyCommand")
        XCTAssertEqual(status.totalRequests, 2)
        XCTAssertEqual(status.recentFailures, 2)
        XCTAssertEqual(status.state, .unhealthy)
        XCTAssertEqual(status.successRate, 0, accuracy: 0.0001)
    }

    func testCancelledTaskCannotEnterNextRetryAttempt() async {
        for resilient in [false, true] {
            for delay in [0.0, 60.0] {
                let attempts = PolicyCounter()
                let task = Task {
                    let next: MiddlewareNext<PolicyCommand> = { _, _ in
                        _ = await attempts.increment()
                        withUnsafeCurrentTask { $0?.cancel() }
                        throw PolicyForeignError.unrelated
                    }
                    if resilient {
                        return try await ResilientMiddleware(name: "policy", retryPolicy: .init(maxAttempts: 3, delayStrategy: .fixed(delay), shouldRetry: { _ in true })).execute(PolicyCommand(), context: CommandContext(), next: next)
                    }
                    return try await RetryMiddleware(configuration: .init(maxAttempts: 2, strategy: .fixed(delay: delay), errorEvaluator: { _ in true }, emitEvents: false)).execute(PolicyCommand(), context: CommandContext(), next: next)
                }
                do {
                    _ = try await task.value
                    XCTFail("Expected cancellation")
                } catch {
                    guard case PipelineError.cancelled = error else { XCTFail("Expected library cancellation, got \(error)"); continue }
                }
                let count = await attempts.count()
                XCTAssertEqual(count, 1, "resilient=\(resilient), delay=\(delay)")
            }
        }
    }

    func testHealthCustomEvaluatorOverridesOnlyNoncancellationErrors() async {
        let failures: [any Error] = [CancellationError(), PipelineError.cancelled(context: "caller"), PipelineError.validation(field: nil, reason: .missingRequired), PolicyForeignError.unrelated, PipelineError.timeout(duration: 1, context: nil)]
        for decision in [false, true] {
            for failure in failures {
                let calls = PolicyPredicateProbe()
                let health = HealthCheckMiddleware(configuration: .init(failureThreshold: 1, minRequests: 1, emitMetrics: false, errorEvaluator: { _ in calls.record(); return decision }))
                do {
                    _ = try await health.execute(PolicyCommand(), context: CommandContext()) { _, _ in throw failure }
                    XCTFail("Expected failure")
                } catch {
                    if isPolicyCancellation(failure) {
                        guard case PipelineError.cancelled = error else { XCTFail("Expected normalized cancellation: \(error)"); continue }
                    } else {
                        XCTAssertEqual(String(reflecting: error), String(reflecting: failure))
                    }
                }
                let cancellation = isPolicyCancellation(failure)
                let status = await health.getHealthStatus(for: "PolicyCommand")
                XCTAssertEqual(calls.count, cancellation ? 0 : 1)
                XCTAssertEqual(status.totalRequests, decision && !cancellation ? 1 : 0)
                XCTAssertEqual(status.recentFailures, decision && !cancellation ? 1 : 0)
            }
        }
    }

    func testPreCancelledPolicyBoundariesDoNotEnterWork() async {
        for kind in 0..<4 {
            let calls = PolicyCounter()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                let next: MiddlewareNext<PolicyCommand> = { _, _ in _ = await calls.increment(); return "unexpected" }
                switch kind {
                case 0: return try await RetryMiddleware(maxAttempts: 2, strategy: .fixed(delay: 0)).execute(PolicyCommand(), context: CommandContext(), next: next)
                case 1: return try await ResilientMiddleware(name: "policy").execute(PolicyCommand(), context: CommandContext(), next: next)
                case 2: return try await CircuitBreakerMiddleware().execute(PolicyCommand(), context: CommandContext(), next: next)
                default: return try await HealthCheckMiddleware(configuration: .init(emitMetrics: false)).execute(PolicyCommand(), context: CommandContext(), next: next)
                }
            }
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch {
                guard case PipelineError.cancelled = error else { XCTFail("Expected library cancellation: \(error)"); continue }
            }
            let count = await calls.count()
            XCTAssertEqual(count, 0)
        }
    }

    func testCancellationAfterBackoffSelectedStopsBothRetryPolicies() async {
        for resilient in [false, true] {
            let selected = AsyncStream<Void>.makeStream()
            let attempts = PolicyCounter()
            let task = Task {
                defer { selected.continuation.finish() }
                let next: MiddlewareNext<PolicyCommand> = { _, _ in _ = await attempts.increment(); throw PolicyForeignError.unrelated }
                if resilient {
                    return try await ResilientMiddleware(name: "policy", retryPolicy: .init(maxAttempts: 3, delayStrategy: .fixed(60), shouldRetry: { _ in selected.continuation.yield(); return true })).execute(PolicyCommand(), context: CommandContext(), next: next)
                }
                return try await RetryMiddleware(configuration: .init(maxAttempts: 2, strategy: .custom { _ in selected.continuation.yield(); return 60 }, errorEvaluator: { _ in true }, emitEvents: false)).execute(PolicyCommand(), context: CommandContext(), next: next)
            }
            for await _ in selected.stream { break }
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch {
                guard case PipelineError.cancelled = error else { XCTFail("Expected library cancellation: \(error)"); continue }
            }
            let count = await attempts.count()
            XCTAssertEqual(count, 1)
        }
    }

    func testCancelledTaskDoesNotReplaceUnrelatedNonretryableError() async {
        for resilient in [false, true] {
            let task = Task {
                let next: MiddlewareNext<PolicyCommand> = { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw PolicyForeignError.unrelated
                }
                if resilient {
                    return try await ResilientMiddleware(name: "policy", retryPolicy: .init(maxAttempts: 3, delayStrategy: .immediate, shouldRetry: { _ in false })).execute(PolicyCommand(), context: CommandContext(), next: next)
                }
                return try await RetryMiddleware(configuration: .init(maxAttempts: 2, strategy: .fixed(delay: 0), errorEvaluator: { _ in false }, emitEvents: false)).execute(PolicyCommand(), context: CommandContext(), next: next)
            }
            do {
                _ = try await task.value
                XCTFail("Expected original error")
            } catch { XCTAssertTrue(error is PolicyForeignError) }
        }
    }

    func testIgnoredHalfOpenProbeReleasesSlotWithoutClosing() async throws {
        for failure: any Error in [CancellationError(), PipelineError.cancelled(context: nil), PipelineError.validation(field: nil, reason: .missingRequired)] {
            let breaker = CircuitBreakerMiddleware(configuration: .init(failureThreshold: 1, recoveryTimeout: 0.1, halfOpenSuccessThreshold: 1, emitEvents: false))
            do {
                _ = try await breaker.execute(PolicyCommand(), context: CommandContext()) { _, _ in throw PolicyForeignError.unrelated }
            } catch { }
            try await Task.sleep(nanoseconds: 150_000_000)
            do {
                _ = try await breaker.execute(PolicyCommand(), context: CommandContext()) { _, _ in throw failure }
                XCTFail("Expected ignored probe failure")
            } catch { XCTAssertTrue(isPolicyCancellation(error) || error is PipelineError) }
            XCTAssertEqual(breaker.circuitState, "half_open")
            let result = try await breaker.execute(PolicyCommand(), context: CommandContext()) { _, _ in "replacement probe" }
            XCTAssertEqual(result, "replacement probe")
            XCTAssertEqual(breaker.circuitState, "closed")
        }
    }

    func testBreakerRejectionCarriesStableOpenDeadline() async throws {
        let breaker = CircuitBreakerMiddleware(configuration: .init(failureThreshold: 1, recoveryTimeout: 60, emitEvents: false))
        let beforeFailure = Date()
        do {
            _ = try await breaker.execute(PolicyCommand(), context: CommandContext()) { _, _ in throw PolicyForeignError.unrelated }
        } catch { }
        let afterFailure = Date()
        var deadlines: [Date] = []
        for _ in 0..<2 {
            do {
                _ = try await breaker.execute(PolicyCommand(), context: CommandContext()) { _, _ in XCTFail("Rejected work entered"); return "unexpected" }
                XCTFail("Expected rejection")
            } catch {
                guard case PipelineError.circuitBreakerOpen(let resetTime) = error, let resetTime else { XCTFail("Expected typed open deadline: \(error)"); continue }
                deadlines.append(resetTime)
                XCTAssertGreaterThanOrEqual(resetTime, beforeFailure.addingTimeInterval(60))
                XCTAssertLessThanOrEqual(resetTime, afterFailure.addingTimeInterval(60))
            }
        }
        XCTAssertEqual(deadlines.count, 2)
        XCTAssertEqual(deadlines.first, deadlines.last)
    }

    private func assertRetryAndBreaker(name: String, failure: any Error, retry shouldRetry: Bool, breaker shouldOpen: Bool, defaultUnknown: Bool = false, override: Bool? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        let evaluator: (@Sendable (any Error) -> Bool)?
        if let override { evaluator = { _ in override } } else { evaluator = nil }
        let retry = RetryMiddleware(configuration: .init(maxAttempts: 2, strategy: .fixed(delay: 0), retryableErrors: [.timeout], errorEvaluator: evaluator, emitEvents: false))
        let retryCount = PolicyCounter()
        do {
            let result = try await retry.execute(PolicyCommand(), context: CommandContext()) { _, _ in
                if await retryCount.increment() == 1 { throw failure }
                return "success"
            }
            XCTAssertTrue(shouldRetry, name, file: file, line: line)
            XCTAssertEqual(result, "success", name, file: file, line: line)
        } catch {
            XCTAssertFalse(shouldRetry, "\(name): \(error)", file: file, line: line)
            if isPolicyCancellation(failure) {
                guard case PipelineError.cancelled = error else { XCTFail("Expected normalized cancellation: \(error)", file: file, line: line); return }
            } else {
                XCTAssertEqual(String(reflecting: error), String(reflecting: failure), name, file: file, line: line)
            }
        }
        let attempts = await retryCount.count()
        XCTAssertEqual(attempts, shouldRetry ? 2 : 1, name, file: file, line: line)

        let breaker = CircuitBreakerMiddleware(configuration: .init(failureThreshold: 1, recoveryTimeout: 60, triggeredByErrors: defaultUnknown ? [.timeout, .unknown] : [.timeout], emitEvents: false, errorEvaluator: evaluator))
        let count = PolicyCounter()
        do {
            _ = try await breaker.execute(PolicyCommand(), context: CommandContext()) { _, _ in
                _ = await count.increment(); throw failure
            }
            XCTFail("\(name): expected failure", file: file, line: line)
        } catch {
            if isPolicyCancellation(failure) {
                guard case PipelineError.cancelled = error else { XCTFail("Expected normalized cancellation: \(error)", file: file, line: line); return }
            } else {
                XCTAssertEqual(String(reflecting: error), String(reflecting: failure), name, file: file, line: line)
            }
        }
        XCTAssertEqual(breaker.circuitState, shouldOpen ? "open" : "closed", name, file: file, line: line)
        do {
            let result = try await breaker.execute(PolicyCommand(), context: CommandContext()) { _, _ in
                _ = await count.increment(); return "entered"
            }
            XCTAssertFalse(shouldOpen, name, file: file, line: line)
            XCTAssertEqual(result, "entered", name, file: file, line: line)
        } catch {
            XCTAssertTrue(shouldOpen, "\(name): \(error)", file: file, line: line)
            guard case PipelineError.circuitBreakerOpen(let resetTime) = error else { XCTFail("\(name): unexpected rejection \(error)", file: file, line: line); return }
            XCTAssertNotNil(resetTime, name, file: file, line: line)
        }
        let entries = await count.count()
        XCTAssertEqual(entries, shouldOpen ? 1 : 2, name, file: file, line: line)
    }
}

private let excludedPolicyFailures: [PipelineError] = [
    .validation(field: nil, reason: .missingRequired),
    .authentication(required: true),
    .authorization(reason: .invalidCredentials),
    .securityPolicy(reason: .validationFailed(reason: "policy")),
    .rateLimitExceeded(limit: 1, resetTime: nil, retryAfter: nil),
    .circuitBreakerOpen(resetTime: nil),
    .bulkheadRejected(reason: "full"),
    .resilience(reason: .bulkheadFull),
    .resilience(reason: .circuitBreakerOpen),
    .backPressure(reason: .queueFull(current: 1, limit: 1)),
    .backPressure(reason: .commandDropped(reason: "full")),
    .backPressure(reason: .memoryPressure)
]

private func isPolicyCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if case PipelineError.cancelled = error { return true }
    return false
}

private final class PolicyPredicateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func record() { lock.lock(); defer { lock.unlock() }; calls += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}
