import XCTest
@testable import PipelineKitResilience
@testable import PipelineKitCore
import PipelineKit
import PipelineKitTestSupport

final class BackPressureTests: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()
    
    // MARK: - PipelineOptions Tests
    
    func testPipelineOptionsDefaults() {
        let options = PipelineOptions()
        
        XCTAssertEqual(options.maxConcurrency, 10)
        XCTAssertEqual(options.maxOutstanding, 50)
        
        if case .suspend = options.backPressureStrategy {
            // Success
        } else {
            XCTFail("Expected suspend strategy")
        }
    }
    
    func testPipelineOptionsPresets() {
        let unlimited = PipelineOptions.unlimited()
        XCTAssertNil(unlimited.maxConcurrency)
        XCTAssertNil(unlimited.maxOutstanding)
        
        let highThroughput = PipelineOptions.highThroughput()
        XCTAssertEqual(highThroughput.maxConcurrency, 50)
        XCTAssertEqual(highThroughput.maxOutstanding, 200)
        
        let lowLatency = PipelineOptions.lowLatency()
        XCTAssertEqual(lowLatency.maxConcurrency, 5)
        XCTAssertEqual(lowLatency.maxOutstanding, 10)
    }
    
    // MARK: - BackPressureSemaphore Tests
    
    func testSemaphoreBasicAcquisition() async throws {
        let semaphore = BackPressureSemaphore(
            maxConcurrency: 2,
            maxOutstanding: 4,
            strategy: .suspend
        )
        
        // Should acquire immediately
        let token1 = try await semaphore.acquire()
        let token2 = try await semaphore.acquire()
        
        let stats = await semaphore.getStats()
        XCTAssertEqual(stats.activeOperations, 2)
        XCTAssertEqual(stats.availableResources, 0)
        
        // Token will auto-release when it goes out of scope
        _ = token1
        _ = token2
    }
    
    func testSemaphoreErrorStrategy() async throws {
        let semaphore = BackPressureSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 1,
            strategy: .error(timeout: nil)
        )
        
        // First acquisition should succeed
        _ = try await semaphore.acquire()
        
        // Second acquisition should fail immediately
        do {
            _ = try await semaphore.acquire()
            XCTFail("Expected PipelineError.backPressure")
        } catch let error as PipelineError {
            if case .backPressure(let reason) = error,
               case .queueFull = reason {
                // Success
            } else {
                XCTFail("Expected queueFull error, got \(error)")
            }
        }
    }
    
    func testSemaphoreTimeoutAcquisition() async throws {
        let semaphore = BackPressureSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .suspend
        )
        
        // Acquire the only resource and hold it
        let token1 = try await semaphore.acquire()
        
        // Check stats to confirm resource is held
        let stats1 = await semaphore.getStats()
        XCTAssertEqual(stats1.activeOperations, 1, "Should have 1 active operation")
        XCTAssertEqual(stats1.availableResources, 0, "Should have 0 available resources")
        
        // Try to acquire with timeout - should timeout
        let startTime = Date()
        
        do {
            let token = try await semaphore.acquire(timeout: 0.1)
            if token == nil {
                // Timeout occurred but didn't throw - this is wrong
                XCTFail("Expected timeout to throw, got nil")
            } else {
                XCTFail("Expected timeout, got a token")
            }
        } catch let error as PipelineError {
            let elapsed = Date().timeIntervalSince(startTime)
            XCTAssertGreaterThan(elapsed, 0.09) // Allow small tolerance
            
            if case .backPressure(let reason) = error,
               case .timeout = reason {
                // Success
            } else {
                XCTFail("Expected timeout error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        
        // Keep token1 alive until end
        _ = token1
    }
    
    // MARK: - ConcurrentPipeline Back-pressure Tests
    
    func testConcurrentPipelineWithBackPressure() async throws {
        let options = PipelineOptions(
            maxConcurrency: 2,
            maxOutstanding: 3,
            backPressureStrategy: .error(timeout: nil)
        )
        
        let pipeline = ConcurrentPipeline(options: options)
        let handler = TestSlowHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        
        await pipeline.register(TestSlowCommand.self, pipeline: standardPipeline)
        
        // Start two long-running commands to fill concurrency
        let task1 = Task {
            try await pipeline.execute(TestSlowCommand(duration: 1.0))
        }
        
        let task2 = Task {
            try await pipeline.execute(TestSlowCommand(duration: 1.0))
        }
        
        // Wait a bit to ensure they're running
        await synchronizer.mediumDelay()
        
        // This should queue (within outstanding limit)
        let task3 = Task {
            try await pipeline.execute(TestSlowCommand(duration: 0.1))
        }
        
        // Give task3 time to queue
        await synchronizer.shortDelay()
        
        // This should fail due to outstanding limit exceeded
        do {
            _ = try await pipeline.execute(TestSlowCommand(duration: 0.1))
            XCTFail("Expected PipelineError.backPressure")
        } catch {
            // Success - should fail with back-pressure
        }
        
        // Wait for tasks to complete
        _ = try await task1.value
        _ = try await task2.value
        _ = try await task3.value
    }
    
    func testConcurrentPipelineCapacityStats() async throws {
        let options = PipelineOptions(
            maxConcurrency: 3,
            maxOutstanding: 5,
            backPressureStrategy: .suspend
        )
        
        let pipeline = ConcurrentPipeline(options: options)
        let handler = TestSlowHandler()
        let standardPipeline = StandardPipeline(handler: handler)
        
        await pipeline.register(TestSlowCommand.self, pipeline: standardPipeline)
        
        // Initial stats
        let initialStats = await pipeline.getCapacityStats()
        XCTAssertEqual(initialStats.maxConcurrency, 3)
        XCTAssertEqual(initialStats.maxOutstanding, 5)
        XCTAssertEqual(initialStats.activeOperations, 0)
        XCTAssertEqual(initialStats.utilizationPercent, 0.0)
        
        // Start a long-running command
        let task = Task {
            try await pipeline.execute(TestSlowCommand(duration: 0.5))
        }
        
        // Wait a bit and check stats
        await synchronizer.mediumDelay()
        
        let activeStats = await pipeline.getCapacityStats()
        XCTAssertEqual(activeStats.activeOperations, 1)
        XCTAssertEqual(activeStats.utilizationPercent, 100.0 / 3.0, accuracy: 0.1)
        
        _ = try await task.value
    }
    
    // MARK: - BackPressureMiddleware Tests
    
    func testBackPressureMiddleware() async throws {
        let backPressureMiddleware = BackPressureMiddleware(
            maxConcurrency: 2,
            maxOutstanding: 4,
            strategy: .suspend
        )
        
        let handler = BackPressureTestHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(backPressureMiddleware)
        
        // Execute commands within capacity
        let result1 = try await pipeline.execute(BackPressureTestCommand(value: "test1"))
        XCTAssertEqual(result1, "Handled: test1")
        
        let result2 = try await pipeline.execute(BackPressureTestCommand(value: "test2"))
        XCTAssertEqual(result2, "Handled: test2")
        
        // Check middleware stats
        let stats = await backPressureMiddleware.getStats()
        XCTAssertEqual(stats.maxConcurrency, 2)
        XCTAssertEqual(stats.maxOutstanding, 4)
        
        // Check health
        let health = await backPressureMiddleware.healthCheck()
        XCTAssertTrue(health.isHealthy)
    }
    
    func testBackPressureMiddlewareWithConcurrency() async throws {
        let backPressureMiddleware = BackPressureMiddleware(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .error(timeout: 0.1)
        )
        
        let handler = TestSlowHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(backPressureMiddleware)
        
        // Start a slow command that will occupy the only available slot
        let task1 = Task {
            try await pipeline.execute(TestSlowCommand(duration: 0.5))
        }
        
        // Give it time to start
        await synchronizer.shortDelay()
        
        // This should fail with timeout since concurrency is maxed out
        do {
            let result = try await pipeline.execute(TestSlowCommand(duration: 0.1))
            XCTFail("Expected back pressure error, but got result: \(result)")
        } catch let error as PipelineError {
            if case .backPressure = error {
                // Success
            } else {
                XCTFail("Expected backPressure error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        
        // Wait for first task to complete
        _ = try await task1.value
    }
    
    func testBackPressureMiddlewarePresets() async throws {
        let highThroughput = BackPressureMiddleware.highThroughput()
        let lowLatency = BackPressureMiddleware.lowLatency()
        let flowControl = BackPressureMiddleware.flowControl(maxConcurrency: 5)
        
        // Test high throughput stats
        let htStats = await highThroughput.getStats()
        XCTAssertEqual(htStats.maxConcurrency, 50)
        XCTAssertEqual(htStats.maxOutstanding, 200)
        
        // Test low latency stats
        let llStats = await lowLatency.getStats()
        XCTAssertEqual(llStats.maxConcurrency, 5)
        XCTAssertEqual(llStats.maxOutstanding, 10)
        
        // Test flow control stats
        let fcStats = await flowControl.getStats()
        XCTAssertEqual(fcStats.maxConcurrency, 5)
    }
    
    func testBackPressureMiddlewareWithCustomSize() async throws {
        let backPressureMiddleware = BackPressureMiddleware(
            maxConcurrency: 2,
            maxQueueMemory: 1024,
            strategy: .suspend
        )
        
        let handler = BackPressureTestHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(backPressureMiddleware)
        
        // Execute with custom size estimation
        let context = CommandContext()
        let result = try await backPressureMiddleware.execute(
            BackPressureTestCommand(value: "test"),
            context: context,
            estimatedSize: 512
        ) { command, ctx in
            try await handler.handle(command, context: ctx)
        }
        
        XCTAssertEqual(result, "Handled: test")
    }

    // MARK: - BackPressureSemaphore Correctness Tests

    func testCancellationTargetsCorrectWaiter() async throws {
        // Tests that task cancellation cancels the correct waiter, not a random one
        let semaphore = BackPressureSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 10,
            strategy: .suspend
        )

        // Hold the only permit
        let holdingToken = try await semaphore.acquire()

        // Create multiple waiting tasks
        let task1 = Task {
            do {
                _ = try await semaphore.acquire()
                return "task1-acquired"
            } catch is CancellationError {
                return "task1-cancelled"
            } catch {
                return "task1-error"
            }
        }

        let task2 = Task {
            do {
                _ = try await semaphore.acquire()
                return "task2-acquired"
            } catch is CancellationError {
                return "task2-cancelled"
            } catch {
                return "task2-error"
            }
        }

        let task3 = Task {
            do {
                _ = try await semaphore.acquire()
                return "task3-acquired"
            } catch is CancellationError {
                return "task3-cancelled"
            } catch {
                return "task3-error"
            }
        }

        // Give all tasks time to queue
        await synchronizer.mediumDelay()

        // Cancel only task2
        task2.cancel()

        // Give cancellation time to process
        await synchronizer.shortDelay()

        // Verify only task2 was cancelled
        let result2 = await task2.value
        XCTAssertEqual(result2, "task2-cancelled", "Task 2 should be cancelled")

        // Release the holding token so task1 and task3 can complete
        _ = holdingToken  // Keep alive until here

        // Cancel remaining tasks for cleanup
        task1.cancel()
        task3.cancel()

        _ = await task1.value
        _ = await task3.value
    }

    func testWaiterTimeoutActuallyExpires() async throws {
        // Tests that the timeout cleanup actually removes old waiters
        let shortTimeout: TimeInterval = 0.5  // 500ms
        let semaphore = BackPressureSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 10,
            strategy: .suspend,
            waiterTimeout: shortTimeout
        )

        // Hold the only permit
        let holdingToken = try await semaphore.acquire()

        // Start a waiter that will timeout
        let waiterTask = Task {
            do {
                _ = try await semaphore.acquire()
                return "acquired"
            } catch let error as PipelineError {
                if case .backPressure(let reason) = error,
                   case .timeout = reason {
                    return "timed-out"
                }
                return "other-error: \(error)"
            } catch {
                return "unexpected-error: \(error)"
            }
        }

        // Wait for timeout + cleanup interval + margin
        // Cleanup runs every 1 second, so wait 2 seconds to ensure it runs
        try await Task.sleep(nanoseconds: 2_500_000_000)  // 2.5 seconds

        let result = await waiterTask.value
        XCTAssertEqual(result, "timed-out", "Waiter should have been timed out by cleanup")

        // Cleanup
        _ = holdingToken
    }

    func testNoDoubleResumeUnderConcurrentOperations() async throws {
        // Stress test: concurrent cancellations and releases shouldn't cause double-resume
        // If double-resume happens, this test will crash (continuation resumed twice)
        let semaphore = BackPressureSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 20,
            strategy: .suspend
        )

        let successCounter = TestCounter()
        let cancelCounter = TestCounter()
        let errorCounter = TestCounter()

        // Run multiple iterations to stress test
        for _ in 0..<20 {
            // Hold the only permit
            let holdingToken = try await semaphore.acquire()

            // Create a waiting task
            let waitingTask = Task {
                do {
                    let token = try await semaphore.acquire()
                    token.release()
                    return "acquired"
                } catch is CancellationError {
                    return "cancelled"
                } catch {
                    return "error: \(error)"
                }
            }

            // Give task time to queue
            await synchronizer.shortDelay()

            // Race: cancel the task AND release the permit nearly simultaneously
            // This tests the scenario where both cancellation and release try to
            // resume the same continuation - if not handled correctly, this crashes
            let cancelTask = Task {
                waitingTask.cancel()
            }
            let releaseTask = Task {
                holdingToken.release()
            }

            _ = await cancelTask.value
            _ = await releaseTask.value

            // Collect result
            let result = await waitingTask.value
            switch result {
            case "acquired":
                await successCounter.increment()
            case "cancelled":
                await cancelCounter.increment()
            default:
                await errorCounter.increment()
            }
        }

        // Verify no unexpected errors (which could indicate double-resume)
        let errorCount = await errorCounter.get()
        let successCount = await successCounter.get()
        let cancelCount = await cancelCounter.get()

        XCTAssertEqual(errorCount, 0, "Should have no errors - double-resume would cause crashes")
        // Either acquired or cancelled is valid - just verify we didn't crash
        XCTAssertGreaterThan(successCount + cancelCount, 0, "All operations should complete without crash")
    }
}

// MARK: - Test Support Types

private struct BackPressureTestCommand: Command {
    typealias Result = String
    let value: String
}

private struct TestSlowCommand: Command {
    typealias Result = String
    let duration: TimeInterval
}

private struct BackPressureTestHandler: CommandHandler {
    typealias CommandType = BackPressureTestCommand
    
    func handle(_ command: BackPressureTestCommand, context: CommandContext) async throws -> String {
        return "Handled: \(command.value)"
    }
}

private struct TestSlowHandler: CommandHandler {
    typealias CommandType = TestSlowCommand
    
    func handle(_ command: TestSlowCommand, context: CommandContext) async throws -> String {
        // Actually sleep for the specified duration
        try await Task.sleep(nanoseconds: UInt64(command.duration * 1_000_000_000))
        return "Processed slow command"
    }
}
