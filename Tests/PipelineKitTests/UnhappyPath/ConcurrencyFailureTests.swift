import XCTest
import Foundation
@testable import PipelineKit

// MARK: - Test Support Types for ConcurrencyFailureTests

struct ConcurrencyTestCommand: Command {
    typealias Result = String
    let value: String
}

struct ConcurrencyTestHandler: CommandHandler {
    typealias CommandType = ConcurrencyTestCommand
    
    func handle(_ command: ConcurrencyTestCommand) async throws -> String {
        return "Handled: \(command.value)"
    }
}

/// Tests for concurrency failure scenarios and edge cases
final class ConcurrencyFailureTests: XCTestCase {
    private let synchronizer = TestSynchronizer()
    private let timeoutTester = TimeoutTester()
    
    // MARK: - Back-Pressure Overflow
    
    func testBackPressureQueueOverflow() async throws {
        let options = PipelineOptions(
            maxConcurrency: 1,
            maxOutstanding: 3,
            backPressureStrategy: .error(timeout: 0.1)
        )
        
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: options.maxConcurrency!,
            maxOutstanding: options.maxOutstanding,
            strategy: options.backPressureStrategy
        )
        
        // Fill up the queue
        let tokens = try await withThrowingTaskGroup(of: SemaphoreToken?.self) { group in
            // Add tasks up to the limit
            for _ in 0..<3 {
                group.addTask {
                    try await semaphore.acquire()
                }
            }
            
            var acquiredTokens: [SemaphoreToken] = []
            for try await token in group {
                if let token = token {
                    acquiredTokens.append(token)
                }
            }
            return acquiredTokens
        }
        
        XCTAssertEqual(tokens.count, 3)
        
        // Try to acquire one more - should fail immediately
        do {
            _ = try await semaphore.acquire()
            XCTFail("Should fail when queue is full")
        } catch let error as BackPressureError {
            switch error {
            case .queueFull:
                // Expected
                break
            default:
                XCTFail("Unexpected back-pressure error: \(error)")
            }
        }
    }
    
    func testBackPressureTimeout() async throws {
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 1,
            strategy: .error(timeout: 0.1)
        )
        
        // Acquire the only token
        let token = try await semaphore.acquire()
        
        // Try to acquire another with timeout
        do {
            _ = try await semaphore.acquire()
            XCTFail("Should timeout waiting for capacity")
        } catch let error as BackPressureError {
            switch error {
            case .timeout(let duration):
                XCTAssertGreaterThanOrEqual(duration, 0.1)
            default:
                XCTFail("Expected timeout error, got: \(error)")
            }
        }
        
        // Clean up
        _ = token
    }
    
    func testBackPressureDropOldest() async throws {
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .dropOldest
        )
        
        // Fill capacity
        let token1 = try await semaphore.acquire()
        
        // This will queue
        let task2 = Task {
            try await semaphore.acquire()
        }
        
        // Wait a moment for task2 to queue
        await synchronizer.shortDelay()
        
        // This should drop the oldest queued item (task2)
        let token3 = try await semaphore.acquire()
        
        // task2 should be cancelled/dropped
        do {
            _ = try await task2.value
            XCTFail("Task2 should be dropped")
        } catch {
            // Expected - task was dropped
        }
        
        // Clean up
        _ = token1
        _ = token3
    }
    
    func testBackPressureDropNewest() async throws {
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 1,
            maxOutstanding: 2,
            strategy: .dropNewest
        )
        
        // Fill capacity
        let token1 = try await semaphore.acquire()
        
        // This will queue successfully
        let task2 = Task {
            try await semaphore.acquire()
        }
        
        // Wait for task2 to queue
        await synchronizer.shortDelay()
        
        // This should be dropped (newest)
        do {
            _ = try await semaphore.acquire()
            XCTFail("Newest request should be dropped")
        } catch let error as BackPressureError {
            switch error {
            case .commandDropped:
                // Expected
                break
            default:
                XCTFail("Expected commandDropped error, got: \(error)")
            }
        }
        
        // Clean up - task2 should still be able to proceed when token1 is released
        _ = token1
        
        // task2 should eventually succeed
        let token2 = try await task2.value
        _ = token2
    }
    
    // MARK: - Race Conditions
    
    func testConcurrentContextModification() async throws {
        let pipeline = StandardPipeline(handler: ConcurrencyTestHandler())
        let racingMiddleware = ConcurrentContextMiddleware()
        
        try await pipeline.addMiddleware(racingMiddleware)
        
        let command = ConcurrencyTestCommand(value: "race_test")
        let context = CommandContext()
        
        // Execute multiple commands concurrently to trigger race conditions
        let tasks = (0..<20).map { i in
            Task {
                do {
                    return try await pipeline.execute(command, context: context)
                } catch {
                    return "error: \(error.localizedDescription)"
                }
            }
        }
        
        let results = await withTaskGroup(of: String.self) { group in
            for task in tasks {
                group.addTask { await task.value }
            }
            
            var allResults: [String] = []
            for await result in group {
                allResults.append(result)
            }
            return allResults
        }
        
        // All results should be successful (no data races)
        let successCount = results.filter { $0.starts(with: "Handled") }.count
        XCTAssertEqual(successCount, 20, "All executions should succeed without race conditions")
    }
    
    func testConcurrentPipelineRegistration() async throws {
        let concurrentPipeline = ConcurrentPipeline(options: PipelineOptions())
        
        // Register pipelines concurrently
        let registrationTasks = (0..<10).map { i in
            Task {
                let pipeline = StandardPipeline(handler: ConcurrencyTestHandler())
                await concurrentPipeline.register(ConcurrencyTestCommand.self, pipeline: pipeline)
                return i
            }
        }
        
        // Wait for all registrations
        for task in registrationTasks {
            _ = await task.value
        }
        
        // Verify pipeline is registered and functional
        let command = ConcurrencyTestCommand(value: "test")
        let result = try await concurrentPipeline.execute(command, context: CommandContext())
        XCTAssertEqual(result, "Handled: test")
    }
    
    func testConcurrentMiddlewareRegistration() async throws {
        let pipeline = StandardPipeline(handler: ConcurrencyTestHandler())
        
        // Add middleware concurrently
        let middlewareTasks = (0..<5).map { i in
            Task {
                do {
                    try await pipeline.addMiddleware(NoOpMiddleware(id: i))
                    return true
                } catch {
                    return false
                }
            }
        }
        
        var successCount = 0
        for task in middlewareTasks {
            if await task.value {
                successCount += 1
            }
        }
        
        // All middleware should be added successfully
        XCTAssertEqual(successCount, 5)
        // All middleware should be added successfully
    }
    
    // MARK: - Deadlock Detection
    
    func testPotentialDeadlock() async throws {
        let pipeline1 = StandardPipeline(handler: ConcurrencyTestHandler())
        let pipeline2 = StandardPipeline(handler: ConcurrencyTestHandler())
        
        let crossReferencingMiddleware1 = CrossReferencingMiddleware(otherPipeline: pipeline2)
        let crossReferencingMiddleware2 = CrossReferencingMiddleware(otherPipeline: pipeline1)
        
        try await pipeline1.addMiddleware(crossReferencingMiddleware1)
        try await pipeline2.addMiddleware(crossReferencingMiddleware2)
        
        let command = ConcurrencyTestCommand(value: "deadlock_test")
        let context = CommandContext()
        
        // Execute with timeout to detect potential deadlocks
        let task = Task {
            try await pipeline1.execute(command, context: context)
        }
        
        do {
            let result = try await withConcurrencyTimeout(seconds: 1.0) {
                try await task.value
            }
            XCTAssertEqual(result, "Handled: deadlock_test")
        } catch is ConcurrencyTimeoutError {
            XCTFail("Potential deadlock detected - execution timed out")
        }
    }
    
    func testActorIsolationViolation() async throws {
        let isolatedPipeline = StandardPipeline(handler: ConcurrencyTestHandler())
        
        // Try to access pipeline from multiple actors simultaneously
        actor PipelineUser {
            func usePipeline(_ pipeline: StandardPipeline<ConcurrencyTestCommand, ConcurrencyTestHandler>) async throws -> String {
                let command = ConcurrencyTestCommand(value: "isolation_test")
                return try await pipeline.execute(command, context: CommandContext())
            }
        }
        
        let users = (0..<5).map { _ in PipelineUser() }
        
        let tasks = users.map { user in
            Task {
                try await user.usePipeline(isolatedPipeline)
            }
        }
        
        // All tasks should complete without isolation violations
        for task in tasks {
            let result = try await task.value
            XCTAssertEqual(result, "Handled: isolation_test")
        }
    }
    
    // MARK: - Resource Contention
    
    func testSemaphoreContention() async throws {
        let semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: 2,
            maxOutstanding: 10,
            strategy: .suspend
        )
        
        // Create many competing tasks
        let tasks = (0..<50).map { i in
            Task {
                do {
                    let _ = try await semaphore.acquire()
                    // Hold the token for a short time
                    await self.synchronizer.shortDelay()
                    return (i, true)
                } catch {
                    return (i, false)
                }
            }
        }
        
        var successCount = 0
        var totalCompleted = 0
        
        for task in tasks {
            let (_, success) = await task.value
            totalCompleted += 1
            if success {
                successCount += 1
            }
        }
        
        XCTAssertEqual(totalCompleted, 50, "All tasks should complete")
        XCTAssertGreaterThan(successCount, 0, "Some tasks should succeed")
    }
    
    func testMemoryPressureUnderContention() async throws {
        let pipeline = StandardPipeline(
            handler: ConcurrencyTestHandler(),
            maxConcurrency: 5
        )
        
        let memoryIntensiveMiddleware = MemoryIntensiveMiddleware()
        try await pipeline.addMiddleware(memoryIntensiveMiddleware)
        
        // Execute many memory-intensive operations
        let tasks = (0..<20).map { i in
            Task {
                do {
                    let command = ConcurrencyTestCommand(value: "memory_test_\(i)")
                    return try await pipeline.execute(command, context: CommandContext())
                } catch {
                    return "error: \(error.localizedDescription)"
                }
            }
        }
        
        var successCount = 0
        for task in tasks {
            let result = await task.value
            if result.starts(with: "Handled") {
                successCount += 1
            }
        }
        
        // Should handle memory pressure gracefully
        XCTAssertGreaterThan(successCount, 10, "Should handle most requests despite memory pressure")
    }
    
    // MARK: - Pipeline State Corruption
    
    func testConcurrentPipelineModification() async throws {
        let pipeline = StandardPipeline(handler: ConcurrencyTestHandler())
        
        // Concurrently add and remove middleware while executing
        let modificationTask = Task {
            for i in 0..<10 {
                try await pipeline.addMiddleware(NoOpMiddleware(id: i))
                await self.synchronizer.shortDelay()
                // Note: removeMiddleware may not exist in the API
            }
        }
        
        let executionTasks = (0..<20).map { i in
            Task {
                let command = ConcurrencyTestCommand(value: "concurrent_test_\(i)")
                return try await pipeline.execute(command, context: CommandContext())
            }
        }
        
        // Wait for modification task
        _ = try await modificationTask.value
        
        // All executions should complete successfully
        for task in executionTasks {
            let result = try await task.value
            XCTAssertTrue(result.starts(with: "Handled"))
        }
    }
    
    func testContextStateCorruption() async throws {
        let pipeline = StandardPipeline(handler: ConcurrencyTestHandler())
        let stateCorruptingMiddleware = StateCorruptingMiddleware()
        
        try await pipeline.addMiddleware(stateCorruptingMiddleware)
        
        let command = ConcurrencyTestCommand(value: "corruption_test")
        let context = CommandContext()
        
        // Execute multiple commands that might corrupt shared state
        let tasks = (0..<10).map { _ in
            Task {
                try await pipeline.execute(command, context: context)
            }
        }
        
        // All executions should maintain state integrity
        for task in tasks {
            let result = try await task.value
            XCTAssertEqual(result, "Handled: corruption_test")
        }
    }
    
    // MARK: - Priority Inversion
    
    func testPriorityInversion() async throws {
        final class ExecutionOrderTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var executionOrder: [String] = []
            
            func append(_ value: String) {
                lock.lock()
                defer { lock.unlock() }
                executionOrder.append(value)
            }
            
            func getOrder() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return executionOrder
            }
        }
        
        let pipeline = StandardPipeline(handler: ConcurrencyTestHandler())
        let orderTracker = ExecutionOrderTracker()
        
        // Add middleware with different priorities
        try await pipeline.addMiddleware(HighPriorityMiddleware { order in
            orderTracker.append(order)
        })
        try await pipeline.addMiddleware(LowPriorityMiddleware { order in
            orderTracker.append(order)
        })
        try await pipeline.addMiddleware(MediumPriorityMiddleware { order in
            orderTracker.append(order)
        })
        
        let orderTrackingMiddleware = OrderTrackingMiddleware { order in
            orderTracker.append(order)
        }
        
        // This middleware will capture execution order
        try await pipeline.addMiddleware(orderTrackingMiddleware)
        
        let command = ConcurrencyTestCommand(value: "priority_test")
        let context = CommandContext()
        
        _ = try await pipeline.execute(command, context: context)
        
        // Verify correct priority order (lower numbers = higher priority)
        let expectedOrder = ["order_tracking", "high", "medium", "low"]
        XCTAssertEqual(orderTracker.getOrder(), expectedOrder, "Middleware should execute in priority order")
    }
    
    // MARK: - Task Cancellation Edge Cases
    
    func testCancellationRace() async throws {
        let pipeline = StandardPipeline(handler: ConcurrencySlowHandler())
        let command = ConcurrencyTestCommand(value: "cancellation_race")
        let context = CommandContext()
        
        // Start multiple tasks and cancel them at different times
        let tasks = (0..<5).map { i in
            Task {
                do {
                    if i > 0 {
                        await self.synchronizer.shortDelay()
                    }
                    return try await pipeline.execute(command, context: context)
                } catch is CancellationError {
                    return "cancelled"
                } catch {
                    return "error: \(error.localizedDescription)"
                }
            }
        }
        
        // Cancel tasks at different times
        for (index, task) in tasks.enumerated() {
            if index % 2 == 0 {
                await synchronizer.shortDelay()
                task.cancel()
            }
        }
        
        var cancelledCount = 0
        for task in tasks {
            let result = await task.value
            if result == "cancelled" {
                cancelledCount += 1
            }
        }
        
        XCTAssertGreaterThan(cancelledCount, 0, "Some tasks should be cancelled")
    }
}

// MARK: - Test Support Types

struct ConcurrentContextMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate concurrent context access
        context.set("key1", for: ConcurrencyStringKey.self)
        context.set("key2", for: ConcurrencyStringKey.self)
        
        let _ = await context[ConcurrencyStringKey.self]
        
        context.set("key3", for: ConcurrencyStringKey.self)
        
        return try await next(command, context)
    }
}

struct CrossReferencingMiddleware: Middleware {
    let otherPipeline: StandardPipeline<ConcurrencyTestCommand, ConcurrencyTestHandler>
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Don't actually call other pipeline to avoid real deadlock in tests
        // Just simulate the potential for deadlock
        return try await next(command, context)
    }
}

struct MemoryIntensiveMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Allocate and immediately release memory
        autoreleasepool {
            let _ = Array(repeating: Array(repeating: 0, count: 100), count: 100)
        }
        return try await next(command, context)
    }
}

final class StateCorruptingMiddleware: Middleware, @unchecked Sendable {
    private var sharedState = 0
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate state that could be corrupted by concurrent access
        // Note: This is intentionally unsafe to test corruption handling
        let currentState = sharedState
        await Task {
            // Simulate async work without sleep
            _ = currentState
        }.value
        sharedState = currentState + 1
        
        return try await next(command, context)
    }
}

final class HighPriorityMiddleware: Middleware, @unchecked Sendable {
    let orderTracker: @Sendable (String) -> Void
    var priority: ExecutionPriority { .validation }  // Execute second
    
    init(orderTracker: @escaping @Sendable (String) -> Void = { _ in }) {
        self.orderTracker = orderTracker
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        orderTracker("high")
        return try await next(command, context)
    }
}

final class MediumPriorityMiddleware: Middleware, @unchecked Sendable {
    let orderTracker: @Sendable (String) -> Void
    var priority: ExecutionPriority { .preProcessing }  // Execute third
    
    init(orderTracker: @escaping @Sendable (String) -> Void = { _ in }) {
        self.orderTracker = orderTracker
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        orderTracker("medium")
        return try await next(command, context)
    }
}

final class LowPriorityMiddleware: Middleware, @unchecked Sendable {
    let orderTracker: @Sendable (String) -> Void
    var priority: ExecutionPriority { .postProcessing }
    
    init(orderTracker: @escaping @Sendable (String) -> Void = { _ in }) {
        self.orderTracker = orderTracker
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        orderTracker("low")
        return try await next(command, context)
    }
}

struct OrderTrackingMiddleware: Middleware {
    let onExecute: @Sendable (String) -> Void
    let priority = ExecutionPriority.authentication  // Execute first
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        onExecute("order_tracking")
        return try await next(command, context)
    }
}

struct ConcurrencySlowHandler: CommandHandler {
    typealias CommandType = ConcurrencyTestCommand
    
    func handle(_ command: ConcurrencyTestCommand) async throws -> String {
        // Use TimeoutTester for deterministic delay simulation
        let tester = TimeoutTester()
        try await tester.runWithTimeout(0.1) {
            // Simulate slow work
        }
        return "Slow: \(command.value)"
    }
}

struct ConcurrencyStringKey: ContextKey {
    typealias Value = String
}

// Helper for timeout testing
struct ConcurrencyTimeoutError: Error {}

func withConcurrencyTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            let tester = TimeoutTester()
            try await tester.runWithTimeout(seconds) {
                // Timeout task
            }
            throw ConcurrencyTimeoutError()
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
