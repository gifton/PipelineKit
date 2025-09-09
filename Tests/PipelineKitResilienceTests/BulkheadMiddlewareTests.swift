import XCTest
import PipelineKitCore
@testable import PipelineKitResilience

final class BulkheadMiddlewareTests: XCTestCase {
    // MARK: - Test Commands

    private struct SlowCommand: Command {
        typealias Result = String
        let id: Int
        let duration: TimeInterval

        func execute() async throws -> String {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            return "Command \(id) completed"
        }
    }

    private struct FastCommand: Command {
        typealias Result = String
        let id: Int

        func execute() async throws -> String {
            "Command \(id) completed"
        }
    }

    private struct FailingCommand: Command {
        typealias Result = String

        func execute() async throws -> String {
            throw TestError.expectedFailure
        }
    }

    private enum TestError: Error {
        case expectedFailure
        case timeout
    }

    // MARK: - Tests

    func testConcurrencyLimiting() async throws {
        // Given - Need to enable queueing for all commands to succeed
        let maxConcurrency = 2
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: maxConcurrency,
                maxQueueSize: 2,  // Allow 2 commands to queue
                rejectionPolicy: .queue
            )
        )

        let commandDuration: TimeInterval = 0.1
        let commands = (0..<4).map { SlowCommand(id: $0, duration: commandDuration) }

        let startTime = Date()

        // When - execute commands concurrently
        let results = await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
            for (index, command) in commands.enumerated() {
                group.addTask {
                    do {
                        let result = try await middleware.execute(command, context: CommandContext()) { cmd, _ in
                            try await cmd.execute()
                        }
                        return (index, .success(result))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            var results: [(Int, Result<String, Error>)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }
        }

        let totalTime = Date().timeIntervalSince(startTime)

        // Then - should take at least 2 batches
        XCTAssertGreaterThanOrEqual(totalTime, commandDuration * 1.8) // Allow some tolerance

        // All commands should succeed
        for (index, result) in results {
            switch result {
            case .success(let value):
                XCTAssertEqual(value, "Command \(index) completed")
            case .failure(let error):
                XCTFail("Command \(index) failed: \(error)")
            }
        }
    }

    func testFailFastRejectionPolicy() async throws {
        // Given
        let middleware = BulkheadMiddleware(
            maxConcurrency: 1,
            maxQueueSize: 0 // No queueing
        )

        // Start a slow command
        let slowTask = Task {
            try await middleware.execute(
                SlowCommand(id: 1, duration: 0.1),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Give it time to acquire the semaphore
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        // When - try another command while first is running
        do {
            _ = try await middleware.execute(
                FastCommand(id: 2),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Expected bulkhead rejection")
        } catch {
            // Then - should be rejected
            if case PipelineError.middlewareError(let middleware, _, _) = error {
                XCTAssertEqual(middleware, "BulkheadMiddleware")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }

        // Cleanup
        _ = try await slowTask.value
    }

    func testQueueingPolicy() async throws {
        // Given
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 1,
                maxQueueSize: 2,
                rejectionPolicy: .queue
            )
        )

        let commandDuration: TimeInterval = 0.05
        let commands = (0..<3).map { SlowCommand(id: $0, duration: commandDuration) }

        let startTime = Date()

        // When - execute 3 commands (1 active, 2 queued)
        let results = await withTaskGroup(of: String?.self) { group in
            for command in commands {
                group.addTask {
                    try? await middleware.execute(command, context: CommandContext()) { cmd, _ in
                        try await cmd.execute()
                    }
                }
            }

            var results: [String] = []
            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
            return results
        }

        let totalTime = Date().timeIntervalSince(startTime)

        // Then - all should complete sequentially
        XCTAssertEqual(results.count, 3)
        XCTAssertGreaterThanOrEqual(totalTime, commandDuration * 2.8) // Sequential execution
    }

    func testQueueTimeout() async throws {
        // Given
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 1,
                maxQueueSize: 1,
                queueTimeout: 0.05, // 50ms timeout
                rejectionPolicy: .queue
            )
        )

        // Start a slow command
        let slowTask = Task {
            try await middleware.execute(
                SlowCommand(id: 1, duration: 0.2), // 200ms
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Give it time to start and acquire the semaphore reliably in CI
        try await Task.sleep(nanoseconds: 30_000_000)

        // When - queue another command that will timeout
        do {
            _ = try await middleware.execute(
                FastCommand(id: 2),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
            XCTFail("Expected timeout")
        } catch {
            // Then - should timeout
            if case PipelineError.middlewareError(_, let message, _) = error {
                XCTAssertTrue(message.contains("timed out"))
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }

        // Cleanup
        _ = try await slowTask.value
    }

    func testFallbackPolicy() async throws {
        // Given
        let fallbackValue = "Fallback response"
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 1,
                rejectionPolicy: .fallback(value: { fallbackValue })
            )
        )

        // Start a slow command
        let slowTask = Task {
            try await middleware.execute(
                SlowCommand(id: 1, duration: 0.1),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Give it time to start
        try await Task.sleep(nanoseconds: 10_000_000)

        // When - execute another command
        let result = try await middleware.execute(
            FastCommand(id: 2),
            context: CommandContext()
        ) { cmd, _ in
            try await cmd.execute()
        }

        // Then - should get fallback value
        XCTAssertEqual(result, fallbackValue)

        // Cleanup
        _ = try await slowTask.value
    }

    func testCustomRejectionPolicy() async throws {
        // Given
        let customResponse = "Custom handled"
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 1,
                rejectionPolicy: .custom(handler: { _ in
                    customResponse
                })
            )
        )

        // Start a slow command
        let slowTask = Task {
            try await middleware.execute(
                SlowCommand(id: 1, duration: 0.1),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Give it time to start
        try await Task.sleep(nanoseconds: 10_000_000)

        // When
        let result = try await middleware.execute(
            FastCommand(id: 2),
            context: CommandContext()
        ) { cmd, _ in
            try await cmd.execute()
        }

        // Then
        XCTAssertEqual(result, customResponse)

        // Cleanup
        _ = try await slowTask.value
    }

    func testMetricsTracking() async throws {
        // Given
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 2,
                maxQueueSize: 1,
                rejectionPolicy: .queue,  // Need queue policy for proper metrics
                emitMetrics: true
            )
        )

        let context = CommandContext()

        // When - execute a command
        _ = try await middleware.execute(FastCommand(id: 1), context: context) { cmd, _ in
            try await cmd.execute()
        }

        // Give time for metrics to be emitted
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        // Then - check metrics
        let metrics = await context.getMetadata()
        XCTAssertNotNil(metrics["bulkhead.duration"])
        XCTAssertEqual(metrics["bulkhead.wasQueued"] as? Bool, false)
        XCTAssertNotNil(metrics["bulkhead.activeCount"])
        XCTAssertNotNil(metrics["bulkhead.queuedCount"])
    }

    func testRejectionHandler() async throws {
        // Given
        let expectation = XCTestExpectation(description: "Rejection handler called")
        actor CommandTracker {
            var rejectedCommand: (any Command)?
            func setRejected(_ cmd: any Command) {
                rejectedCommand = cmd
            }
            func getRejected() -> (any Command)? {
                return rejectedCommand
            }
        }
        let tracker = CommandTracker()

        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 1,
                rejectionHandler: { command, _ in
                    Task { await tracker.setRejected(command) }
                    expectation.fulfill()
                }
            )
        )

        // Start a slow command
        let slowTask = Task {
            try await middleware.execute(
                SlowCommand(id: 1, duration: 0.1),
                context: CommandContext()
            ) { cmd, _ in
                try await cmd.execute()
            }
        }

        // Give it time to start
        try await Task.sleep(nanoseconds: 10_000_000)

        // When - try to execute another
        _ = try? await middleware.execute(
            FastCommand(id: 2),
            context: CommandContext()
        ) { cmd, _ in
            try await cmd.execute()
        }

        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        let rejectedCommand = await tracker.getRejected()
        XCTAssertNotNil(rejectedCommand)
        XCTAssertTrue(rejectedCommand is FastCommand)

        // Cleanup
        _ = try await slowTask.value
    }

    func testHighConcurrencyStress() async throws {
        // Given
        let middleware = BulkheadMiddleware(
            configuration: BulkheadMiddleware.Configuration(
                maxConcurrency: 10,
                maxQueueSize: 90,  // Need to queue up to 90 commands for 100 total
                rejectionPolicy: .queue
            )
        )

        let commandCount = 100
        let commands = (0..<commandCount).map { FastCommand(id: $0) }

        // When - execute many commands concurrently
        let results = await withTaskGroup(of: Result<String, Error>.self) { group in
            for command in commands {
                group.addTask {
                    do {
                        let result = try await middleware.execute(command, context: CommandContext()) { cmd, _ in
                            // Add small random delay
                            try await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...10_000_000))
                            return try await cmd.execute()
                        }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var results: [Result<String, Error>] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        // Then - all should complete
        var successCount = 0
        var failureCount = 0

        for result in results {
            switch result {
            case .success:
                successCount += 1
            case .failure:
                failureCount += 1
            }
        }

        XCTAssertEqual(successCount, commandCount)
        XCTAssertEqual(failureCount, 0)
    }
}
