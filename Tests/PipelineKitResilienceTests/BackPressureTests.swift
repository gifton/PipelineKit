import XCTest
@testable import PipelineKit
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
    
    // MARK: - BackPressureAsyncSemaphore Tests
    
    func testSemaphoreBasicAcquisition() async throws {
        let semaphore = BackPressureAsyncSemaphore(
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
        let semaphore = BackPressureAsyncSemaphore(
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
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .suspend
        )
        
        // Acquire the only resource
        _ = try await semaphore.acquire()
        
        // Try to acquire with timeout - should timeout
        let startTime = Date()
        
        do {
            _ = try await semaphore.acquire(timeout: 0.1)
            XCTFail("Expected timeout")
        } catch let error as PipelineError {
            let elapsed = Date().timeIntervalSince(startTime)
            XCTAssertGreaterThan(elapsed, 0.1)
            
            if case .backPressure(let reason) = error,
               case .timeout = reason {
                // Success
            } else {
                XCTFail("Expected timeout error, got \(error)")
            }
        }
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
            _ = try await pipeline.execute(TestSlowCommand(duration: 0.1))
            XCTFail("Expected back pressure error")
        } catch let error as PipelineError {
            if case .backPressure = error {
                // Success
            } else {
                XCTFail("Expected backPressure error, got \(error)")
            }
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
        let result = try await backPressureMiddleware.execute(
            BackPressureTestCommand(value: "test"),
            context: CommandContext(),
            estimatedSize: 512
        ) { command, _ in
            try await handler.handle(command)
        }
        
        XCTAssertEqual(result, "Handled: test")
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
    
    func handle(_ command: BackPressureTestCommand) async throws -> String {
        return "Handled: \(command.value)"
    }
}

private struct TestSlowHandler: CommandHandler {
    typealias CommandType = TestSlowCommand
    
    func handle(_ command: TestSlowCommand) async throws -> String {
        // Simulate command duration by yielding
        await Task.yield()
        await Task.yield()
        return "Processed slow command"
    }
}
