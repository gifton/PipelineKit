import XCTest
import PipelineKitCore
@testable import PipelineKitResilience

final class CircuitBreakerMiddlewareTests: XCTestCase {
    // MARK: - Test Commands

    private struct SuccessCommand: Command {
        typealias Result = String
        func execute() async throws -> String {
            "Success"
        }
    }

    private struct FailingCommand: Command {
        typealias Result = String
        let error: Error

        init(error: Error = TestError.expectedFailure) {
            self.error = error
        }

        func execute() async throws -> String {
            throw error
        }
    }

    private struct SlowCommand: Command {
        typealias Result = String
        let duration: TimeInterval

        func execute() async throws -> String {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            return "Completed"
        }
    }

    private enum TestError: Error {
        case expectedFailure
        case networkError
        case timeoutError
    }

    // MARK: - Helper Methods

    private func createMiddleware(
        failureThreshold: Int = 3,
        recoveryTimeout: TimeInterval = 5.0,
        halfOpenSuccessThreshold: Int = 1
    ) -> CircuitBreakerMiddleware {
        CircuitBreakerMiddleware(
            configuration: CircuitBreakerMiddleware.Configuration(
                failureThreshold: failureThreshold,
                recoveryTimeout: recoveryTimeout,
                halfOpenSuccessThreshold: halfOpenSuccessThreshold
            )
        )
    }

    // MARK: - Tests

    func testInitialClosedState() async throws {
        // Given - Circuit breaker should allow requests initially
        let middleware = createMiddleware()
        let command = SuccessCommand()
        let context = CommandContext()

        // When - Execute a successful command
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            try await cmd.execute()
        }

        // Then - Request should pass through successfully
        XCTAssertEqual(result, "Success", "Circuit breaker should allow requests in initial state")
    }

    func testCircuitOpensAfterFailureThreshold() async throws {
        // Given - Circuit breaker with low threshold
        let middleware = createMiddleware(failureThreshold: 3)
        let failingCommand = FailingCommand()
        let successCommand = SuccessCommand()
        let context = CommandContext()

        // When - Cause failures up to threshold
        for _ in 0..<3 {
            do {
                _ = try await middleware.execute(failingCommand, context: context) { cmd, _ in
                    try await cmd.execute()
                }
                XCTFail("Expected failure")
            } catch {
                // Expected - command should fail normally
            }
        }

        // Then - Circuit should now reject even successful commands (fail fast)
        do {
            _ = try await middleware.execute(successCommand, context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Circuit breaker should reject requests after reaching failure threshold")
        } catch {
            // Expected - circuit breaker should reject all requests when open
            if case PipelineError.middlewareError(let middleware, _, _) = error {
                XCTAssertEqual(middleware, "CircuitBreakerMiddleware", "Error should come from CircuitBreakerMiddleware")
            } else {
                XCTFail("Expected PipelineError.middlewareError, got: \(error)")
            }
        }
    }

    func testCircuitAllowsRequestAfterRecoveryTimeout() async throws {
        // Given - Circuit breaker with short recovery timeout
        let recoveryTimeout: TimeInterval = 0.1
        let middleware = createMiddleware(
            failureThreshold: 2,
            recoveryTimeout: recoveryTimeout
        )
        let failingCommand = FailingCommand()
        let successCommand = SuccessCommand()
        let context = CommandContext()

        // When - Open the circuit
        for _ in 0..<2 {
            _ = try? await middleware.execute(failingCommand, context: context) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Verify circuit is open (blocks requests)
        do {
            _ = try await middleware.execute(successCommand, context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Should block requests when open")
        } catch {
            // Expected - circuit is open
        }

        // Wait for recovery timeout
        try await Task.sleep(nanoseconds: UInt64((recoveryTimeout + 0.05) * 1_000_000_000))

        // Then - Circuit should allow a test request (half-open behavior)
        let result = try await middleware.execute(successCommand, context: context) { cmd, _ in
            try await cmd.execute()
        }

        XCTAssertEqual(result, "Success", "Circuit should allow test request after recovery timeout")
    }

    func testCircuitReclosesAfterSuccessfulRecovery() async throws {
        // Given - Circuit that requires 2 successful requests to close
        let middleware = createMiddleware(
            failureThreshold: 2,
            recoveryTimeout: 0.1,
            halfOpenSuccessThreshold: 2
        )
        let context = CommandContext()

        // Open the circuit
        for _ in 0..<2 {
            _ = try? await middleware.execute(FailingCommand(), context: context) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Wait for recovery timeout
        try await Task.sleep(nanoseconds: 150_000_000)

        // When - Succeed multiple times in half-open state
        for i in 0..<2 {
            let result = try await middleware.execute(SuccessCommand(), context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTAssertEqual(result, "Success", "Request \(i + 1) should succeed in half-open")
        }

        // Then - Circuit should be fully closed (accept all requests)
        for i in 0..<3 {
            let result = try await middleware.execute(SuccessCommand(), context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTAssertEqual(result, "Success", "Circuit should be closed, request \(i + 1) should succeed")
        }
    }

    func testCircuitReopensOnFailureDuringRecovery() async throws {
        // Given - Circuit breaker in recovery
        let middleware = createMiddleware(
            failureThreshold: 2,
            recoveryTimeout: 0.1
        )
        let context = CommandContext()

        // Open the circuit
        for _ in 0..<2 {
            _ = try? await middleware.execute(FailingCommand(), context: context) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Wait for recovery timeout
        try await Task.sleep(nanoseconds: 150_000_000)

        // When - First request after timeout fails (half-open test)
        do {
            _ = try await middleware.execute(FailingCommand(), context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Failing command should fail")
        } catch {
            // Expected - command fails
        }

        // Then - Circuit should immediately reject requests again (reopened)
        do {
            _ = try await middleware.execute(SuccessCommand(), context: context) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Circuit should be open again after failure in half-open")
        } catch {
            // Expected - circuit breaker blocks request
            if case PipelineError.middlewareError(let name, _, _) = error {
                XCTAssertEqual(name, "CircuitBreakerMiddleware")
            }
        }
    }

    // Configuration API changed - successThreshold and sampleSize no longer exist
    // This test needs redesign if those features return
    /*
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
            if i.isMultiple(of: 3) { // ~33% failure rate
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
    */

    // Configuration API changed - failureHandler no longer exists
    // This test needs redesign if failure callback feature returns
    /*
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
    */

    // Configuration API changed - stateChangeHandler and resetTimeout no longer exist
    // This test needs redesign if state change notifications return
    /*
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
    */

    // API changed - getMetrics() method no longer exists
    // This test needs redesign if metrics exposure returns
    /*
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
    */

    func testConcurrentAccess() async throws {
        // Given
        let middleware = createMiddleware(failureThreshold: 10)
        let iterations = 100

        // When - concurrent executions
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    // Handle command types separately to avoid type inference issues
                    if i.isMultiple(of: 3) {
                        // Execute failing command
                        let command = FailingCommand()
                        do {
                            _ = try await middleware.execute(command, context: CommandContext()) { cmd, _ in
                                try await cmd.execute()
                            }
                            return true
                        } catch {
                            return false
                        }
                    } else {
                        // Execute success command
                        let command = SuccessCommand()
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

            // Then - verify we got results from all iterations
            XCTAssertEqual(successes + failures, iterations, "All concurrent tasks should complete")
            // Can't verify exact counts without metrics API, but circuit should handle concurrent access
        }
    }

    // Configuration API changed - fallbackProvider no longer exists
    // This test needs redesign if fallback feature returns
    /*
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
    */
}
