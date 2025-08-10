import XCTest
import PipelineKitCore
@testable import PipelineKitResilience

final class CircuitBreakerMiddlewareTests: XCTestCase {

    // MARK: - Test Commands

    struct SuccessCommand: Command {
        typealias Result = String
        func execute() async throws -> String {
            "Success"
        }
    }

    struct FailingCommand: Command {
        typealias Result = String
        let error: Error

        init(error: Error = TestError.expectedFailure) {
            self.error = error
        }

        func execute() async throws -> String {
            throw error
        }
    }

    struct SlowCommand: Command {
        typealias Result = String
        let duration: TimeInterval

        func execute() async throws -> String {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            return "Completed"
        }
    }

    enum TestError: Error {
        case expectedFailure
        case networkError
        case timeoutError
    }

    // MARK: - Helper Methods

    private func createMiddleware(
        failureThreshold: Int = 3,
        resetTimeout: TimeInterval = 5.0,
        halfOpenMaxAttempts: Int = 1
    ) -> CircuitBreakerMiddleware {
        CircuitBreakerMiddleware(
            configuration: CircuitBreakerMiddleware.Configuration(
                failureThreshold: failureThreshold,
                resetTimeout: resetTimeout,
                halfOpenMaxAttempts: halfOpenMaxAttempts
            )
        )
    }

    // MARK: - Tests

    func testInitialClosedState() async throws {
        // Given
        let middleware = createMiddleware()
        let command = SuccessCommand()
        let context = CommandContext()

        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }

        // Then
        XCTAssertEqual(result, "Success")
        let state = await middleware.getState()
        XCTAssertEqual(state, .closed)
    }

    func testTransitionToOpenStateAfterFailures() async throws {
        // Given
        let middleware = createMiddleware(failureThreshold: 3)
        let failingCommand = FailingCommand()
        let context = CommandContext()

        // When - cause failures
        for i in 0..<3 {
            do {
                _ = try await middleware.execute(failingCommand, context: context) { cmd, _ in
                    try await cmd.execute()
                }
                XCTFail("Expected failure")
            } catch {
                // Expected
                if i < 2 {
                    let state = await middleware.getState()
                    XCTAssertEqual(state, .closed)
                }
            }
        }

        // Then - circuit should be open
        let state = await middleware.getState()
        XCTAssertEqual(state, .open)

        // Subsequent calls should fail fast
        do {
            _ = try await middleware.execute(SuccessCommand(), context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Expected circuit open error")
        } catch {
            // Verify it's a circuit breaker error
            if case PipelineError.middlewareError(let middleware, _, _) = error {
                XCTAssertEqual(middleware, "CircuitBreakerMiddleware")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    func testTransitionToHalfOpenAfterTimeout() async throws {
        // Given
        let resetTimeout: TimeInterval = 0.1 // Short timeout for testing
        let middleware = createMiddleware(
            failureThreshold: 2,
            resetTimeout: resetTimeout
        )
        let failingCommand = FailingCommand()
        let context = CommandContext()

        // When - cause circuit to open
        for _ in 0..<2 {
            try? await middleware.execute(failingCommand, context: context) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Verify open state
        var state = await middleware.getState()
        XCTAssertEqual(state, .open)

        // Wait for reset timeout
        try await Task.sleep(nanoseconds: UInt64((resetTimeout + 0.05) * 1_000_000_000))

        // Then - should transition to half-open on next call
        let successCommand = SuccessCommand()
        let result = try await middleware.execute(successCommand, context: context) { cmd, _ in
            try await cmd.execute()
        }

        XCTAssertEqual(result, "Success")
        state = await middleware.getState()
        XCTAssertEqual(state, .closed) // Success in half-open closes circuit
    }

    func testHalfOpenToClosedTransition() async throws {
        // Given
        let middleware = createMiddleware(
            failureThreshold: 2,
            resetTimeout: 0.1,
            halfOpenMaxAttempts: 2
        )

        // Open the circuit
        for _ in 0..<2 {
            try? await middleware.execute(FailingCommand(), context: CommandContext()) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Wait for half-open
        try await Task.sleep(nanoseconds: 150_000_000)

        // When - succeed in half-open state
        for _ in 0..<2 {
            _ = try await middleware.execute(SuccessCommand(), context: CommandContext()) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Then - circuit should close
        let state = await middleware.getState()
        XCTAssertEqual(state, .closed)
    }

    func testHalfOpenBackToOpenOnFailure() async throws {
        // Given
        let middleware = createMiddleware(
            failureThreshold: 2,
            resetTimeout: 0.1
        )

        // Open the circuit
        for _ in 0..<2 {
            try? await middleware.execute(FailingCommand(), context: CommandContext()) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Wait for half-open
        try await Task.sleep(nanoseconds: 150_000_000)

        // When - fail in half-open state
        do {
            _ = try await middleware.execute(FailingCommand(), context: CommandContext()) { cmd, _ in
                try await cmd.execute()
            }
        } catch {
            // Expected
        }

        // Then - circuit should reopen
        let state = await middleware.getState()
        XCTAssertEqual(state, .open)
    }

    func testSuccessRateThreshold() async throws {
        // Given
        let middleware = CircuitBreakerMiddleware(
            configuration: CircuitBreakerMiddleware.Configuration(
                failureThreshold: 5,
                successThreshold: 0.6, // 60% success rate required
                sampleSize: 10
            )
        )

        // When - mix of successes and failures
        for i in 0..<10 {
            if i % 3 == 0 { // ~33% failure rate
                try? await middleware.execute(FailingCommand(), context: CommandContext()) { cmd, _ in
                    try await cmd.execute()
                }
            } else {
                _ = try? await middleware.execute(SuccessCommand(), context: CommandContext()) { cmd, _ in
                    try await cmd.execute()
                }
            }
        }

        // Then - circuit should remain closed (failure rate below threshold)
        let state = await middleware.getState()
        XCTAssertEqual(state, .closed)
    }

    func testCustomFailureHandler() async throws {
        // Given
        let expectation = XCTestExpectation(description: "Failure handler called")
        var handledError: Error?

        let middleware = CircuitBreakerMiddleware(
            configuration: CircuitBreakerMiddleware.Configuration(
                failureThreshold: 1,
                failureHandler: { error, command in
                    handledError = error
                    expectation.fulfill()
                }
            )
        )

        // When
        do {
            _ = try await middleware.execute(FailingCommand(), context: CommandContext()) { cmd, _ in
                try await cmd.execute()
            }
        } catch {
            // Expected
        }

        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNotNil(handledError)
    }

    func testStateChangeHandler() async throws {
        // Given
        let expectation = XCTestExpectation(description: "State change handler called")
        expectation.expectedFulfillmentCount = 2 // closed->open, open->half-open

        var stateChanges: [(CircuitBreakerMiddleware.State, CircuitBreakerMiddleware.State)] = []

        let middleware = CircuitBreakerMiddleware(
            configuration: CircuitBreakerMiddleware.Configuration(
                failureThreshold: 2,
                resetTimeout: 0.1,
                stateChangeHandler: { oldState, newState in
                    stateChanges.append((oldState, newState))
                    expectation.fulfill()
                }
            )
        )

        // When - trigger state changes
        for _ in 0..<2 {
            try? await middleware.execute(FailingCommand(), context: CommandContext()) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Wait and trigger half-open
        try await Task.sleep(nanoseconds: 150_000_000)
        _ = try? await middleware.execute(SuccessCommand(), context: CommandContext()) { cmd, _ in
            try await cmd.execute()
        }

        // Then
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(stateChanges.count, 2)
        XCTAssertEqual(stateChanges[0].0, .closed)
        XCTAssertEqual(stateChanges[0].1, .open)
    }

    func testMetricsTracking() async throws {
        // Given
        let middleware = createMiddleware()
        let context = CommandContext()

        // When - execute various commands
        _ = try await middleware.execute(SuccessCommand(), context: context) { cmd, _ in
            try await cmd.execute()
        }

        try? await middleware.execute(FailingCommand(), context: context) { cmd, _ in
            try await cmd.execute()
        }

        // Then - check metrics
        let metrics = await middleware.getMetrics()
        XCTAssertEqual(metrics.successCount, 1)
        XCTAssertEqual(metrics.failureCount, 1)
        XCTAssertEqual(metrics.totalCount, 2)
        XCTAssertEqual(metrics.successRate, 0.5)
    }

    func testConcurrentAccess() async throws {
        // Given
        let middleware = createMiddleware(failureThreshold: 10)
        let iterations = 100

        // When - concurrent executions
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let command = i % 3 == 0 ? FailingCommand() : SuccessCommand()
                    do {
                        _ = try await middleware.execute(command, context: CommandContext()) { cmd, _ in
                            try await cmd.execute()
                        }
                        return true
                    } catch {
                        return false
                    }
                }
            }

            var successes = 0
            var failures = 0
            for await result in group {
                if result {
                    successes += 1
                } else {
                    failures += 1
                }
            }

            // Then - verify counts are consistent
            let metrics = await middleware.getMetrics()
            XCTAssertEqual(metrics.totalCount, successes + failures)
        }
    }

    func testFallbackBehavior() async throws {
        // Given
        let middleware = CircuitBreakerMiddleware(
            configuration: CircuitBreakerMiddleware.Configuration(
                failureThreshold: 1,
                fallbackProvider: { command in
                    return "Fallback response"
                }
            )
        )

        // When - cause circuit to open
        try? await middleware.execute(FailingCommand(), context: CommandContext()) { cmd, _ in
            try await cmd.execute()
        }

        // Then - fallback should be used
        let result = try await middleware.execute(SuccessCommand(), context: CommandContext()) { cmd, _ in
            try await cmd.execute()
        }

        XCTAssertEqual(result, "Fallback response")
    }
}

