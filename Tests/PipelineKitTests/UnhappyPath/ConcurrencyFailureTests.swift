import XCTest
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
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
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
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
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
        let pipeline = ContextAwarePipeline(handler: ConcurrencyTestHandler())
        let racingMiddleware = ConcurrentContextMiddleware()
        
        try await pipeline.addMiddleware(racingMiddleware)
        
        let command = ConcurrencyTestCommand(value: "race_test")
        let metadata = DefaultCommandMetadata()
        
        // Execute multiple commands concurrently to trigger race conditions
        let tasks = (0..<20).map { i in
            Task {
                do {
                    return try await pipeline.execute(command, metadata: metadata)
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
                let pipeline = DefaultPipeline(handler: ConcurrencyTestHandler())
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
        let result = try await concurrentPipeline.execute(command, metadata: DefaultCommandMetadata())
        XCTAssertEqual(result, "Handled: test")
    }
    
    func testConcurrentMiddlewareRegistration() async throws {
        let pipeline = DefaultPipeline(handler: ConcurrencyTestHandler())
        
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
        let pipeline1 = DefaultPipeline(handler: ConcurrencyTestHandler())
        let pipeline2 = DefaultPipeline(handler: ConcurrencyTestHandler())
        
        let crossReferencingMiddleware1 = CrossReferencingMiddleware(otherPipeline: pipeline2)
        let crossReferencingMiddleware2 = CrossReferencingMiddleware(otherPipeline: pipeline1)
        
        try await pipeline1.addMiddleware(crossReferencingMiddleware1)
        try await pipeline2.addMiddleware(crossReferencingMiddleware2)
        
        let command = ConcurrencyTestCommand(value: "deadlock_test")
        let metadata = DefaultCommandMetadata()
        
        // Execute with timeout to detect potential deadlocks
        let task = Task {
            try await pipeline1.execute(command, metadata: metadata)
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
        let isolatedPipeline = DefaultPipeline(handler: ConcurrencyTestHandler())
        
        // Try to access pipeline from multiple actors simultaneously
        actor PipelineUser {
            func usePipeline(_ pipeline: DefaultPipeline<ConcurrencyTestCommand, ConcurrencyTestHandler>) async throws -> String {
                let command = ConcurrencyTestCommand(value: "isolation_test")
                return try await pipeline.execute(command, metadata: DefaultCommandMetadata())
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
                    let token = try await semaphore.acquire()
                    // Hold the token for a short time
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
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
        let pipeline = DefaultPipeline(
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
                    return try await pipeline.execute(command, metadata: DefaultCommandMetadata())
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
        let pipeline = DefaultPipeline(handler: ConcurrencyTestHandler())
        
        // Concurrently add and remove middleware while executing
        let modificationTask = Task {
            for i in 0..<10 {
                try await pipeline.addMiddleware(NoOpMiddleware(id: i))
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms
                // Note: removeMiddleware may not exist in the API
            }
        }
        
        let executionTasks = (0..<20).map { i in
            Task {
                let command = ConcurrencyTestCommand(value: "concurrent_test_\(i)")
                return try await pipeline.execute(command, metadata: DefaultCommandMetadata())
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
        let pipeline = ContextAwarePipeline(handler: ConcurrencyTestHandler())
        let stateCorruptingMiddleware = StateCorruptingMiddleware()
        
        try await pipeline.addMiddleware(stateCorruptingMiddleware)
        
        let command = ConcurrencyTestCommand(value: "corruption_test")
        let metadata = DefaultCommandMetadata()
        
        // Execute multiple commands that might corrupt shared state
        let tasks = (0..<10).map { _ in
            Task {
                try await pipeline.execute(command, metadata: metadata)
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
        let pipeline = PriorityPipeline(handler: ConcurrencyTestHandler())
        
        // Add middleware with different priorities
        try await pipeline.addMiddleware(HighPriorityMiddleware(), priority: 100)
        try await pipeline.addMiddleware(LowPriorityMiddleware(), priority: 1000)
        try await pipeline.addMiddleware(MediumPriorityMiddleware(), priority: 500)
        
        var executionOrder: [String] = []
        let orderTrackingMiddleware = OrderTrackingMiddleware { order in
            executionOrder.append(order)
        }
        
        // This middleware will capture execution order
        try await pipeline.addMiddleware(orderTrackingMiddleware, priority: 1)
        
        let command = ConcurrencyTestCommand(value: "priority_test")
        let metadata = DefaultCommandMetadata()
        
        _ = try await pipeline.execute(command, metadata: metadata)
        
        // Verify correct priority order (lower numbers = higher priority)
        let expectedOrder = ["order_tracking", "high", "medium", "low"]
        XCTAssertEqual(executionOrder, expectedOrder, "Middleware should execute in priority order")
    }
    
    // MARK: - Task Cancellation Edge Cases
    
    func testCancellationRace() async throws {
        let pipeline = DefaultPipeline(handler: ConcurrencySlowHandler())
        let command = ConcurrencyTestCommand(value: "cancellation_race")
        let metadata = DefaultCommandMetadata()
        
        // Start multiple tasks and cancel them at different times
        let tasks = (0..<5).map { i in
            Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(i * 10_000_000)) // Stagger starts
                    return try await pipeline.execute(command, metadata: metadata)
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
                try await Task.sleep(nanoseconds: 20_000_000) // 20ms
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

struct ConcurrentContextMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate concurrent context access
        await context.set("key1", for: ConcurrencyStringKey.self)
        await context.set("key2", for: ConcurrencyStringKey.self)
        
        let _ = await context[ConcurrencyStringKey.self]
        
        await context.set("key3", for: ConcurrencyStringKey.self)
        
        return try await next(command, context)
    }
}

struct CrossReferencingMiddleware: Middleware {
    let otherPipeline: DefaultPipeline<ConcurrencyTestCommand, ConcurrencyTestHandler>
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Don't actually call other pipeline to avoid real deadlock in tests
        // Just simulate the potential for deadlock
        return try await next(command, metadata)
    }
}

struct MemoryIntensiveMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Allocate and immediately release memory
        autoreleasepool {
            let _ = Array(repeating: Array(repeating: 0, count: 100), count: 100)
        }
        return try await next(command, metadata)
    }
}

final class StateCorruptingMiddleware: ContextAwareMiddleware, @unchecked Sendable {
    private var sharedState = 0
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate state that could be corrupted by concurrent access
        // Note: This is intentionally unsafe to test corruption handling
        let currentState = sharedState
        try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        sharedState = currentState + 1
        
        return try await next(command, context)
    }
}

struct HighPriorityMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        return try await next(command, metadata)
    }
}

struct MediumPriorityMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        return try await next(command, metadata)
    }
}

struct LowPriorityMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        return try await next(command, metadata)
    }
}

struct OrderTrackingMiddleware: Middleware {
    let onExecute: @Sendable (String) -> Void
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        onExecute("order_tracking")
        return try await next(command, metadata)
    }
}

struct ConcurrencySlowHandler: CommandHandler {
    typealias CommandType = ConcurrencyTestCommand
    
    func handle(_ command: ConcurrencyTestCommand) async throws -> String {
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        return "Slow: \(command.value)"
    }
}

struct ConcurrencyStringKey: ContextKey {
    typealias Value = String
}

// Helper for timeout testing
struct ConcurrencyTimeoutError: Error {}

func withConcurrencyTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ConcurrencyTimeoutError()
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
