import XCTest
import Foundation
@testable import PipelineKit

final class BackPressureMiddlewareTestsV2: XCTestCase {
    
    func testSuccessfulExecutionUnderLimit() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 3
        )
        
        let command = BPTestCommand(value: "test")
        let context = CommandContext()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            // Simulate some work
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            return cmd.value
        }
        
        // Then
        XCTAssertEqual(result, "test")
        
        // Verify stats
        let stats = await middleware.getStats()
        XCTAssertEqual(stats.maxConcurrency, 3)
    }
    
    func testBackPressureWithConcurrentRequests() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 2,
            maxOutstanding: 5
        )
        
        let executionOrder = ExecutionTracker()
        
        // When - Execute 5 commands with limit of 2
        let tasks = (0..<5).map { i in
            Task {
                let command = BPTestCommand(value: "test-\(i)")
                let context = CommandContext()
                
                return try await middleware.execute(command, context: context) { cmd, _ in
                    await executionOrder.append(i)
                    
                    // Hold the semaphore for a bit
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    return cmd.value
                }
            }
        }
        
        // Then - All should complete
        for (i, task) in tasks.enumerated() {
            let result = try await task.value
            XCTAssertEqual(result, "test-\(i)")
        }
        
        // Verify that all commands executed
        let count = await executionOrder.getCount()
        XCTAssertEqual(count, 5)
    }
    
    func testBackPressureRejection() async throws {
        // Given - Low maxOutstanding to trigger rejection
        let middleware = BackPressureMiddleware(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .dropNewest
        )
        
        // Block the semaphore with a long-running task
        let blockingTask = Task {
            let command = BPTestCommand(value: "blocking")
            let context = CommandContext()
            
            return try await middleware.execute(command, context: context) { cmd, _ in
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                return cmd.value
            }
        }
        
        // Try to queue more than maxOutstanding
        let rejectedTracker = ExecutionTracker()
        let tasks = (0..<3).map { i in
            Task {
                let command = BPTestCommand(value: "test-\(i)")
                let context = CommandContext()
                
                do {
                    return try await middleware.execute(command, context: context) { cmd, _ in
                        cmd.value
                    }
                } catch {
                    await rejectedTracker.append(i)
                    return "rejected"
                }
            }
        }
        
        // Give tasks time to attempt execution
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        // Cancel blocking task
        blockingTask.cancel()
        
        // Wait for all tasks
        for task in tasks {
            _ = await task.value
        }
        
        // At least one should have been rejected
        let rejectedCount = await rejectedTracker.getCount()
        XCTAssertGreaterThan(rejectedCount, 0)
    }
    
    func testBackPressurePriority() {
        let middleware = BackPressureMiddleware(maxConcurrency: 1)
        XCTAssertEqual(middleware.priority, .throttling)
    }
    
    func testBackPressureWithFailure() async throws {
        // Given
        let middleware = BackPressureMiddleware(maxConcurrency: 2)
        
        let command = BPTestCommand(value: "fail")
        let context = CommandContext()
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                throw BPTestError.intentionalFailure
            }
            XCTFail("Should have thrown error")
        } catch {
            // Expected
        }
        
        // Verify stats - semaphore should be released after failure
        let stats = await middleware.getStats()
        XCTAssertLessThanOrEqual(stats.activeOperations, stats.maxConcurrency)
    }
    
    func testBackPressureStats() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 3,
            maxOutstanding: 10
        )
        
        // Initial stats
        let initialStats = await middleware.getStats()
        XCTAssertEqual(initialStats.maxConcurrency, 3)
        XCTAssertEqual(initialStats.maxOutstanding, 10)
        XCTAssertEqual(initialStats.activeOperations, 0)
        XCTAssertEqual(initialStats.queuedOperations, 0)
        
        // When - Start multiple executions
        let task1 = Task {
            let command = BPTestCommand(value: "1")
            let context = CommandContext()
            return try await middleware.execute(command, context: context) { cmd, _ in
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                return cmd.value
            }
        }
        
        let task2 = Task {
            let command = BPTestCommand(value: "2")
            let context = CommandContext()
            return try await middleware.execute(command, context: context) { cmd, _ in
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                return cmd.value
            }
        }
        
        // Give tasks time to acquire semaphore
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        // Check stats during execution
        let duringStats = await middleware.getStats()
        XCTAssertGreaterThan(duringStats.activeOperations, 0)
        
        // Wait for completion
        _ = try await task1.value
        _ = try await task2.value
        
        // Final stats should show resources released
        let finalStats = await middleware.getStats()
        XCTAssertEqual(finalStats.activeOperations, 0)
    }
    
    func testConcurrentStressTest() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 5,
            maxOutstanding: 60
        )
        
        // When - Execute many commands concurrently
        let commandCount = 50
        let tasks = (0..<commandCount).map { i in
            Task {
                let command = BPTestCommand(value: "stress-\(i)")
                let context = CommandContext()
                
                return try await middleware.execute(command, context: context) { cmd, _ in
                    // Random work duration
                    let sleepTime = UInt64.random(in: 1_000_000...10_000_000) // 1-10ms
                    try await Task.sleep(nanoseconds: sleepTime)
                    return cmd.value
                }
            }
        }
        
        // Then - All should complete without errors
        for (i, task) in tasks.enumerated() {
            let result = try await task.value
            XCTAssertEqual(result, "stress-\(i)")
        }
        
        // Verify final state
        let finalStats = await middleware.getStats()
        XCTAssertEqual(finalStats.activeOperations, 0)
        XCTAssertEqual(finalStats.queuedOperations, 0)
    }
}

// Test support types
private struct BPTestCommand: Command {
    typealias Result = String
    let value: String
    
    func execute() async throws -> String {
        return value
    }
}

private enum BPTestError: Error {
    case intentionalFailure
}

// Helper actor to track concurrent executions
private actor ExecutionTracker {
    private var executionOrder: [Int] = []
    
    func append(_ value: Int) {
        executionOrder.append(value)
    }
    
    func getCount() -> Int {
        return executionOrder.count
    }
    
    func getOrder() -> [Int] {
        return executionOrder
    }
}