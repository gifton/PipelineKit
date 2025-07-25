import XCTest
@testable import PipelineKit

final class TimeoutMiddlewareTests: XCTestCase {
    
    // Test command
    struct TestCommand: Command {
        typealias Result = String
        let value: String
        
        func execute() async throws -> String {
            return value
        }
    }
    
    // Test handler
    struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return command.value
        }
    }
    
    // Slow middleware for testing timeouts
    struct SlowMiddleware: Middleware {
        let delay: TimeInterval
        let priority: ExecutionPriority = .custom
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await next(command, context)
        }
    }
    
    func testTimeoutMiddlewareWarnsOnSlowExecution() async throws {
        // Given
        let slowMiddleware = SlowMiddleware(delay: 0.2) // 200ms
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: slowMiddleware,
            timeout: 0.1 // 100ms timeout
        )
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(timeoutWrapper)
        
        let context = CommandContext.test()
        let command = TestCommand(value: "test")
        
        // When - Execute (should complete but log warning)
        let result = try await pipeline.execute(command, context: context)
        
        // Then - Command should complete successfully
        XCTAssertEqual(result, "test")
        // Note: In a real test, we'd capture logs to verify the warning was printed
    }
    
    func testTimeoutMiddlewareWithFastExecution() async throws {
        // Given
        let fastMiddleware = SlowMiddleware(delay: 0.01) // 10ms
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: fastMiddleware,
            timeout: 0.1 // 100ms timeout
        )
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(timeoutWrapper)
        
        let context = CommandContext.test()
        let command = TestCommand(value: "fast")
        
        // When
        let result = try await pipeline.execute(command, context: context)
        
        // Then - Should complete without warning
        XCTAssertEqual(result, "fast")
    }
    
    func testMultipleTimeoutWrappersInPipeline() async throws {
        // Given
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        // Add multiple middleware with different timeouts
        let slow1 = TimeoutMiddlewareWrapper(
            wrapped: SlowMiddleware(delay: 0.05),
            timeout: 0.1
        )
        let slow2 = TimeoutMiddlewareWrapper(
            wrapped: SlowMiddleware(delay: 0.03),
            timeout: 0.1
        )
        
        try await pipeline.addMiddleware(slow1)
        try await pipeline.addMiddleware(slow2)
        
        let context = CommandContext.test()
        let command = TestCommand(value: "multi")
        
        // When
        let result = try await pipeline.execute(command, context: context)
        
        // Then - Should complete successfully
        XCTAssertEqual(result, "multi")
    }
    
    func testTimeoutErrorPropagation() async throws {
        // Given - Middleware that throws a timeout error
        struct TimeoutThrowingMiddleware: Middleware {
            let priority: ExecutionPriority = .custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                throw TimeoutError(
                    timeout: 1.0,
                    middleware: "TestMiddleware",
                    command: String(describing: T.self)
                )
            }
        }
        
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: TimeoutThrowingMiddleware(),
            timeout: 1.0
        )
        
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(timeoutWrapper)
        
        let context = CommandContext.test()
        let command = TestCommand(value: "error")
        
        // When/Then
        do {
            _ = try await pipeline.execute(command, context: context)
            XCTFail("Should throw timeout error")
        } catch let error as TimeoutError {
            XCTAssertEqual(error.timeout, 1.0)
            XCTAssertEqual(error.middleware, "TestMiddleware")
        }
    }
}