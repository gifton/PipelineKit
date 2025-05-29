import XCTest
@testable import PipelineKit

// MARK: - Test Support Types for PipelineExecutionFailureTests

struct PipelineTestCommand: Command {
    typealias Result = String
    let value: String
}

struct PipelineTestHandler: CommandHandler {
    typealias CommandType = PipelineTestCommand
    
    func handle(_ command: PipelineTestCommand) async throws -> String {
        return "Handled: \(command.value)"
    }
}

/// Tests for pipeline execution failure scenarios
final class PipelineExecutionFailureTests: XCTestCase {
    
    // MARK: - Handler Failures
    
    func testHandlerException() async throws {
        let faultyHandler = PipelineFaultyHandler()
        let pipeline = DefaultPipeline(handler: faultyHandler)
        
        let command = PipelineTestCommand(value: "trigger_error")
        let metadata = DefaultCommandMetadata()
        
        do {
            _ = try await pipeline.execute(command, metadata: metadata)
            XCTFail("Handler exception should propagate")
        } catch HandlerError.processingFailed {
            // Expected error
        }
    }
    
    func testHandlerTimeout() async throws {
        let slowHandler = PipelineSlowHandler()
        let pipeline = DefaultPipeline(handler: slowHandler)
        
        let command = PipelineTestCommand(value: "slow_operation")
        let metadata = DefaultCommandMetadata()
        
        // Use timeout to simulate real-world timeout scenarios
        do {
            let result = try await withPipelineTimeout(seconds: 0.1) {
                try await pipeline.execute(command, metadata: metadata)
            }
            XCTFail("Handler should timeout, got result: \(result)")
        } catch {
            // Expected timeout
            XCTAssertTrue(error is PipelineTimeoutError || error.localizedDescription.contains("timeout"))
        }
    }
    
    func testHandlerMemoryLeak() async throws {
        weak var weakHandler: PipelineLeakyHandler?
        var pipeline: DefaultPipeline<PipelineTestCommand, PipelineLeakyHandler>?
        
        autoreleasepool {
            let handler = PipelineLeakyHandler()
            weakHandler = handler
            pipeline = DefaultPipeline(handler: handler)
        }
        
        // Handler should still exist because pipeline holds it
        XCTAssertNotNil(weakHandler)
        
        // Simulate pipeline cleanup
        pipeline = nil
        
        // Handler should be deallocated
        XCTAssertNil(weakHandler, "Handler should be deallocated when pipeline is released")
    }
    
    // MARK: - Middleware Failures
    
    func testMiddlewareException() async throws {
        let pipeline = DefaultPipeline(handler: PipelineTestHandler())
        let faultyMiddleware = FaultyMiddleware()
        
        try pipeline.addMiddleware(faultyMiddleware)
        
        let command = PipelineTestCommand(value: "test")
        let metadata = DefaultCommandMetadata()
        
        do {
            _ = try await pipeline.execute(command, metadata: metadata)
            XCTFail("Middleware exception should propagate")
        } catch MiddlewareError.executionFailed {
            // Expected error
        }
    }
    
    func testMiddlewareChainFailure() async throws {
        let pipeline = DefaultPipeline(handler: PipelineTestHandler())
        
        // Add multiple middleware, with one that fails
        try pipeline.addMiddleware(LoggingMiddleware())
        try pipeline.addMiddleware(FaultyMiddleware()) // This will fail
        try pipeline.addMiddleware(ValidationMiddleware(validator: CommandValidator<PipelineTestCommand>()))
        
        let command = PipelineTestCommand(value: "test")
        let metadata = DefaultCommandMetadata()
        
        do {
            _ = try await pipeline.execute(command, metadata: metadata)
            XCTFail("Middleware chain failure should propagate")
        } catch MiddlewareError.executionFailed {
            // Expected - middleware chain should stop at first failure
        }
    }
    
    func testMiddlewareNextNotCalled() async throws {
        let pipeline = DefaultPipeline(handler: PipelineTestHandler())
        let shortCircuitMiddleware = ShortCircuitMiddleware()
        
        try pipeline.addMiddleware(shortCircuitMiddleware)
        
        let command = PipelineTestCommand(value: "test")
        let metadata = DefaultCommandMetadata()
        
        // This should work but return short-circuited result
        let result = try await pipeline.execute(command, metadata: metadata)
        XCTAssertEqual(result, "short_circuit")
    }
    
    func testMiddlewareInfiniteLoop() async throws {
        let pipeline = DefaultPipeline(handler: PipelineTestHandler(), maxDepth: 5)
        
        // Add more middleware than max depth allows
        for i in 0..<10 {
            do {
                try pipeline.addMiddleware(NoOpMiddleware(id: i))
            } catch PipelineError.maxDepthExceeded {
                // Expected after hitting max depth
                break
            }
        }
        
        // Pipeline should enforce depth limit
        XCTAssertEqual(pipeline.middlewareCount, 5)
    }
    
    // MARK: - Context Corruption
    
    func testContextCorruption() async throws {
        let pipeline = ContextAwarePipeline(handler: PipelineTestHandler())
        let corruptingMiddleware = ContextCorruptingMiddleware()
        
        try await pipeline.addMiddleware(corruptingMiddleware)
        
        let command = PipelineTestCommand(value: "test")
        let metadata = DefaultCommandMetadata()
        
        do {
            _ = try await pipeline.execute(command, metadata: metadata)
            XCTFail("Context corruption should be detected")
        } catch ContextError.corruptedState {
            // Expected error
        }
    }
    
    func testContextMemoryLeak() async throws {
        weak var weakContext: CommandContext?
        
        autoreleasepool {
            let pipeline = ContextAwarePipeline(handler: PipelineTestHandler())
            let contextCapturingMiddleware = ContextCapturingMiddleware { context in
                weakContext = context
            }
            
            try await pipeline.addMiddleware(contextCapturingMiddleware)
            
            let command = PipelineTestCommand(value: "test")
            let metadata = DefaultCommandMetadata()
            
            _ = try await pipeline.execute(command, metadata: metadata)
        }
        
        // Context should be deallocated after execution
        XCTAssertNil(weakContext, "Context should not leak after execution")
    }
    
    func testContextRaceCondition() async throws {
        let pipeline = ContextAwarePipeline(handler: PipelineTestHandler())
        let racingMiddleware = ContextRacingMiddleware()
        
        try await pipeline.addMiddleware(racingMiddleware)
        
        let command = PipelineTestCommand(value: "test")
        let metadata = DefaultCommandMetadata()
        
        // Execute multiple commands concurrently to trigger race condition
        let tasks = (0..<10).map { _ in
            Task {
                try await pipeline.execute(command, metadata: metadata)
            }
        }
        
        // All tasks should complete successfully without data races
        for task in tasks {
            let result = try await task.value
            XCTAssertEqual(result, "Handled: test")
        }
    }
    
    // MARK: - Resource Exhaustion
    
    func testMemoryExhaustion() async throws {
        let pipeline = DefaultPipeline(handler: PipelineTestHandler())
        let memoryHogMiddleware = MemoryHogMiddleware()
        
        try pipeline.addMiddleware(memoryHogMiddleware)
        
        let command = PipelineTestCommand(value: "test")
        let metadata = DefaultCommandMetadata()
        
        // This test verifies graceful handling under memory pressure
        do {
            _ = try await pipeline.execute(command, metadata: metadata)
            // If it completes, memory management is working
        } catch {
            // If it fails due to memory pressure, that's also valid
            XCTAssertTrue(error.localizedDescription.contains("memory") || 
                         error.localizedDescription.contains("resource"))
        }
    }
    
    func testMaxConcurrencyExceeded() async throws {
        let pipeline = DefaultPipeline(
            handler: PipelineSlowHandler(), 
            maxConcurrency: 2
        )
        
        let command = PipelineTestCommand(value: "slow_operation")
        let metadata = DefaultCommandMetadata()
        
        // Start 5 concurrent operations (exceeds limit of 2)
        let tasks = (0..<5).map { _ in
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
        
        // Should have some successful and some back-pressure limited results
        let successCount = results.filter { $0.starts(with: "Handled") }.count
        XCTAssertLessOrEqual(successCount, 2, "Should not exceed concurrency limit")
    }
    
    // MARK: - Error Recovery
    
    func testErrorRecoveryAfterFailure() async throws {
        let recoveringHandler = RecoveringHandler()
        let pipeline = DefaultPipeline(handler: recoveringHandler)
        
        let command = PipelineTestCommand(value: "test")
        let metadata = DefaultCommandMetadata()
        
        // First call should fail
        do {
            _ = try await pipeline.execute(command, metadata: metadata)
            XCTFail("First call should fail")
        } catch HandlerError.processingFailed {
            // Expected
        }
        
        // Second call should succeed (handler recovered)
        let result = try await pipeline.execute(command, metadata: metadata)
        XCTAssertEqual(result, "Recovered: test")
    }
    
    func testPartialPipelineRecovery() async throws {
        let pipeline = DefaultPipeline(handler: PipelineTestHandler())
        let resilientMiddleware = ResilientMiddleware()
        
        try pipeline.addMiddleware(resilientMiddleware)
        
        let command = PipelineTestCommand(value: "trigger_recovery")
        let metadata = DefaultCommandMetadata()
        
        // Should handle internal failures and continue
        let result = try await pipeline.execute(command, metadata: metadata)
        XCTAssertEqual(result, "Handled: trigger_recovery")
    }
    
    // MARK: - Cancellation Scenarios
    
    func testCancellationDuringExecution() async throws {
        let pipeline = DefaultPipeline(handler: PipelineSlowHandler())
        let command = PipelineTestCommand(value: "cancellable_operation")
        let metadata = DefaultCommandMetadata()
        
        let task = Task {
            try await pipeline.execute(command, metadata: metadata)
        }
        
        // Cancel after short delay
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Task should be cancelled")
        } catch is CancellationError {
            // Expected cancellation
        }
    }
    
    func testCancellationCleanup() async throws {
        var resourcesCleaned = false
        
        let cleanupHandler = CleanupHandler { 
            resourcesCleaned = true 
        }
        let pipeline = DefaultPipeline(handler: cleanupHandler)
        
        let command = PipelineTestCommand(value: "cleanup_test")
        let metadata = DefaultCommandMetadata()
        
        let task = Task {
            try await pipeline.execute(command, metadata: metadata)
        }
        
        // Cancel immediately
        task.cancel()
        
        do {
            _ = try await task.value
        } catch is CancellationError {
            // Expected
        }
        
        // Give cleanup a moment to run
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        
        XCTAssertTrue(resourcesCleaned, "Resources should be cleaned up on cancellation")
    }
}

// MARK: - Test Support Types

enum HandlerError: Error {
    case processingFailed
}

enum MiddlewareError: Error {
    case executionFailed
}

enum ContextError: Error {
    case corruptedState
}

struct PipelineTimeoutError: Error {}

struct PipelineFaultyHandler: CommandHandler {
    typealias CommandType = PipelineTestCommand
    
    func handle(_ command: PipelineTestCommand) async throws -> String {
        throw HandlerError.processingFailed
    }
}

struct PipelineSlowHandler: CommandHandler {
    typealias CommandType = PipelineTestCommand
    
    func handle(_ command: PipelineTestCommand) async throws -> String {
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        return "Slow: \(command.value)"
    }
}

final class PipelineLeakyHandler: CommandHandler, @unchecked Sendable {
    typealias CommandType = PipelineTestCommand
    
    private let largeData = Array(repeating: 0, count: 10000)
    
    func handle(_ command: PipelineTestCommand) async throws -> String {
        return "Handled: \(command.value)"
    }
}

struct FaultyMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        throw MiddlewareError.executionFailed
    }
}

struct ShortCircuitMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Don't call next - short circuit the pipeline
        return "short_circuit" as! T.Result
    }
}

struct NoOpMiddleware: Middleware {
    let id: Int
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        return try await next(command, metadata)
    }
}

struct ContextCorruptingMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate context corruption
        throw ContextError.corruptedState
    }
}

struct ContextCapturingMiddleware: ContextAwareMiddleware {
    let captureHandler: (CommandContext) -> Void
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        captureHandler(context)
        return try await next(command, context)
    }
}

struct ContextRacingMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simulate race condition by rapid context access
        await context.set("race_key", for: StringKey.self)
        let _ = await context.get(StringKey.self)
        await context.set("race_key_2", for: StringKey.self)
        
        return try await next(command, context)
    }
}

struct MemoryHogMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Allocate large amount of memory
        let _ = Array(repeating: Array(repeating: 0, count: 1000), count: 1000)
        return try await next(command, metadata)
    }
}

class RecoveringHandler: CommandHandler {
    typealias CommandType = PipelineTestCommand
    
    private var callCount = 0
    
    func handle(_ command: PipelineTestCommand) async throws -> String {
        callCount += 1
        
        if callCount == 1 {
            throw HandlerError.processingFailed
        }
        
        return "Recovered: \(command.value)"
    }
}

struct ResilientMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        do {
            // Simulate internal operation that might fail
            if command.description.contains("trigger_recovery") {
                // Recover from simulated failure
            }
            return try await next(command, metadata)
        } catch {
            // Middleware handles its own errors and continues
            return try await next(command, metadata)
        }
    }
}

class CleanupHandler: CommandHandler {
    typealias CommandType = PipelineTestCommand
    
    private let onCleanup: () -> Void
    
    init(onCleanup: @escaping () -> Void) {
        self.onCleanup = onCleanup
    }
    
    func handle(_ command: PipelineTestCommand) async throws -> String {
        defer { onCleanup() }
        
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        return "Handled: \(command.value)"
    }
}

struct StringKey: ContextKey {
    typealias Value = String
}

// Helper function for timeout testing
func withPipelineTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw PipelineTimeoutError()
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}