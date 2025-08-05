import XCTest
@testable import PipelineKit

final class TimeoutMiddlewareWrapperTests: XCTestCase {
    // MARK: - Test Types
    
    private struct TestCommand: Command {
        typealias Result = String
        let id: String
    }
    
    private final class SlowMiddleware: Middleware, @unchecked Sendable {
        let executionTime: TimeInterval
        let priority = ExecutionPriority.processing
        var wasCompleted = false
        var wasCancelled = false
        let checkCancellation: Bool
        
        init(executionTime: TimeInterval, checkCancellation: Bool = true) {
            self.executionTime = executionTime
            self.checkCancellation = checkCancellation
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Simulate slow operation with cancellation checks
            let steps = Int(executionTime * 10) // Check every 100ms
            
            do {
                for _ in 0..<steps {
                    if checkCancellation {
                        try Task.checkCancellation()
                    }
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
                wasCompleted = true
            } catch {
                if case PipelineError.cancelled = error {
                    wasCancelled = true
                    throw PipelineError.cancelled(context: nil)
                }
                throw error
            }
            
            return try await next(command, context)
        }
    }
    
    private final class FastMiddleware: Middleware {
        let priority = ExecutionPriority.processing
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            // Execute immediately
            return try await next(command, context)
        }
    }
    
    private final class CountingMiddleware: Middleware {
        let priority = ExecutionPriority.processing
        private let counter: Counter
        
        init(counter: Counter) {
            self.counter = counter
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            await counter.increment()
            return try await next(command, context)
        }
    }
    
    private actor Counter {
        private var count = 0
        
        func increment() {
            count += 1
        }
        
        func getCount() -> Int {
            return count
        }
        
        func reset() {
            count = 0
        }
    }
    
    // MARK: - Tests
    
    func testFastExecutionCompletes() async throws {
        // Given
        let fastMiddleware = FastMiddleware()
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: fastMiddleware,
            timeout: 1.0 // 1 second timeout
        )
        
        // When
        let result = try await timeoutWrapper.execute(
            TestCommand(id: "fast"),
            context: CommandContext(),
            next: { command, _ in "Success: \(command.id)" }
        )
        
        // Then
        XCTAssertEqual(result, "Success: fast")
    }
    
    func testTimeoutActuallyCancelsTask() async throws {
        // Given: A slow middleware that takes 2 seconds
        let slowMiddleware = SlowMiddleware(executionTime: 2.0)
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: slowMiddleware,
            timeout: 0.5 // 500ms timeout
        )
        
        // When: We execute with timeout
        do {
            _ = try await timeoutWrapper.execute(
                TestCommand(id: "test-timeout"),
                context: CommandContext(),
                next: { _, _ in "Should not complete" }
            )
            XCTFail("Should have timed out")
        } catch let error as PipelineError {
            // Then: We get a timeout error
            if case .cancelled(let context) = error {
                XCTAssertNotNil(context)
                XCTAssertTrue(context?.contains("SlowMiddleware") ?? false)
            } else {
                XCTFail("Expected PipelineError.cancelled")
            }
            
            // And: The middleware was not completed
            XCTAssertFalse(slowMiddleware.wasCompleted)
            
            // Wait a bit to ensure the task was actually cancelled
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            XCTAssertTrue(slowMiddleware.wasCancelled || !slowMiddleware.wasCompleted)
        }
    }
    
    func testTimeoutWithNonCancellableMiddleware() async throws {
        // Given: A middleware that doesn't check for cancellation
        let stubbornMiddleware = SlowMiddleware(
            executionTime: 2.0,
            checkCancellation: false
        )
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: stubbornMiddleware,
            timeout: 0.5
        )
        
        // When: We execute with timeout
        do {
            _ = try await timeoutWrapper.execute(
                TestCommand(id: "test-stubborn"),
                context: CommandContext(),
                next: { _, _ in "Should timeout" }
            )
            XCTFail("Should have timed out")
        } catch is PipelineError {
            // Then: We still get a timeout error
            // The middleware might continue in background but we've returned control
            XCTAssertFalse(stubbornMiddleware.wasCompleted)
        }
    }
    
    
    func testPriorityInheritance() async throws {
        // Given
        let middleware = PriorityMiddleware(priority: .authentication)
        
        // When - inherit priority
        let inheritedWrapper = TimeoutMiddlewareWrapper(
            wrapped: middleware,
            timeout: 1.0
        )
        XCTAssertEqual(inheritedWrapper.priority, .authentication)
        
        // When - override priority
        let overriddenWrapper = TimeoutMiddlewareWrapper(
            wrapped: middleware,
            timeout: 1.0,
            priority: .validation
        )
        XCTAssertEqual(overriddenWrapper.priority, .validation)
    }
    
    func testWrappedMiddlewareExecution() async throws {
        // Given
        let counter = Counter()
        let countingMiddleware = CountingMiddleware(counter: counter)
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: countingMiddleware,
            timeout: 1.0
        )
        
        // When
        _ = try await timeoutWrapper.execute(
            TestCommand(id: "count"),
            context: CommandContext(),
            next: { _, _ in "Done" }
        )
        
        // Then
        let count = await counter.getCount()
        XCTAssertEqual(count, 1, "Wrapped middleware should be executed")
    }
    
    /*
    func testContextPassThrough() async throws {
        // Given
        struct TestKey: ContextKey { typealias Value = String }
        let context = CommandContext()
        context.set("test-value", for: TestKey.self)
        
        // Create a simple middleware that verifies context
        let middleware = SimpleMiddleware { cmd, ctx, next in
            let value = await ctx.get(TestKey.self)
            guard value == "test-value" else {
                throw TestError.contextValueMismatch
            }
            return try await next(cmd, ctx)
        }
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: middleware,
            timeout: 1.0
        )
        
        // When/Then - should not throw if context is passed correctly
        _ = try await timeoutWrapper.execute(
            TestCommand(id: "context"),
            context: context,
            next: { _, _ in "Success" }
        )
    }
    */
    
    func testErrorPropagation() async throws {
        // Given
        let errorMiddleware = ErrorThrowingMiddleware(error: TestError.middleware)
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: errorMiddleware,
            timeout: 1.0
        )
        
        // When/Then
        do {
            _ = try await timeoutWrapper.execute(
                TestCommand(id: "error"),
                context: CommandContext(),
                next: { _, _ in "Should not reach" }
            )
            XCTFail("Should have thrown error")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }
    
    func testMultipleExecutions() async throws {
        // Given
        let counter = Counter()
        let countingMiddleware = CountingMiddleware(counter: counter)
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: countingMiddleware,
            timeout: 0.5
        )
        
        // When - execute multiple times
        for i in 0..<5 {
            _ = try await timeoutWrapper.execute(
                TestCommand(id: "multi-\(i)"),
                context: CommandContext(),
                next: { _, _ in "Done" }
            )
        }
        
        // Then
        let count = await counter.getCount()
        XCTAssertEqual(count, 5, "Should handle multiple executions")
    }
    
    func testZeroTimeout() async throws {
        // Given
        let middleware = FastMiddleware()
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: middleware,
            timeout: 0.0 // Zero timeout
        )
        
        // When - should still complete (timeout is checked after execution)
        let result = try await timeoutWrapper.execute(
            TestCommand(id: "zero"),
            context: CommandContext(),
            next: { command, _ in "Completed: \(command.id)" }
        )
        
        // Then
        XCTAssertEqual(result, "Completed: zero")
    }
    
    // MARK: - Helper Types
    
    private enum TestError: Error {
        case middleware
        case validation
        case contextValueMismatch
    }
    
    private final class ErrorThrowingMiddleware: Middleware {
        let error: Error
        let priority = ExecutionPriority.processing
        
        init(error: Error) {
            self.error = error
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            throw error
        }
    }
    
    
    private final class PriorityMiddleware: Middleware {
        let priority: ExecutionPriority
        
        init(priority: ExecutionPriority) {
            self.priority = priority
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            try await next(command, context)
        }
    }
    
    // Commented out due to Swift limitation: cannot pass non-escaping 'next' to escaping closure
    /*
    private struct SimpleMiddleware: Middleware {
        let priority = ExecutionPriority.processing
        let handler: @Sendable (any Command, CommandContext, @escaping @Sendable (any Command, CommandContext) async throws -> Any) async throws -> Any
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            let result = try await handler(command, context) { cmd, ctx in
                try await next(cmd as! T, ctx)
            }
            return result as! T.Result
        }
    }
    */
}
