import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience

final class TimeoutMiddlewareEnhancedTests: XCTestCase {

    // MARK: - Grace Period Tests

    func testGracePeriodAllowsCompletionAfterInitialTimeout() async throws {
        let middleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 0.1,
                gracePeriod: 0.2
            )
        )

        let command = SlowCommand(duration: 0.15) // Exceeds timeout but within grace period
        let context = CommandContext()

        let result = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }

        XCTAssertEqual(result, "completed")
    }

    func testGracePeriodExpirationThrowsError() async throws {
        let middleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 0.1,
                gracePeriod: 0.1
            )
        )

        let command = SlowCommand(duration: 0.25) // Exceeds both timeout and grace period
        let context = CommandContext()

        do {
            _ = try await middleware.execute(command, context: context) { cmd, ctx in
                try await cmd.execute()
            }
            XCTFail("Should have thrown timeout error")
        } catch let error as PipelineError {
            guard case .timeoutWithContext(let timeoutContext) = error else {
                XCTFail("Wrong error type: \(error)")
                return
            }

            XCTAssertTrue(timeoutContext.gracePeriodUsed)
            XCTAssertEqual(timeoutContext.reason, .gracePeriodExpired)
        }
    }

    func testGracePeriodStateTracking() async throws {
        let stateTracker = TimeoutStateTracker()
        let gracePeriodManager = GracePeriodManager()

        let middleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 0.1,
                gracePeriod: 0.2,
                emitEvents: true
            )
        )

        let command = SlowCommand(duration: 0.15)
        let context = CommandContext()
        var gracePeriodStarted = false

        // Monitor events
        let eventExpectation = expectation(description: "Grace period event")
        context.observabilityStream.sink { event in
            if event.name == "command_grace_period_started" {
                gracePeriodStarted = true
                eventExpectation.fulfill()
            }
        }

        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }

        await fulfillment(of: [eventExpectation], timeout: 1.0)
        XCTAssertTrue(gracePeriodStarted)
    }

    // MARK: - Metrics Collection Tests

    func testTimeoutMetricsCollection() async throws {
        let collector = StandardMetricsCollector()
        let middleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 0.1,
                metricsCollector: collector
            )
        )

        let command = SlowCommand(duration: 0.2)
        let context = CommandContext()

        // Execute and expect timeout
        do {
            _ = try await middleware.execute(command, context: context) { cmd, ctx in
                try await cmd.execute()
            }
        } catch {
            // Expected timeout
        }

        // Check metrics
        let metrics = await collector.getMetrics()
        let timeoutMetrics = metrics.filter { $0.name.contains("timeout") }

        XCTAssertFalse(timeoutMetrics.isEmpty)
        XCTAssertTrue(timeoutMetrics.contains { $0.name.contains("command.timeout") })
    }

    func testNearTimeoutMetrics() async throws {
        let collector = StandardMetricsCollector()
        let middleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 0.2,
                metricsCollector: collector
            )
        )

        let command = SlowCommand(duration: 0.19) // 95% of timeout
        let context = CommandContext()

        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }

        // Check for near-timeout metrics
        let metrics = await collector.getMetrics()
        let nearTimeoutMetrics = metrics.filter { $0.name.contains("near_timeout") }

        XCTAssertFalse(nearTimeoutMetrics.isEmpty)
    }

    func testTimeoutRecoveryMetrics() async throws {
        let collector = StandardMetricsCollector()
        let middleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 0.1,
                gracePeriod: 0.2,
                metricsCollector: collector
            )
        )

        let command = SlowCommand(duration: 0.15) // Will recover in grace period
        let context = CommandContext()

        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }

        // Check for recovery metrics
        let adapter = await collector.asTimeoutMetricsCollector()
        // This would require extending the test to check internal state
    }

    // MARK: - Custom Timeout Configuration Tests

    func testCommandSpecificTimeout() async throws {
        let middleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 1.0,
                commandTimeouts: ["ConfigurableTimeoutCommand": 0.1]
            )
        )

        let command = ConfigurableTimeoutCommand(duration: 0.2)
        let context = CommandContext()

        do {
            _ = try await middleware.execute(command, context: context) { cmd, ctx in
                try await cmd.execute()
            }
            XCTFail("Should have timed out with command-specific timeout")
        } catch {
            // Expected timeout
        }
    }

    func testTimeoutConfigurableProtocol() async throws {
        let middleware = TimeoutMiddleware(defaultTimeout: 1.0)

        let command = TimeoutConfigurableCommand(
            duration: 0.2,
            configuredTimeout: 0.1
        )
        let context = CommandContext()

        do {
            _ = try await middleware.execute(command, context: context) { cmd, ctx in
                try await cmd.execute()
            }
            XCTFail("Should have timed out with protocol-configured timeout")
        } catch {
            // Expected timeout
        }
    }

    func testCustomTimeoutResolver() async throws {
        let middleware = TimeoutMiddleware(
            defaultTimeout: 1.0,
            timeoutResolver: { command in
                // Custom logic based on command type
                if command is SlowCommand {
                    return 0.1
                }
                return nil
            }
        )

        let command = SlowCommand(duration: 0.2)
        let context = CommandContext()

        do {
            _ = try await middleware.execute(command, context: context) { cmd, ctx in
                try await cmd.execute()
            }
            XCTFail("Should have timed out with resolver timeout")
        } catch {
            // Expected timeout
        }
    }

    // MARK: - Cancellation Tests

    func testCooperativeCancellation() async throws {
        let middleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 0.1,
                cancelOnTimeout: true
            )
        )

        let command = CancellationAwareCommand()
        let context = CommandContext()

        do {
            _ = try await middleware.execute(command, context: context) { cmd, ctx in
                try await cmd.execute()
            }
            XCTFail("Should have timed out")
        } catch {
            // Check that cancellation was requested
            XCTAssertTrue(command.wasCancelled)
        }
    }

    func testNonCancellationMode() async throws {
        let middleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 0.1,
                cancelOnTimeout: false
            )
        )

        let command = CancellationAwareCommand()
        let context = CommandContext()

        do {
            _ = try await middleware.execute(command, context: context) { cmd, ctx in
                try await cmd.execute()
            }
            XCTFail("Should have timed out")
        } catch {
            // Cancellation should not have been requested
            XCTAssertFalse(command.wasCancelled)
        }
    }

    // MARK: - Edge Cases

    func testZeroTimeout() async throws {
        let middleware = TimeoutMiddleware(defaultTimeout: 0.0)

        let command = InstantCommand()
        let context = CommandContext()

        do {
            _ = try await middleware.execute(command, context: context) { cmd, ctx in
                try await cmd.execute()
            }
            XCTFail("Should have timed out immediately")
        } catch {
            // Expected timeout
        }
    }

    func testVeryLongTimeout() async throws {
        let middleware = TimeoutMiddleware(defaultTimeout: 10.0)

        let command = InstantCommand()
        let context = CommandContext()

        let result = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }

        XCTAssertEqual(result, "instant")
    }

    func testConcurrentTimeouts() async throws {
        let middleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 0.1,
                gracePeriod: 0.1
            )
        )

        let context = CommandContext()

        // Run multiple commands concurrently
        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let command = SlowCommand(
                        duration: Double(i) * 0.05,
                        identifier: i
                    )

                    do {
                        _ = try await middleware.execute(command, context: context) { cmd, ctx in
                            try await cmd.execute()
                        }
                    } catch {
                        // Some will timeout, some won't
                    }
                }
            }
        }
    }
}

// MARK: - Test Commands

private struct SlowCommand: Command {
    typealias Result = String

    let duration: TimeInterval
    let identifier: Int = 0

    func execute() async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        return "completed"
    }
}

private struct InstantCommand: Command {
    typealias Result = String

    func execute() async throws -> String {
        return "instant"
    }
}

private struct ConfigurableTimeoutCommand: Command {
    typealias Result = String

    let duration: TimeInterval

    func execute() async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        return "completed"
    }
}

private struct TimeoutConfigurableCommand: Command, TimeoutConfigurable {
    let duration: TimeInterval
    let configuredTimeout: TimeInterval

    var timeout: TimeInterval {
        configuredTimeout
    }

    func execute() async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        return "completed"
    }
}

private final class CancellationAwareCommand: Command {
    var wasCancelled = false

    func execute() async throws -> String {
        // Check for cancellation periodically
        for _ in 0..<10 {
            if Task.isCancelled {
                wasCancelled = true
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        return "completed"
    }
}

