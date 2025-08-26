import XCTest
@testable import PipelineKitCore
@testable import PipelineKitResilience
@testable import PipelineKitMiddleware

/// Phase 4 Validation Tests - Comprehensive integration testing
final class Phase4ValidationTests: XCTestCase {
    // MARK: - Test Types
    
    private struct TestCommand: Command {
        typealias Result = String
        let value: String
        let shouldFail: Bool = false
        
        func execute() async throws -> String {
            if shouldFail {
                throw TestError.commandFailed
            }
            return value
        }
    }
    
    private enum TestError: Error {
        case commandFailed
        case middlewareFailed
    }
    
    private struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> TestCommand.Result {
            if command.shouldFail {
                throw TestError.commandFailed
            }
            return command.value + "-handled"
        }
    }
    
    // MARK: - Test Middleware
    
    private struct CountingMiddleware: Middleware {
        let id: String
        let priority: ExecutionPriority
        let callCounter: CallCounter
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            await callCounter.increment(id)
            return try await next(command, context)
        }
    }
    
    private actor CallCounter {
        private var counts: [String: Int] = [:]
        
        func increment(_ id: String) {
            counts[id, default: 0] += 1
        }
        
        func getCount(_ id: String) -> Int {
            counts[id] ?? 0
        }
        
        func reset() {
            counts = [:]
        }
    }
    
    private struct ConditionalMiddleware: Middleware {
        let priority = ExecutionPriority.custom
        let condition: @Sendable (any Command) -> Bool
        let callNext: Bool
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            if condition(command) && callNext {
                return try await next(command, context)
            } else if condition(command) {
                // Return without calling next - should trigger NextGuard warning
                throw TestError.middlewareFailed
            } else {
                return try await next(command, context)
            }
        }
    }
    
    private struct UnsafeMultiCallMiddleware: Middleware, UnsafeMiddleware {
        let priority = ExecutionPriority.custom
        let callCount: Int
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            var lastResult: T.Result?
            for _ in 0..<callCount {
                lastResult = try await next(command, context)
            }
            return lastResult ?? (try await next(command, context))
        }
    }
    
    // MARK: - Complex Chain Tests
    
    func testComplexMiddlewareChain() async throws {
        // Test that middleware executes in correct priority order
        let counter = CallCounter()
        let pipeline = StandardPipeline(handler: TestHandler())
        
        // Add middleware with different priorities
        try await pipeline.addMiddleware(CountingMiddleware(
            id: "auth",
            priority: .authentication,
            callCounter: counter
        ))
        
        try await pipeline.addMiddleware(CountingMiddleware(
            id: "validation",
            priority: .validation,
            callCounter: counter
        ))
        
        try await pipeline.addMiddleware(CountingMiddleware(
            id: "processing",
            priority: .processing,
            callCounter: counter
        ))
        
        try await pipeline.addMiddleware(CountingMiddleware(
            id: "monitoring",
            priority: .monitoring,
            callCounter: counter
        ))
        
        // Execute command
        let command = TestCommand(value: "test")
        let result = try await pipeline.execute(command, context: CommandContext())
        
        XCTAssertEqual(result, "test-handled")
        
        // Verify all middleware were called
        XCTAssertEqual(await counter.getCount("auth"), 1)
        XCTAssertEqual(await counter.getCount("validation"), 1)
        XCTAssertEqual(await counter.getCount("processing"), 1)
        XCTAssertEqual(await counter.getCount("monitoring"), 1)
    }
    
    func testCancellationPropagation() async throws {
        // Test that cancellation properly propagates through middleware chain
        let pipeline = StandardPipeline(handler: TestHandler())
        
        let slowMiddleware = SlowMiddleware(delay: 0.5)
        let timeoutMiddleware = TimeoutMiddleware(defaultTimeout: 0.1)
        
        try await pipeline.addMiddleware(timeoutMiddleware)
        try await pipeline.addMiddleware(slowMiddleware)
        
        let command = TestCommand(value: "test")
        
        do {
            _ = try await pipeline.execute(command, context: CommandContext())
            XCTFail("Should have timed out")
        } catch let error as PipelineError {
            if case .timeout = error {
                // Success - timeout worked
            } else {
                XCTFail("Expected timeout error, got: \(error)")
            }
        }
    }
    
    func testNextGuardWithConditionalCalls() async throws {
        // Test NextGuard behavior with middleware that conditionally calls next
        let pipeline = StandardPipeline(handler: TestHandler())
        
        let conditionalMiddleware = ConditionalMiddleware(
            condition: { command in
                if let testCommand = command as? TestCommand {
                    return testCommand.value == "skip"
                }
                return false
            },
            callNext: false
        )
        
        try await pipeline.addMiddleware(conditionalMiddleware)
        
        // This should trigger NextGuard warning but not crash
        let skipCommand = TestCommand(value: "skip")
        do {
            _ = try await pipeline.execute(skipCommand, context: CommandContext())
            XCTFail("Should have thrown error")
        } catch {
            // Expected to throw TestError.middlewareFailed
            XCTAssertTrue(error is TestError)
        }
        
        // This should work normally
        let normalCommand = TestCommand(value: "normal")
        let result = try await pipeline.execute(normalCommand, context: CommandContext())
        XCTAssertEqual(result, "normal-handled")
    }
    
    func testUnsafeMiddlewareMultipleCalls() async throws {
        // Test that UnsafeMiddleware can call next multiple times
        let counter = CallCounter()
        
        struct CountingHandler: CommandHandler {
            typealias CommandType = TestCommand
            let counter: CallCounter
            
            func handle(_ command: TestCommand) async throws -> TestCommand.Result {
                await counter.increment("handler")
                return command.value + "-handled"
            }
        }
        
        let pipeline = StandardPipeline(handler: CountingHandler(counter: counter))
        
        let unsafeMiddleware = UnsafeMultiCallMiddleware(callCount: 3)
        try await pipeline.addMiddleware(unsafeMiddleware)
        
        let command = TestCommand(value: "test")
        let result = try await pipeline.execute(command, context: CommandContext())
        
        XCTAssertEqual(result, "test-handled")
        XCTAssertEqual(await counter.getCount("handler"), 3, "Handler should be called 3 times")
    }
    
    func testErrorPropagation() async throws {
        // Test that errors properly propagate through middleware chain
        let pipeline = StandardPipeline(handler: TestHandler())
        
        // Add some middleware
        try await pipeline.addMiddleware(LoggingMiddleware())
        
        // Execute command that will fail
        let failCommand = TestCommand(value: "test", shouldFail: true)
        
        do {
            _ = try await pipeline.execute(failCommand, context: CommandContext())
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }
    
    func testEmptyMiddlewareChain() async throws {
        // Test pipeline with no middleware
        let pipeline = StandardPipeline(handler: TestHandler())
        
        let command = TestCommand(value: "test")
        let result = try await pipeline.execute(command, context: CommandContext())
        
        XCTAssertEqual(result, "test-handled")
    }
    
    func testDeepMiddlewareChain() async throws {
        // Test with 50+ middleware layers
        let pipeline = StandardPipeline(handler: TestHandler())
        let counter = CallCounter()
        
        // Add 50 middleware
        for i in 0..<50 {
            try await pipeline.addMiddleware(CountingMiddleware(
                id: "middleware-\(i)",
                priority: .custom,
                callCounter: counter
            ))
        }
        
        let command = TestCommand(value: "test")
        let result = try await pipeline.execute(command, context: CommandContext())
        
        XCTAssertEqual(result, "test-handled")
        
        // Verify all middleware were called
        for i in 0..<50 {
            XCTAssertEqual(await counter.getCount("middleware-\(i)"), 1)
        }
    }
    
    // MARK: - Helper Types
    
    private struct SlowMiddleware: Middleware {
        let delay: TimeInterval
        let priority = ExecutionPriority.postProcessing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await next(command, context)
        }
    }
}

// MARK: - Concurrency Tests

extension Phase4ValidationTests {
    func testHighConcurrency() async throws {
        // Test with many concurrent requests
        let pipeline = StandardPipeline(handler: TestHandler())
        let counter = CallCounter()
        
        try await pipeline.addMiddleware(CountingMiddleware(
            id: "concurrent",
            priority: .processing,
            callCounter: counter
        ))
        
        // Execute 100 commands concurrently
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let command = TestCommand(value: "test-\(i)")
                    return try await pipeline.execute(command, context: CommandContext())
                }
            }
            
            var results = Set<String>()
            for try await result in group {
                results.insert(result)
            }
            
            XCTAssertEqual(results.count, 100, "Should have 100 unique results")
        }
        
        XCTAssertEqual(await counter.getCount("concurrent"), 100, "Middleware should be called 100 times")
    }
    
    func testSendableConformance() async throws {
        // Verify all types are properly Sendable
        let pipeline = StandardPipeline(handler: TestHandler())
        
        // This should compile if everything is properly Sendable
        let _: @Sendable () async throws -> Void = {
            let command = TestCommand(value: "test")
            let context = CommandContext()
            _ = try await pipeline.execute(command, context: context)
        }
    }
}
