import XCTest
@testable import PipelineKit

final class BackPressureTests: XCTestCase {
    
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
            XCTFail("Expected BackPressureError")
        } catch let error as BackPressureError {
            if case .queueFull = error {
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
        } catch let error as BackPressureError {
            let elapsed = Date().timeIntervalSince(startTime)
            XCTAssertGreaterThan(elapsed, 0.1)
            
            if case .timeout = error {
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
        let standardPipeline = DefaultPipeline(handler: handler)
        
        await pipeline.register(TestSlowCommand.self, pipeline: standardPipeline)
        
        // Start two long-running commands to fill concurrency
        let task1 = Task {
            try await pipeline.execute(TestSlowCommand(duration: 1.0))
        }
        
        let task2 = Task {
            try await pipeline.execute(TestSlowCommand(duration: 1.0))
        }
        
        // Wait a bit to ensure they're running
        try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        
        // This should queue (within outstanding limit)
        let task3 = Task {
            try await pipeline.execute(TestSlowCommand(duration: 0.1))
        }
        
        // This should fail due to outstanding limit exceeded
        do {
            let _ = try await pipeline.execute(TestSlowCommand(duration: 0.1))
            XCTFail("Expected BackPressureError")
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
        let standardPipeline = DefaultPipeline(handler: handler)
        
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
        try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        
        let activeStats = await pipeline.getCapacityStats()
        XCTAssertEqual(activeStats.activeOperations, 1)
        XCTAssertEqual(activeStats.utilizationPercent, 100.0 / 3.0, accuracy: 0.1)
        
        _ = try await task.value
    }
    
    // MARK: - BackPressureMiddleware Tests
    
    func testBackPressureMiddleware() async throws {
        let handler = TestHandler()
        let pipeline = PriorityPipeline(handler: handler)
        
        let backPressureMiddleware = BackPressureMiddleware(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .error(timeout: nil)
        )
        
        try await pipeline.addMiddleware(
            backPressureMiddleware,
            priority: ExecutionPriority.throttling.rawValue
        )
        
        // First command should succeed
        let result1 = try await pipeline.execute(
            TestCommand(value: "test1"),
            metadata: DefaultCommandMetadata()
        )
        XCTAssertEqual(result1, "Handled: test1")
        
        // Start a slow command to block the middleware
        Task {
            let slowHandler = TestSlowHandler()
            let slowPipeline = PriorityPipeline(handler: slowHandler)
            
            try await slowPipeline.addMiddleware(
                backPressureMiddleware,
                priority: ExecutionPriority.throttling.rawValue
            )
            
            return try await slowPipeline.execute(
                TestSlowCommand(duration: 0.5),
                metadata: DefaultCommandMetadata()
            )
        }
        
        // Wait a bit
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Get middleware stats
        let stats = await backPressureMiddleware.getStats()
        XCTAssertGreaterThan(stats.activeOperations, 0)
    }
    
    func testBackPressureMiddlewarePresets() {
        let highThroughput = BackPressureMiddleware.highThroughput()
        let lowLatency = BackPressureMiddleware.lowLatency()
        let _ = BackPressureMiddleware.flowControl(maxConcurrency: 5)
        
        XCTAssertEqual(highThroughput.options.maxConcurrency, 50)
        XCTAssertEqual(lowLatency.options.maxConcurrency, 5)
        // Flow control middleware should have appropriate settings
    }
}

// MARK: - Test Support Types

private struct TestCommand: Command {
    typealias Result = String
    let value: String
}

private struct TestSlowCommand: Command {
    typealias Result = String
    let duration: TimeInterval
}

private struct TestHandler: CommandHandler {
    func handle(_ command: TestCommand) async throws -> String {
        return "Handled: \(command.value)"
    }
}

private struct TestSlowHandler: CommandHandler {
    func handle(_ command: TestSlowCommand) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(command.duration * 1_000_000_000))
        return "Processed slow command"
    }
}
