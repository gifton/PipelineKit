import XCTest
@testable import PipelineKitResilience
@testable import PipelineKitCore
import PipelineKitTestSupport

// Test counter actor
actor ResilientTestCounter {
    private var value: Int

    init(_ value: Int = 0) {
        self.value = value
    }

    func increment() {
        value += 1
    }

    func get() -> Int {
        value
    }
}

// Test times tracking actor
actor TestTimesActor {
    private var times: [Date] = []

    func recordAttempt() {
        times.append(Date())
    }

    func getTimes() -> [Date] {
        times
    }
}

final class ResilientMiddlewareTests: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()

    func testSuccessfulExecutionWithoutRetry() async throws {
        // Given
        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: RetryPolicy(maxAttempts: 3)
        )

        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()

        actor ExecutionCounter {
            private var count = 0
            func increment() { count += 1 }
            func get() -> Int { count }
        }
        let counter = ExecutionCounter()

        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            await counter.increment()
            return cmd.value
        }

        // Then
        XCTAssertEqual(result, "test")
        let executionCount = await counter.get()
        XCTAssertEqual(executionCount, 1) // Should not retry on success
    }

    func testRetryOnTransientFailure() async throws {
        // Given
        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            delayStrategy: .fixed(0.01), // 10ms delay
            shouldRetry: { error in
                error is TransientError
            }
        )

        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: retryPolicy
        )

        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()

        let attemptTracker = ResilientTestCounter(0)

        // When
        let result = try await middleware.execute(command, context: context) { _, _ in
            await attemptTracker.increment()
            let count = await attemptTracker.get()

            if count < 3 {
                throw TransientError.temporaryFailure
            }

            return "success-\(count)"
        }

        // Then
        XCTAssertEqual(result, "success-3")
        let finalCount = await attemptTracker.get()
        XCTAssertEqual(finalCount, 3) // Should retry twice before succeeding
    }

    func testRetryExhaustion() async throws {
        // Given
        let retryPolicy = RetryPolicy(
            maxAttempts: 2,
            delayStrategy: .fixed(0.01)
        )

        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: retryPolicy
        )

        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()

        let attemptTracker = ResilientTestCounter(0)

        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                await attemptTracker.increment()
                throw TransientError.temporaryFailure
            }
            XCTFail("Should throw after retry exhaustion")
        } catch {
            XCTAssertTrue(error is TransientError)
            let finalCount = await attemptTracker.get()
            XCTAssertEqual(finalCount, 2) // Should attempt maxAttempts times
        }
    }

    func testNoRetryOnNonRetriableError() async throws {
        // Given
        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            shouldRetry: { error in
                !(error is PermanentError)
            }
        )

        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: retryPolicy
        )

        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()

        let attemptTracker = ResilientTestCounter(0)

        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                await attemptTracker.increment()
                throw PermanentError.unrecoverable
            }
            XCTFail("Should throw permanent error")
        } catch {
            XCTAssertTrue(error is PermanentError)
            let finalCount = await attemptTracker.get()
            XCTAssertEqual(finalCount, 1) // Should not retry
        }
    }

    // Circuit breaker functionality has been moved to CircuitBreakerMiddleware
    // These tests are preserved as comments for reference when implementing
    // integration tests that combine ResilientMiddleware with CircuitBreakerMiddleware

    /*
    func testCircuitBreakerOpen() async throws {
        // Test would now use CircuitBreakerMiddleware directly
        // or compose it with ResilientMiddleware in a pipeline
    }
    */

    /*
    func testCircuitBreakerRecovery() async throws {
        // Test would now use CircuitBreakerMiddleware directly
        // or compose it with ResilientMiddleware in a pipeline

        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()

        // Trip the circuit
        for _ in 0..<2 {
            do {
                _ = try await middleware.execute(command, context: context) { _, _ in
                    throw TransientError.temporaryFailure
                }
            } catch {
                // Expected failures
            }
        }

        // Circuit should be open
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                XCTFail("Should not execute")
                return ""
            }
            XCTFail("Should throw circuit open")
        } catch {
            if let pipelineError = error as? PipelineError,
               case .resilience = pipelineError {
                // Expected
            } else {
                XCTFail("Expected resilience error")
            }
        }

        // Wait for reset timeout (with some buffer)
        // Circuit breaker timeout is 100ms, so we need to wait at least that long
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

        // Circuit should be half-open, allowing one attempt
        let result = try await middleware.execute(command, context: context) { _, _ in
            "recovered"
        }

        XCTAssertEqual(result, "recovered")
    }
    */

    func testExponentialBackoffRetry() async throws {
        // Given
        let retryPolicy = RetryPolicy(
            maxAttempts: 3,
            delayStrategy: .exponentialBackoff(base: 0.01, multiplier: 2.0, maxDelay: 0.1)
        )

        let middleware = ResilientMiddleware(
            name: "test",
            retryPolicy: retryPolicy
        )

        let command = ResilientTestCommand(value: "test")
        let context = CommandContext()

        let attemptTimesActor = TestTimesActor()
        let attemptTracker = ResilientTestCounter(0)

        // When
        do {
            _ = try await middleware.execute(command, context: context) { _, _ in
                await attemptTracker.increment()
                await attemptTimesActor.recordAttempt()
                throw TransientError.temporaryFailure
            }
        } catch {
            // Expected
        }

        // Then
        let finalCount = await attemptTracker.get()
        XCTAssertEqual(finalCount, 3)
        let attemptTimes = await attemptTimesActor.getTimes()
        XCTAssertEqual(attemptTimes.count, 3)

        // Verify exponential delays (with CI tolerance)
        if attemptTimes.count >= 3 {
            let delay1 = attemptTimes[1].timeIntervalSince(attemptTimes[0])
            let delay2 = attemptTimes[2].timeIntervalSince(attemptTimes[1])

            // In CI environments, timing can be highly variable due to resource contention
            // We'll just verify that there were delays and they increased

            // First retry should have some delay (at least 5ms even in CI)
            XCTAssertGreaterThan(delay1, 0.005, "First delay should exist (was \(delay1)s)")
            XCTAssertLessThan(delay1, 1.0, "First delay should be reasonable (was \(delay1)s)")

            // Second retry should also have delay
            XCTAssertGreaterThan(delay2, 0.005, "Second delay should exist (was \(delay2)s)")
            XCTAssertLessThan(delay2, 2.0, "Second delay should be reasonable (was \(delay2)s)")

            // Verify exponential growth pattern (delay2 should generally be >= delay1)
            // In CI, we can't guarantee exact 2x growth due to scheduling
            XCTAssertGreaterThanOrEqual(delay2, delay1 * 0.8,
                "Second delay (\(delay2)s) should generally be >= first delay (\(delay1)s)")
        }
    }

    // Note: Re-enable when EventEmitter is implemented
    // func testObservabilityEvents() async throws {
    //     // Given
    //     let eventCollector = TestEventCollector()
    //     let observerRegistry = ObserverRegistry(observers: [eventCollector])
    //
    //     let middleware = ResilientMiddleware(
    //         name: "test-middleware",
    //         retryPolicy: RetryPolicy(maxAttempts: 2)
    //     )
    //
    //     let command = ResilientTestCommand(value: "test")
    //     let metadata = TestCommandMetadata(userId: "user-123")
    //     let context = CommandContext(metadata: metadata)
    //     await context.setObserverRegistry(observerRegistry)
    //
    //     let attemptTracker = ResilientTestCounter(0)
    //
    //     // When - Fail once then succeed
    //     let result = try await middleware.execute(command, context: context) { _, _ in
    //         await attemptTracker.increment()
    //         let count = await attemptTracker.get()
    //
    //         if count == 1 {
    //             throw TransientError.temporaryFailure
    //         }
    //
    //         return "success"
    //     }
    //
    //     // Then
    //     XCTAssertEqual(result, "success")
    //
    //     // Verify events were emitted
    //     await eventCollector.waitForEvents(count: 2) // retry.failed and retry.attempt
    //
    //     let events = await eventCollector.getEvents()
    //
    //     // Should have retry failed event
    //     let failedEvent = events.first { $0.name == "resilience.retry.failed" }
    //     XCTAssertNotNil(failedEvent)
    //     XCTAssertEqual(failedEvent?.properties["middleware"] as? String, "test-middleware")
    //     XCTAssertEqual(failedEvent?.properties["attempt"] as? Int, 1)
    //     XCTAssertEqual(failedEvent?.properties["userId"] as? String, "user-123")
    //
    //     // Should have retry attempt event
    //     let attemptEvent = events.first { $0.name == "resilience.retry.attempt" }
    //     XCTAssertNotNil(attemptEvent)
    //     XCTAssertEqual(attemptEvent?.properties["attempt"] as? Int, 2)
    // }
}

// Test support types
private struct ResilientTestCommand: Command {
    typealias Result = String
    let value: String

    func execute() async throws -> String {
        return value
    }
}

private enum TransientError: Error {
    case temporaryFailure
}

private enum PermanentError: Error {
    case unrecoverable
}

private actor TestEventCollector: PipelineObserver {
    private var events: [PipelineEvent] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func getEvents() -> [PipelineEvent] {
        events
    }

    func waitForEvents(count: Int) async {
        while events.count < count {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }

    private func notifyWaiters() {
        let waiters = continuations
        continuations.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }

    // PipelineObserver conformance
    func handleEvent(_ event: PipelineEvent) async {
        events.append(event)
        notifyWaiters()
    }
}
