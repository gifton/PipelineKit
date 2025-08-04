import XCTest
import Foundation
@testable import PipelineKit
import PipelineKitTests

final class BackPressureMiddlewareTests: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()
    
    func testSuccessfulExecutionUnderLimit() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 3
        )
        
        let command = BPTestCommand(value: "test")
        let context = CommandContext()
        let workSimulator = TestSynchronizer()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, _ in
            // Simulate work without actual delay
            await workSimulator.signal("work-started")
            let result = cmd.value
            await workSimulator.wait(for: "work-completed")
            return result
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
                    await self.synchronizer.mediumDelay()
                    
                    await executionOrder.append(i + 100) // Mark completion
                    return cmd.value
                }
            }
        }
        
        // Wait for all
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for task in tasks {
                group.addTask {
                    try await task.value
                }
            }
            
            var collected: [String] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }
        
        // Then
        XCTAssertEqual(results.count, 5)
        
        // Verify concurrent execution was limited
        let order = await executionOrder.getOrder()
        
        // Check that at most 2 were executing at any time
        var concurrent = 0
        var maxConcurrent = 0
        
        for event in order {
            if event < 100 {
                // Started
                concurrent += 1
                maxConcurrent = max(maxConcurrent, concurrent)
            } else {
                // Completed
                concurrent -= 1
            }
        }
        
        XCTAssertLessThanOrEqual(maxConcurrent, 2, "Should limit concurrency to 2")
    }
    
    func testDropStrategyUnderPressure() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .dropNewest
        )
        
        var results: [Result<String, Error>] = []
        
        // When - Try to execute 5 commands with outstanding limit of 2
        await withTaskGroup(of: Result<String, Error>.self) { group in
            for i in 0..<5 {
                group.addTask {
                    let command = BPTestCommand(value: "test-\(i)")
                    let context = CommandContext()
                    
                    do {
                        let result = try await middleware.execute(command, context: context) { cmd, _ in
                            // First one will take time
                            if i == 0 {
                                await self.synchronizer.mediumDelay()
                            }
                            return cmd.value
                        }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            for await result in group {
                results.append(result)
            }
        }
        
        // Then
        let successes = results.compactMap { try? $0.get() }
        let failures = results.compactMap { result in
            if case .failure(let error) = result {
                return error
            }
            return nil
        }
        
        XCTAssertGreaterThan(failures.count, 0, "Some commands should be dropped")
        XCTAssertLessThanOrEqual(successes.count, 3, "At most 3 should succeed (1 executing + 2 queued)")
        
        // Verify drops are PipelineError.backPressure
        for error in failures {
            if let pipelineError = error as? PipelineError,
               case .backPressure = pipelineError {
                // Expected
            } else {
                XCTFail("Expected PipelineError.backPressure, got \(error)")
            }
        }
    }
    
    func testSuspendStrategyUnderPressure() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 1,
            maxOutstanding: 3,
            strategy: .suspend
        )
        
        let startTimes = ExecutionTracker()
        
        // When - All should eventually execute
        let tasks = (0..<5).map { i in
            Task {
                await startTimes.append(i)
                
                let command = BPTestCommand(value: "test-\(i)")
                let context = CommandContext()
                
                return try await middleware.execute(command, context: context) { cmd, _ in
                    // Simulate varying work
                    await self.synchronizer.shortDelay()
                    return cmd.value
                }
            }
        }
        
        // Wait for all with timeout
        let results = try await withTimeout(seconds: 2.0) {
            try await withThrowingTaskGroup(of: String.self) { group in
                for task in tasks {
                    group.addTask {
                        try await task.value
                    }
                }
                
                var collected: [String] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected
            }
        }
        
        // Then - All should complete
        XCTAssertEqual(results.count, 5)
        
        // Verify suspension worked
        let order = await startTimes.getOrder()
        XCTAssertEqual(order.count, 5, "All tasks should have started")
    }
    
    func testMemoryPressureStrategy() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 2,
            maxOutstanding: 10,
            maxQueueMemory: 1024, // 1KB limit
            strategy: .dropOldest
        )
        
        // When - Submit commands with memory estimates
        var results: [Result<String, Error>] = []
        
        await withTaskGroup(of: Result<String, Error>.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let command = BPTestCommand(value: String(repeating: "x", count: 200)) // ~200 bytes
                    let context = CommandContext()
                    
                    do {
                        let result = try await middleware.execute(
                            command,
                            context: context,
                            estimatedSize: 200
                        ) { cmd, _ in
                            // Slow processing to build queue
                            await self.synchronizer.mediumDelay()
                            return cmd.value
                        }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            for await result in group {
                results.append(result)
            }
        }
        
        // Then
        let failures = results.compactMap { result in
            if case .failure(let error) = result {
                return error
            }
            return nil
        }
        XCTAssertGreaterThan(failures.count, 0, "Some commands should be dropped due to memory pressure")
        
        // Check memory errors
        let hasMemoryPressure = failures.contains { error in
            if let pipelineError = error as? PipelineError,
               case .backPressure(let reason) = pipelineError,
               case .memoryPressure = reason {
                return true
            }
            return false
        }
        XCTAssertTrue(hasMemoryPressure, "Should have memory pressure errors")
    }
    
    func testHealthCheck() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 2,
            maxOutstanding: 5
        )
        
        // When - Fill up queue
        let blockingTasks = (0..<6).map { i in
            Task {
                let command = BPTestCommand(value: "blocking-\(i)")
                let context = CommandContext()
                
                _ = try? await middleware.execute(command, context: context) { cmd, _ in
                    // Block indefinitely (or very long)
                    await self.synchronizer.longDelay()
                    return cmd.value
                }
            }
        }
        
        // Give time for queue to fill
        await synchronizer.mediumDelay()
        
        // Check health
        let health = await middleware.healthCheck()
        
        // Then
        XCTAssertFalse(health.isHealthy, "Should be unhealthy when queue is > 80% full")
        XCTAssertGreaterThanOrEqual(health.queueUtilization, 0.8)
        
        // Cleanup
        blockingTasks.forEach { $0.cancel() }
    }
    
    func testRateLimitIntegration() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 10
            // Rate limiting is not available in this version
        )
        
        let executionTimes = ExecutionTracker()
        
        // When - Try to execute 10 commands rapidly
        let startTime = Date()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let command = BPTestCommand(value: "rate-\(i)")
                    let context = CommandContext()
                    
                    _ = try? await middleware.execute(command, context: context) { cmd, _ in
                        await executionTimes.append(Int(Date().timeIntervalSince(startTime) * 1000)) // ms
                        return cmd.value
                    }
                }
            }
        }
        
        // Then
        let times = await executionTimes.getOrder()
        
        // First 5 should execute immediately (< 100ms)
        let firstBatch = times.prefix(5)
        for time in firstBatch {
            XCTAssertLessThan(time, 100, "First batch should execute quickly")
        }
        
        // Next 5 should be delayed (~1 second)
        if times.count > 5 {
            let secondBatch = times.dropFirst(5)
            for time in secondBatch {
                XCTAssertGreaterThan(time, 900, "Second batch should be rate limited")
            }
        }
    }
    
    func testStatsAccuracy() async throws {
        // Given
        let middleware = BackPressureMiddleware(
            maxConcurrency: 3,
            maxOutstanding: 10
        )
        
        // When - Create specific scenario
        let blocker = Task {
            let command = BPTestCommand(value: "blocker")
            let context = CommandContext()
            
            _ = try? await middleware.execute(command, context: context) { cmd, _ in
                await self.synchronizer.longDelay()
                return cmd.value
            }
        }
        
        // Add some queued items
        let queued = (0..<5).map { i in
            Task {
                let command = BPTestCommand(value: "queued-\(i)")
                let context = CommandContext()
                
                return try await middleware.execute(command, context: context) { cmd, _ in
                    return cmd.value
                }
            }
        }
        
        // Let queue build
        await synchronizer.mediumDelay()
        
        // Get stats
        let stats = await middleware.getStats()
        
        // Then
        XCTAssertEqual(stats.currentConcurrency, 1, "One blocker executing")
        XCTAssertGreaterThan(stats.queuedRequests, 0, "Should have queued requests")
        XCTAssertGreaterThan(stats.totalProcessed, 0, "Should track processed count")
        
        // Cleanup
        blocker.cancel()
        queued.forEach { $0.cancel() }
    }
}

// MARK: - Test Helpers

private struct BPTestCommand: Command {
    typealias Result = String
    let value: String
}

private actor ExecutionTracker {
    private var order: [Int] = []
    
    func append(_ value: Int) {
        order.append(value)
    }
    
    func getOrder() -> [Int] {
        return order
    }
}

// Timeout helper
private func withTimeout<T>(
    seconds: TimeInterval,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            let tester = TimeoutTester()
            try await tester.runWithTimeout(seconds) {
                // Timeout task
            }
            throw PipelineError.cancelled(context: "Timeout in test")
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// TimeoutError removed - using PipelineError.cancelled instead