import XCTest
@testable import PipelineKit

final class CommandContextNonActorTests: XCTestCase {
    private struct TestKey: ContextKey {
        typealias Value = String
    }
    
    private struct NumberKey: ContextKey {
        typealias Value = Int
    }
    
    func testContextIsNoLongerActor() {
        // This test verifies that CommandContext methods don't require await
        let metadata = TestCommandMetadata(
            userId: "test-user",
            correlationId: "test-123"
        )
        let context = CommandContext(metadata: metadata)
        
        // These operations should not require await
        context.set("test-value", for: TestKey.self)
        let value = context.get(TestKey.self)
        XCTAssertEqual(value, "test-value")
        
        // Test metadata access
        let retrievedMetadata = context.commandMetadata
        XCTAssertEqual(retrievedMetadata.userId, "test-user")
    }
    
    func testConcurrentContextAccess() async throws {
        let context = CommandContext.test()
        let iterations = 1000
        
        await withTaskGroup(of: Void.self) { group in
            // Multiple writers
            for i in 0..<iterations {
                group.addTask {
                    context.set("value-\(i)", for: TestKey.self)
                    context.set(i, for: NumberKey.self)
                }
            }
            
            // Multiple readers
            for _ in 0..<iterations {
                group.addTask {
                    _ = context.get(TestKey.self)
                    _ = context.get(NumberKey.self)
                }
            }
        }
        
        // Verify context still works after concurrent access
        context.set("final", for: TestKey.self)
        XCTAssertEqual(context.get(TestKey.self), "final")
    }
    
    func testMiddlewareWithoutAwaitOnContext() async throws {
        struct NonAsyncContextMiddleware: Middleware {
            let priority: ExecutionPriority = .custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                // No await needed for context operations
                context.set("middleware-value", for: TestKey.self)
                let value = context.get(TestKey.self)
                XCTAssertEqual(value, "middleware-value")
                
                return try await next(command, context)
            }
        }
        
        let handler = TestHelpers.TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(NonAsyncContextMiddleware())
        
        let context = CommandContext.test()
        let command = TestHelpers.TestCommand(value: "test")
        
        let result = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result, "test")
        
        // Verify context retained the value
        XCTAssertEqual(context.get(TestKey.self), "middleware-value")
    }
    
    func testParallelMiddlewareExecution() async throws {
        struct ParallelTestMiddleware: Middleware {
            let id: String
            let priority: ExecutionPriority = .custom
            
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @Sendable (T, CommandContext) async throws -> T.Result
            ) async throws -> T.Result {
                // Simulate some work
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                context.set(id, for: TestKey.self)
                
                // For parallel middleware, we don't call next
                throw ParallelExecutionError.middlewareShouldNotCallNext
            }
        }
        
        let handler = TestHelpers.TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        let parallelWrapper = ParallelMiddlewareWrapper(
            middlewares: [
                ParallelTestMiddleware(id: "middleware-1"),
                ParallelTestMiddleware(id: "middleware-2"),
                ParallelTestMiddleware(id: "middleware-3")
            ],
            strategy: .sideEffectsOnly
        )
        
        try await pipeline.addMiddleware(parallelWrapper)
        
        let context = CommandContext.test()
        let command = TestHelpers.TestCommand(value: "test")
        
        let result = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result, "test")
        
        // One of the middleware should have set a value
        XCTAssertNotNil(context.get(TestKey.self))
    }
}

// Test helpers specific to this test file
private enum TestHelpers {
    struct TestCommand: Command {
        typealias Result = String
        let value: String
        
        func execute() async throws -> String {
            return value
        }
    }
    
    struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return command.value
        }
    }
}
